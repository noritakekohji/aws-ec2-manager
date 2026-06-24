# aws-ec2-manager — MVP 実装プラン

**日付**: 2026-06-25
**対応 spec**: [`docs/superpowers/specs/2026-06-25-aws-ec2-manager.md`](../specs/2026-06-25-aws-ec2-manager.md)
**目標バージョン**: 0.1.0

---

## 全体方針

- **垂直分割**: モジュール単位（AwsConfig → AwsManager → WPF → SSM YAML → 仕上げ）で進める
- 各タスクは **テスト先行**（Pester で AwsCLI を Mock）
- WPF 部分は実 AWS を必要とするため、最終手動確認は AVD 上で実施
- `tools/` の中身は触らない（spec §7 参照）

---

## Task A: AwsConfig.psm1（プロファイル管理）

**目的**: `~/.aws/config` を読み、プロファイル一覧・SSO 状態を返す。

**成果物**:
- `AwsConfig.psm1`
- `tests/AwsConfig.Tests.ps1`

**実装内容**:
1. `Get-AwsProfiles` — INI 形式パーサ（PS ネイティブ実装、`profile <name>` セクション抽出）
2. `Get-AwsProfileDetail -Name <string>` — `sso_start_url` / `region` / `sso_account_id` を返す
3. `Test-SsoToken -Name <string>` — `aws sts get-caller-identity --profile <name>` を実行し成否を `[bool]` で返す

**テスト**:
- 一時 ini ファイルを作って `Get-AwsProfiles` がプロファイル名配列を返すこと
- 存在しないプロファイル指定時に `$null` を返すこと
- `Test-SsoToken` で `aws` コマンドを Mock し成功/失敗を切り分け

**完了条件**: `Invoke-Pester tests/AwsConfig.Tests.ps1` が全グリーン

---

## Task B: AwsManager.psm1（EC2 / SG / SSM 操作）

**目的**: AWS CLI を叩いて EC2 / SG / SSM Run Command の操作を提供。

**成果物**:
- `AwsManager.psm1`
- `tests/AwsManager.Tests.ps1`

**実装内容**:
1. `Get-Ec2Instances -Profile <name>` — `aws ec2 describe-instances` → 整形済み PSCustomObject 配列
2. `Start-Ec2Instance` / `Stop-Ec2Instance` / `Restart-Ec2Instance`
3. `Get-VpcSecurityGroups -Profile <name> -VpcId <id>`
4. `Set-InstanceSecurityGroups -Profile <name> -InstanceId <id> -GroupIds <id[]>` — `modify-instance-attribute --groups`
5. `Invoke-SsmTask -Profile <name> -InstanceId <id> -YamlPath <path>` —
   YAML を読み（PowerShell-Yaml なしの場合は最小自作パーサ）、`send-command` → ポーリング → 結果オブジェクト返却

**戻り値スキーマ** (`Invoke-SsmTask`):
```powershell
[PSCustomObject]@{
    Status     = 'Success' | 'Failed' | 'TimedOut'
    Output     = <string>      # CommandPlugin StandardOutputContent
    Error      = <string>      # StandardErrorContent
    OutputType = 'text' | 'html'
    Duration   = <TimeSpan>
}
```

**テスト**:
- `Mock aws` で `describe-instances` の偽 JSON を返し整形を検証
- `Set-InstanceSecurityGroups` 呼び出し時の引数（特に `--groups` の順序）を assert
- `Invoke-SsmTask` のポーリング → 完了パスをタイマー Mock で検証

**完了条件**: Pester グリーン + PSScriptAnalyzer 警告ゼロ

---

## Task C: MainWindow.xaml + App.ps1（WPF 骨組み）

**目的**: タブ 3 つを持つメインウィンドウを表示するところまで。AWS 呼び出しはダミー。

**成果物**:
- `MainWindow.xaml`
- `App.ps1`
- `launch.bat`

