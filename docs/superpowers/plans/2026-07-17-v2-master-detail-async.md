# aws-ec2-manager v2.0 マスター/ディテール + 非同期化 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 4 タブ独立選択の現行 UI をマスター/ディテール型に再構成し、全 AWS 呼び出しをイベント駆動の非同期実行基盤に載せ替えて UI フリーズを解消する。

**Architecture:** 左ペインにインスタンス一覧(フィルタ + 電源操作 + ロック)、右ペインに選択インスタンス追従のタブ(詳細 / SG / ロール / ツール実行)。AWS CLI 呼び出しはバックグラウンド Runspace で実行し、完了・進捗は `Dispatcher.BeginInvoke` で UI へ push(UI 側タイマーなし)。App.ps1 は薄いエントリにして機能別 src/*.ps1 を dot-source。

**Tech Stack:** PowerShell 5.1 / WPF (XAML) / AWS CLI v2 (SSO) / Pester 5

## Global Constraints

- PS 5.1 互換必須: `??` / `?:` / `?.` / `utf8NoBOM` 禁止(CLAUDE.md)
- .ps1 / .psm1 は UTF-8 BOM 付き保存
- Set-StrictMode -Version Latest 下で動くこと
- AWS 認証は SSO プロファイルのみ。課金操作はユーザー明示承認後
- ロック機能の仕様は現行維持(spec §2)
- UI 側に常時タイマー・定期ポーリングを置かない(spec §3)
- 既存モジュール AwsManager.psm1 / AwsConfig.psm1 / AppSettings.psm1 / Logger.psm1 の公開 API は原則維持

## 移植元マップ(現行 App.ps1 → 新配置)

| 現行 (App.ps1 行) | 内容 | 移植先 |
|---|---|---|
| 32-60 | Find-Control / UnhandledException | src/UiCommon.ps1 |
| 61-345 | プロファイル / 設定ダイアログ / SSO / ログボタン | src/HeaderPane.ps1 |
| 362-475 | ロック状態・判定・ボタン制御 | src/AppState.ps1 + src/InstanceListPane.ps1 |
| 477-575 | 選択取得 / 共有アイテム / 依存コンボ同期 | AppState に置換(依存コンボ同期は**削除**) |
| 577-734 | 詳細表示(Show-InstanceDetailWindow) | src/DetailTab.ps1(タブ化) |
| 735-961 | 一覧更新 / 電源操作 / ロックボタン | src/InstanceListPane.ps1 |
| 963-2070 | SG タブ一式(diff/HTML レポート含む) | src/SgTab.ps1 |
| 2071-2543 | ロールタブ一式 | src/RoleTab.ps1 |
| 2545-2564 | Set-UiBusy | src/UiCommon.ps1(AsyncRunner 連動に改修) |
| 2566-3235 | SSM タブ一式 + 起動処理 | src/SsmTab.ps1 + App.ps1 |

---

### Task 1: AsyncRunner(イベント駆動非同期実行基盤)

**Files:**
- Create: `src/AsyncRunner.ps1`
- Test: `tests/AsyncRunner.Tests.ps1`

**Interfaces (Produces):**
- `Initialize-AsyncRunner -Dispatcher <Dispatcher> [-OnBusyChanged <scriptblock>]`
- `Start-AsyncTask -Name <string> -Work <scriptblock> [-ArgumentList <object[]>] -OnSuccess <scriptblock> [-OnError <scriptblock>] [-OnProgress <scriptblock>]` → bool(実行中なら $false を返し開始しない)
- `Stop-AsyncTask` (キャンセル: 子 aws プロセス Kill + Runspace 停止)
- `Test-AsyncTaskRunning` → bool
- `Get-AsyncChannel` → synchronized hashtable(AwsPid / CancelRequested キー)
- Work scriptblock は `param($Channel, $ReportProgress, ...$ArgumentList)` を受け取る。
  `$ReportProgress` は `{ param($msg) }` 形式で UI へ push される

**実装方針(完全コードは実装時に確定、骨子):**

```powershell
$script:AsyncState = @{
    Dispatcher = $null; PowerShell = $null; Runspace = $null; Handle = $null
    Channel = [hashtable]::Synchronized(@{ AwsPid = 0; CancelRequested = $false })
    OnBusyChanged = $null; Running = $false; ModuleRoot = $PSScriptRoot
}
```

- Start-AsyncTask:
  1. Running なら $false
  2. OnSuccess/OnError/OnProgress を UI Runspace 側で delegate 化:
     `$okCb = [System.Windows.Threading.DispatcherOperationCallback]$wrappedSuccess` 形式
  3. STA Runspace を作成し SessionStateProxy で Dispatcher / delegates / Channel /
     WorkText(`$Work.ToString()`)/ ArgumentList / ModuleRoot を渡す
  4. 背景スクリプト: AwsManager.psm1 等を import → `$ReportProgress` を定義
     (`{ param($m) [void]$Dispatcher.BeginInvoke([Action[object]]$OnProgressDelegate, $m) }` 相当)
     → `[scriptblock]::Create($WorkText)` を実行 → 成否を包んだ結果オブジェクトを
     `$Dispatcher.BeginInvoke($OnCompleteDelegate, $result)` で push
  5. UI 側 OnComplete ラッパで Runspace/PowerShell を Dispose し Running=false、
     OnBusyChanged 通知、OnSuccess/OnError 呼び分け
- Stop-AsyncTask: Channel.CancelRequested=true → AwsPid が 0 でなければ Stop-Process →
  `$ps.BeginStop()`。完了通知は通常経路(エラー扱い)で届く

**Steps:**
- [ ] tests/AsyncRunner.Tests.ps1 を作成: (a) 成功時に OnSuccess が結果付きで呼ばれる
      (b) Work が throw したら OnError (c) 実行中の二重 Start は $false
      (d) キャンセルで OnError 経路。Dispatcher は `[Dispatcher]::CurrentDispatcher` +
      DispatcherFrame ポンプで検証
- [ ] テストが失敗することを確認(関数未定義)
- [ ] src/AsyncRunner.ps1 実装
- [ ] `Invoke-Pester tests/AsyncRunner.Tests.ps1` PASS
- [ ] commit `feat: イベント駆動の非同期実行基盤 AsyncRunner を追加`

### Task 2: AwsManager にキャンセルチャネル対応

**Files:**
- Modify: `AwsManager.psm1`(Invoke-AwsCli / Invoke-SsmTask)
- Test: `tests/AwsManager.Tests.ps1` に追記

**Interfaces (Produces):**
- `Set-AwsCliChannel -Channel <hashtable>`(module 変数に保持。$null 許容)
- Invoke-AwsCli: プロセス起動直後に `$Channel['AwsPid'] = $process.Id`、終了時 0 に戻す。
  ループ前後で `$Channel['CancelRequested']` を見て中断時は throw 'キャンセルされました'
- Invoke-SsmTask: ステータス確認ループ内で CancelRequested を確認し、
  cancel-command を送って中断(既存のキャンセル送信ロジックを流用)

**Steps:**
- [ ] 失敗するテストを追加(Set-AwsCliChannel 存在、CancelRequested=true で例外)
- [ ] 実装
- [ ] `Invoke-Pester tests/AwsManager.Tests.ps1` PASS
- [ ] commit `feat: AWS CLI 呼び出しにキャンセルチャネルを追加`

### Task 3: AppState(選択状態・キャッシュ・フィルタ・ロック)

**Files:**
- Create: `src/AppState.ps1`
- Test: `tests/AppState.Tests.ps1`

**Interfaces (Produces):**
- `$script:AppState`: Profile / Items / SelectedInstanceId / HasLoaded / LastUpdated /
  SgCache(hashtable: instanceId → @{ Applied; Available; VpcId; OriginalIds })/
  RoleCache / LockedInstanceIds
- `Test-InstanceMatchesFilter -Instance <obj> -Filter <string>` → bool
  (Name / InstanceId / PrivateIpAddress / PublicIpAddress の部分一致、大文字小文字無視、
  空フィルタは常に $true)
- `Get-FilteredInstances -Items <obj[]> -Filter <string>` → obj[]
- `Test-InstanceLocked` / `Add-InstanceLock` / `Remove-InstanceLock`(AppSettings 永続化込み)
- `Clear-InstanceScopedCaches [-InstanceId <string>]`(プロファイル切替・更新時に SG/ロールキャッシュ破棄)

**Steps:**
- [ ] 失敗するテスト(フィルタ各フィールド一致 / 不一致 / 空 / null 安全、ロック add/remove/永続化 mock)
- [ ] 実装(現行 382-475 のロック関数を移植・改名)
- [ ] PASS 確認 → commit `feat: AppState 選択状態・フィルタ・ロック管理を追加`

### Task 4: 新 MainWindow.xaml(マスター/ディテール)

**Files:**
- Modify: `MainWindow.xaml`(全面書き換え。リソース/スタイルは現行を維持)
- Test: `tests/Xaml.Tests.ps1`(コントロール一覧を更新)

**レイアウト:** ヘッダー(現行のまま)/ Grid 2 列(左 360px 初期 + GridSplitter + 右 *)/ ステータスバー。

主要コントロール(x:Name):
- 左: `InstanceFilterBox`(TextBox)、`InstancesGrid`(列: Name/ロック/State/SSM/InstanceId)、
  `RefreshInstancesButton` `StartInstanceButton` `StopInstanceButton` `RestartInstanceButton`
  `LockInstanceButton` `UnlockInstanceButton`、`InstanceCountText`、`InstanceEmptyText`
- 右: `SelectedInstanceHeaderText`(見出し)、`NoSelectionOverlay`(未選択案内)、
  `DetailTabs`(TabControl: 詳細 `DetailGrid`、SG(現行 SG タブの中身から SgInstanceComboBox/LoadSgButton を除去し `ReloadSgButton` を追加)、
  ロール(同様 `ReloadRoleButton`)、ツール実行(SsmInstanceComboBox/LoadSsmButton を除去))
- ステータスバー: `StatusBarText`、`TaskProgressBar`(IsIndeterminate)、`CancelTaskButton`

**Steps:**
- [ ] MainWindow.xaml 書き換え
- [ ] Xaml.Tests.ps1 の期待コントロール名を更新し PASS
- [ ] commit `feat: マスター/ディテール型レイアウトに MainWindow.xaml を再構成`

### Task 5: UiCommon + HeaderPane + 新 App.ps1 エントリ

**Files:**
- Create: `src/UiCommon.ps1`(Find-Control、Set-StatusText、Set-UiBusy(AsyncRunner 連動)、確認ダイアログヘルパ)
- Create: `src/HeaderPane.ps1`(現行 61-345 を移植: プロファイル・SSO・トークン・設定・ログ)
- Modify: `App.ps1`(~150 行に縮小: import → XAML ロード → src/*.ps1 dot-source → 初期化 → ShowDialog)
- Test: `tests/Syntax.Tests.ps1`(新規: 全 .ps1/.psm1 の PSParser 構文チェック)

**Steps:**
- [ ] Syntax.Tests.ps1 追加(この時点で全ファイル対象、以後のタスクの安全網)
- [ ] UiCommon / HeaderPane 移植、App.ps1 書き換え(この時点ではタブ配線はプレースホルダ関数)
- [ ] Pester 全体 + `powershell -STA -File App.ps1` 手動起動でウィンドウ表示確認(AWS 未接続でもクラッシュしないこと)
- [ ] commit `refactor: App.ps1 を薄いエントリ化し UiCommon/HeaderPane を分離`

### Task 6: InstanceListPane(一覧・フィルタ・電源・ロック、非同期化)

**Files:**
- Create: `src/InstanceListPane.ps1`
- Test: `tests/AppState.Tests.ps1` に選択遷移ケース追記

**Interfaces:**
- Consumes: AsyncRunner(Start-AsyncTask)、AppState、UiCommon
- Produces: `Update-InstanceListAsync [-Force]`、`Get-SelectedInstance`、
  選択変更イベント → `Invoke-SelectionChangedHandlers`(各タブが登録するコールバックリスト)

**要点:**
- 更新: `Start-AsyncTask -Work { param($Channel,$Report,$p) Get-Ec2Instances -Profile $p }`
  → OnSuccess で AppState.Items 更新 + フィルタ適用して Grid 反映
- フィルタ: `InstanceFilterBox.Add_TextChanged` でローカル再描画のみ(AWS 呼び出しなし)
- 電源操作: 確認ダイアログ → Start-AsyncTask(start/stop/reboot)→ OnSuccess で該当 1 台だけ
  再取得(現行 Update-CachedInstanceFromAws 相当も async)
- ロック/解除: 現行ロジック移植(AppState 経由)。empty 状態: `InstanceEmptyText` 表示切替

**Steps:**
- [ ] 実装 → Pester 全体 PASS → 手動起動で一覧取得・フィルタ動作確認(要 SSO。未ログイン時はエラー表示確認のみ)
- [ ] commit `feat: 左ペイン(一覧・フィルタ・電源・ロック)を非同期化して実装`

### Task 7: DetailTab

**Files:**
- Create: `src/DetailTab.ps1`(現行 Show-InstanceDetailWindow 577-734 の行データ生成を流用し、タブ内 DataGrid に表示。選択変更で即時更新 = ローカルデータのみ、AWS 呼び出しなし)

**Steps:**
- [ ] 実装 → 手動確認 → commit `feat: 詳細タブを追加(選択追従)`

### Task 8: SgTab 移植

**Files:**
- Create: `src/SgTab.ps1`(現行 963-2070 を移植)

**変更点:** SgInstanceComboBox / Update-SgInstanceComboBox* / LoadSgButton を削除し、
選択変更コールバック + `ReloadSgButton` に置換。SG リスト取得
(Get-Ec2Instances 1 台 + Get-VpcSecurityGroups)と適用(Set-InstanceSecurityGroups)を
Start-AsyncTask 化。取得結果は AppState.SgCache にインスタンス ID 単位で保持し、
タブがアクティブでないときは取得しない(タブ activation 時に未キャッシュなら取得)。
diff プレビュー / 実効ルール diff / HTML レポートはそのまま移植。

**Steps:**
- [ ] 移植・実装 → Pester 全体 PASS → commit `feat: SG タブを選択追従 + 非同期化で移植`

### Task 9: RoleTab 移植

**Files:**
- Create: `src/RoleTab.ps1`(現行 2071-2543 を移植。変更方針は Task 8 と同一。
  Get-IamInstanceProfiles / Get-InstanceProfileAssociation / Set-InstanceProfileAssociation を async 化、RoleCache 使用)

**Steps:**
- [ ] 移植・実装 → PASS → commit `feat: ロールタブを選択追従 + 非同期化で移植`

### Task 10: SsmTab 移植

**Files:**
- Create: `src/SsmTab.ps1`(現行 2566-3223 を移植)

**変更点:** SsmInstanceComboBox / LoadSsmButton 削除、選択インスタンスの Platform で
YAML リストを切替。YAML 追加・改名・保存・フォルダを開く・再スキャンはローカル操作なので同期のまま。
実行は Start-AsyncTask + OnProgress(Invoke-SsmTask の -StatusCallback を $ReportProgress に接続)。
実行中は CancelTaskButton で中断可能。HTML 結果は現行どおり一時ファイル → ブラウザ。

**Steps:**
- [ ] 移植・実装 → PASS → commit `feat: ツール実行タブを選択追従 + 非同期実行で移植`

### Task 11: 統合クリーンアップ

- [ ] 旧コード残骸(Update-DependentInstanceCombos 系、$pumpUi、旧 Set-UiBusy)が消えていることを確認
- [ ] PSScriptAnalyzer 実行(既存 CI 相当)で新規警告ゼロ
- [ ] Invoke-Pester -Path tests/ 全 PASS
- [ ] BOM / エンコーディング確認(全 .ps1 UTF-8 BOM)
- [ ] commit `refactor: v2 統合クリーンアップ`

### Task 12: 実機検証(検証用 SSO プロファイル)

- [ ] ユーザーに `aws sso login --profile <sso-profile>` を依頼(GUI の SSO ログインボタンでも可)
- [ ] GUI 起動 → スクリーンショット取得(computer-use)
- [ ] 一覧取得 / フィルタ / 選択追従(4 タブ)/ SG・ロール表示 / read-only 系 SSM 実行
- [ ] 実行中の UI 応答(スクロール・タブ切替)とキャンセル動作
- [ ] エラー状態(未ログインプロファイル選択時)の表示確認
- [ ] 発見した不具合を修正し、修正ごとに commit

### Task 13: リリース v2.0.0

- [ ] README.md / CLAUDE.md のディレクトリ構成・使い方を更新
- [ ] design-tokens.md の採用実績表に 1 行追記(tool-designer 規約)
- [ ] CHANGELOG.md に 2.0.0 節を確定、VERSION を 2.0.0 に
- [ ] code-reviewer スキルで自己レビュー
- [ ] publisher スキルを読み込み、commit → tag v2.0.0 → push → push --tags