**実装内容**:
1. `MainWindow.xaml` — Grid / TabControl（インスタンス / SG / ツール） / ヘッダ（プロファイル・ステータス）
2. `App.ps1` —
   - `Add-Type -AssemblyName PresentationFramework`
   - `[Windows.Markup.XamlReader]::Load(...)` で XAML 読込
   - プロファイルドロップダウンに `Get-AwsProfiles` を流し込む
   - 各ボタンのハンドラは TODO ログ出力のみ
3. `launch.bat` — `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0App.ps1"`

**完了条件**: `launch.bat` ダブルクリックでウィンドウが立ち上がり、タブ切替ができる

---

## Task D: Tab1（EC2 インスタンス管理）

**目的**: 一覧表示 / 起動 / 停止 / 再起動。

**実装内容**:
1. DataGrid バインディング（`ItemsSource` を `Get-Ec2Instances` の結果に）
2. 起動 / 停止 / 再起動ボタン → 確認ダイアログ → `Start/Stop/Restart-Ec2Instance` 呼び出し
3. 「更新」ボタン → 再取得
4. 重い呼び出しは Runspace 非同期化（UI が固まらない）

**完了条件**: 実アカウントで一覧・起動・停止が動く

---

## Task E: Tab2（セキュリティグループ管理）

**目的**: SG 付け外し UI と modify-instance-attribute 呼び出し。

**実装内容**:
1. インスタンス選択 → `Get-VpcSecurityGroups` で VPC 内 SG リスト取得
2. 適用済み / 未適用を 2 つの ListBox に表示、`>` / `<` で移動
3. 「適用」ボタン → diff 表示確認 → `Set-InstanceSecurityGroups`

**完了条件**: SG リストの置換が実 AWS で反映される

---

## Task F: Tab3（SSM ツール実行）+ YAML ローダー

**目的**: YAML 一覧表示 → 実行 → 結果表示。

**実装内容**:
1. YAML パーサ（最小実装：トップレベルキーと `script: |` ブロックのみ）
2. インスタンス Platform で `ssm-tasks/linux/` か `ssm-tasks/windows/` をスキャン
3. リストボックスに `name` を並べる
4. 「実行」ボタン → `Invoke-SsmTask` → 完了時に
   - `output: text` → TextBox に表示
   - `output: html` → `%TEMP%` に出力 → `Start-Process msedge.exe`
5. 進行中は ProgressBar 表示
6. **サンプル YAML**: `ssm-tasks/linux/network-check.yaml` を作成
   ```yaml
   name: ネットワーク疎通チェック
   output: text
   script: |
     cd /opt/ops-scripts/tools/network-check
     bash check_network_connectivity.sh --target-list targets.lst
   ```

**完了条件**: 実 EC2 で text / html 両方が表示される

---

## Task G: CI / ドキュメント / リリース

**実装内容**:
1. `.github/workflows/ci.yml` を Pester 実行型に調整（windows-latest）
2. `README.md` の「使い方」を最終形に更新（スクリーンショット差し込みは後回し可）
3. `CHANGELOG.md` 0.1.0 セクションを確定
4. `git tag v0.1.0 && git push --tags`

**完了条件**: CI グリーン + `v0.1.0` タグが push 済み

---

## 依存関係グラフ

```
A (AwsConfig) ─┐
               ├─→ C (WPF骨組み) ─→ D (Tab1) ─→ E (Tab2) ─→ F (Tab3) ─→ G (リリース)
B (AwsManager) ┘                       │           │            │
                                       └───────────┴────────────┘
                                            B に依存
```

A と B は並行実装可能。C は A 完了後に着手。D/E/F は B 完了後で C 後。G は最後。

---

## 検証 / 動作確認

- **モジュール単体**: Pester（Mock 利用、CI で実行）
- **GUI**: AVD 上で手動確認。実 AWS（bedrock プロファイル）を使う
- **SSM**: 検証用 EC2 を 1 台用意し、`tools/network-check` を `/opt/ops-scripts/` 配下に手動配備して試す

---

## 残課題（plan に書ききれないもの）

- tools/ をサーバへ配備する仕組み（Ansible / SSM Distributor / 手動）は別途検討
- 旧 `ops-scripts-template/tools/` の削除は **本ツール 0.1.0 が AVD 上で正常動作確認できた後** に Task #6 で実施
