# LocalToolsLauncher UI 拡張 (select 型パラメータ + perf-monitor Start/Stop)

**日付**: 2026-07-18
**対象**: `LocalToolsLauncher.ps1` / `LocalToolsLauncher.xaml` / `tools/tool-catalog.yaml`(Windows GUI のみ)
**ステータス**: 実装済み(v2.4.0)、v2.5.0 で §3 の専用パネルを廃止し個別ツールパネルへ統合(下記追記参照)

---

## 1. 背景

ユーザーから Windows GUI ツールランチャーについて以下の共通要件が提示された。

- 上から「ツールの説明」「実行ボタン」「(あれば)定義ファイル」の順に表示し、その次に各引数の入力を並べる
- 引数が選択式の場合はプルダウンで選択させる
- 引数がファイルの場合は、パス表示と「開く」ボタンで編集モードに入れるようにする
- 必須指定の項目にはデフォルト値を入れておく
- `perf-monitor` はバックグラウンドで動作するため、専用の Start / Stop 操作を用意する

既存実装(`docs/superpowers/specs/2026-06-29-local-tools-launcher.md` および v2.2.0 での UI 統一)と突き合わせた結果、以下が判明した。

| 要件 | 現状 |
|---|---|
| 上部の要素配置 | タイトル+実行/停止ボタン → 説明 → 設定ファイル(あれば) → 引数、の順で既に実装済み |
| ファイル引数のパス+開くボタン | `configFiles` / `paramKey` 機構で cert-check / network-check / port-inventory / log-collector / perf-monitor / server-snapshot をカバー済み |
| 必須項目のデフォルト値 | カタログ上 `required: true` は `collect-snapshot-report.zipPath` の1件のみで、専用パネルの参照+ブラウズ+自動反映で既にカバー済み |
| 選択式引数のプルダウン化 | **未実装**。すべて `text` として自由入力 |
| perf-monitor の Start/Stop | **未実装**。他ツールと同じ汎用実行パネルで `アクション` を自由入力するのみ |

このため、本 spec は「選択式パラメータの select 型追加」と「perf-monitor 専用 Start/Stop パネル」の2点を実装スコープとする。他の共通要件は現状で充足しているため変更しない。

---

## 2. 対象パラメータのプルダウン化

コード上 `ValidateSet` で選択肢が固定されているパラメータのみを対象とする(複数選択・自由入力併用の `log-collector` の `Target` は対象外)。

| ツール | パラメータ | 現状 (`type`) | 変更後 | 選択肢 |
|---|---|---|---|---|
| `server-snapshot` | `command`(アクション) | `text` (width: short) | `select` | `collect,before,after,compare,list` |
| `perf-monitor` | `command`(アクション) | `text` (width: short) | `select` | `start,stop,report,status,list` |

### カタログスキーマ

`parameters[].type` に `select` を追加し、新規キー `options`(カンマ区切り文字列)を持たせる。

```yaml
- key: command
  label: アクション
  type: select
  width: short
  argument: ""
  options: "collect,before,after,compare,list"
  default: collect
```

`argument` が空(位置引数)である点は既存のまま変更しない。

### パーサー変更 (`Read-ToolCatalog`)

`$currentParam` の初期化に `Options = ''` を追加し、`switch ($key)` に `'options' { $currentParam.Options = $value }` を追加する。

### レンダラー変更 (`Set-ParameterDefaults`)

パラメータの分類ロジック(`[string]$p.Width -eq 'short'` で `compactFields` に振り分ける判定、793〜800行目)は **変更不要**。`select` 型パラメータは `command` キーのように元々 `width: short` を指定するため、既存ロジックのまま自動的に `compactFields` グループに入る。

変更が必要なのは、`compactFields` を実際に描画しているレンダリングループ(872〜895行目相当)。ここで `$p.Type -eq 'select'` かどうかを判定し、`select` の場合は `TextBox` の代わりに `ComboBox` を生成する:

- `ItemsSource` = `options` をカンマ分割・トリムした配列
- 初期選択 = `default` の値(一致する選択肢がなければ先頭)
- `Add_SelectionChanged` で `Update-CommandPreview` を呼ぶ(他コントロールの `TextChanged` と同様)

値の追跡には新規リスト `$script:SelectParameterControls` を用意する。既存の `$script:TextParameterControls` / `$script:CheckParameterControls` と同様に、次の2箇所で扱う(`Set-StrictMode -Version Latest` 下では未初期化の `$script:` 変数参照はエラーになるため両方必須):

- (a) スクリプトトップレベル(19〜20行目付近)で `$script:SelectParameterControls = @()` を宣言する
- (b) `Set-ParameterDefaults` 冒頭(781〜782行目付近、他2つのリストをリセットしている箇所)でも毎回リセットする

`Get-ParameterValueByKey` に `SelectedItem` を読む分岐を追加する。`Get-ToolArguments` / コマンドプレビュー生成ロジックは値取得元を意識しないため変更不要。

---

## 3. perf-monitor 専用パネル

### 3.1 目的

`perf-monitor start` はバックグラウンドで独立プロセス(コレクター)を起動して即座に終了するコマンドであり、GUI の実行中プロセス追跡(`Test-Running` / 停止ボタン)とは別に、「今どのセッションを監視しているか」を GUI 側で保持する必要がある。既存の「スナップショット一括実行」パネル(ヘッダー直下、専用の入力欄+ボタンを持つ帯)と同じパターンを踏襲する。

### 3.2 XAML

`LocalToolsLauncher.xaml` の Grid に新規行(Auto)を追加し、「スナップショット一括実行」パネルの直後・ツール一覧+詳細パネルの直前に配置する。以降の `Grid.Row` (ツール一覧、GridSplitter、ログ、ステータスバー)を1つずつ繰り下げる。

パネル構成(「スナップショット一括実行」と同じ `PanelBorder` スタイル):

- 見出し: `パフォーマンス監視 (perf-monitor)`
- 1行目: `間隔(秒)` テキストボックス(既定 `5`)/ `時間(秒)` テキストボックス(既定 空欄=手動停止まで収集)/ 「開始」ボタン(`PrimaryButton`)
- 2行目: `セッション` ラベル + テキストボックス(開始後に自動入力、手動編集も可)+ `...`(フォルダ選択、`SmallBrowseButton`)+ `開く`(エクスプローラで開く)+ `停止` ボタン(`DangerButton`)

新規 XAML 名前付き要素: `PerfIntervalTextBox`, `PerfDurationTextBox`, `PerfStartButton`, `PerfSessionDirTextBox`, `BrowsePerfSessionDirButton`, `OpenPerfSessionDirButton`, `PerfStopButton`。既存の `$window.FindName('...')` 変数化ブロック(1345〜1370行目相当、`HeaderAwsProfileComboBox` 等を取得している箇所)に、この7要素分の取得コードを追加する。

### 3.3 PowerShell ロジック

新規関数(承認済み動詞を使用)。`Invoke-ToolExecution` の `-ToolArgsFactory` は内部で `& $ToolArgsFactory $runDir` と**位置引数**で呼び出す(999〜1009行目)。既存の `Invoke-CollectSnapshot` / `Invoke-SnapshotReport` がそうしているように、渡す scriptblock は必ず `param($runDir)` を明示すること。これを省略すると `-RunDir` が渡らず `Get-ArtifactsDir` が不正なパスを組み立てる。

```
Get-PerfMonitorStartArguments -RunDir -Tool
  -> @('start') + (Interval/Duration が空でなければ -Interval/-Duration を追加)
     + @('-OutputDir', <artifacts>) + (Add-ConfigFileArgs -Tool $Tool の結果)
     perf_monitor.conf は既存 configFiles 機構をそのまま利用するため、
     呼び出し元で取得した $tool (= Get-ToolById 'perf-monitor') を -Tool として渡す

Get-PerfMonitorStopArguments -RunDir
  -> @('stop', <PerfSessionDirTextBox.Text>)

Invoke-PerfMonitorStart
  -> $tool = Get-ToolById 'perf-monitor'
     Invoke-ToolExecution -Tool $tool -ToolArgsFactory {
         param($runDir) Get-PerfMonitorStartArguments -RunDir $runDir -Tool $tool
     }
     (同期呼び出しのため $tool はクロージャ経由で参照可能。AsyncRunner の
      非同期コールバックにおける GetNewClosure() 禁止ルールとは無関係)

Invoke-PerfMonitorStop
  -> PerfSessionDirTextBox.Text が空なら、Invoke-ToolExecution を呼ばずにその場で
     [System.Windows.MessageBox]::Show('セッションディレクトリを指定してください(開始後に自動入力されます)。')
     を表示して return する。
     (注意: Invoke-ToolExecution 内部の catch (1010〜1016行目) は
      ToolArgsFactory が投げた例外をログ・ステータスバー表示するだけで
      re-throw していないため、呼び出し元で try/catch しても捕まえられない。
      既存 Invoke-SnapshotReport の外側 try/catch は実際には到達しない
      死んだコードであり、本 spec ではこのパターンを踏襲せず、
      検証を Invoke-ToolExecution 呼び出し前に前倒しする)
  -> $tool = Get-ToolById 'perf-monitor'
     Invoke-ToolExecution -Tool $tool -ToolArgsFactory {
         param($runDir) Get-PerfMonitorStopArguments -RunDir $runDir
     }
```

### 3.4 セッションディレクトリの自動検出、および汎用実行パネルとの共有

`PerfMonitor.ps1 start` は `-OutputDir` 直下に `<Prefix>_<timestamp>` という新規サブディレクトリを1つ作成する(ソース確認済み)。GUI 側は `-OutputDir` に実行の `artifacts` ディレクトリを渡すため、実行完了後に `artifacts` 配下を `Get-ChildItem -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1` することで新規セッションディレクトリを特定できる。

既存の `Complete-ToolExecution` にある `collect-snapshot` 専用の自動反映ブロック(生成 ZIP を `SnapshotZipTextBox` に反映する処理)と同じ場所に、`perf-monitor` 用の分岐を追加する:

```
if ($ctx.ToolId -eq 'perf-monitor' -and $null -ne $PerfSessionDirTextBox) {
    artifacts 配下のディレクトリを検索 → 見つかれば
      $PerfSessionDirTextBox.Text = <検出パス>
      $script:LastPerfSessionDir  = <検出パス>   # 新規スクリプト変数(下記)
    → ログ出力
}
```

`stop` 実行時は `artifacts` 配下に新規ディレクトリが作られないため、このブロックは自然に no-op になる(コマンド種別を明示的に判定する必要がない)。

**汎用実行パネルとの共有(レビューで判明した問題への対応)**: 専用パネルの `PerfSessionDirTextBox` と、ツール一覧で `perf-monitor` を選択したときに `Set-ParameterDefaults` が毎回動的生成する汎用パラメータ欄の `sessionDir` テキストボックスは、**別々の WPF コントロールインスタンス**である。これを同期しないと、専用パネルで開始したセッションを汎用の「実行」ボタン(`status`/`report`/`list` アクション)から参照できず、§3.5 で想定している代替導線が機能しない。

これに対応するため、新規スクリプト変数 `$script:LastPerfSessionDir = ''` を導入し、次の一方向同期を行う。

- `Complete-ToolExecution` のセッション自動検出時に `$script:LastPerfSessionDir` も更新する(上記)。
- `Set-ParameterDefaults` で perf-monitor の `sessionDir` パラメータ行を描画する際、カタログの `default`(空文字)の代わりに `$script:LastPerfSessionDir` があればそれを初期値として使う(configFile 連携パラメータ向けの初期値決定(`paramCfgMap` 参照箇所、802〜811行目付近)と同じ場所に、`sessionDir` 用の特別分岐を1つ追加する)。

汎用パネル側での手動編集を専用パネルへ反映する双方向同期は行わない。汎用パネル側は「その1回の実行だけ別のセッションを指定したい」場合の一時的な上書きとして扱う。

### 3.5 スコープ外

- 「状態確認」「レポート生成」用の専用ボタンは追加しない。ツール一覧内の `perf-monitor` を選択し、`select` 化した `アクション` ドロップダウンで `status` / `report` / `list` を選んで通常の「実行」ボタンから実行できる。§3.4 の `$script:LastPerfSessionDir` 同期により、専用パネルで開始した直近セッションのディレクトリが汎用パラメータ欄の初期値として自動的に入る。GUI 起動後に一度も「開始」を押していない場合は汎用パネルの `セッション` 欄は空のままで、`status`/`list` はツール側のデフォルト検索ロジックに委ねられる(必ずしも見つかるとは限らない)。これは対象ツール本体の既存挙動であり、本 spec のスコープ外とする。
- GUI 側でバックグラウンドコレクターの生存監視(ポーリング等)は行わない。あくまで「直近開始したセッションのディレクトリを覚えておく」だけで、実際に動いているかどうかは `status` アクションの実行結果で確認する運用とする。

---

## 4. 変更しない事項

- 上部要素の縦並び順序(タイトル+実行/停止ボタン → 説明 → 設定ファイル → 引数)は現状のまま。
- `configFiles` / `paramKey` によるファイル引数のパス表示+ブラウズ+開くボタンの仕組みは変更しない。新規の `PerfSessionDirTextBox` はフォルダ選択のため既存の `Select-FolderDialog`(設定ダイアログの `ToolsRoot`/`OutputRoot` 選択で使用中)を流用し、ファイル用の `Invoke-SelectConfigFile` とは別経路とする。
- `required: true` パラメータへのデフォルト値付与ルールは、今後カタログにエントリを追加する開発者向けの運用ルールとして本 spec に明記するのみで、既存カタログの変更は行わない。

---

## 5. テスト方針

- 既存 `tests/Xaml.Tests.ps1`(XAML が `XamlReader` で読み込めること)が新しいパネルを含めて通ることを確認する。
- 既存 `tests/Syntax.Tests.ps1`(PowerShell 構文エラーがないこと)が `LocalToolsLauncher.ps1` の変更後も通ることを確認する。
- `tool-catalog.yaml` の `select` エントリについて、`Read-ToolCatalog` 相当のロジックで `Options` が正しくパースされることを目視 or 簡易スクリプトで確認する。
- GUI の実機起動によるビジュアル確認(ドロップダウンの表示、perf-monitor パネルの Start → セッション自動反映 → Stop)は、可能な範囲で `computer-use` 等を用いて行う。実施できない場合は完了報告に残リスクとして明記する。
- 破壊的操作(実際に AWS へアクセスするツール等)は本変更の対象外であり、検証は `perf-monitor` のローカル収集動作(AWS 認証不要)を中心に行う。

---

## 6. 未決事項

なし(ブレインストーミングでの質疑によりすべて解消済み)。

初版に対して architect サブエージェントによる批判的レビューを実施し、以下を修正済み:

- 専用パネルと汎用実行パネルのセッションディレクトリ不同期(§3.4 に `$script:LastPerfSessionDir` 同期を追加)
- `ToolArgsFactory` scriptblock の `param($runDir)` 欠落(§3.3)
- 機能しない「例外→MessageBox」パターンの踏襲(§3.3、検証を呼び出し前に前倒しする方式へ変更)
- `$script:SelectParameterControls` の初期化箇所の明記漏れ(§2)
- 分類ロジック変更が不要である旨の明記漏れ(§2)
- 新規 XAML 要素の `FindName` 取得コード追加箇所の明記漏れ(§3.2)

いずれも重大な設計変更ではなく、実装計画の記述精度を上げるための修正。

---

## 7. v2.5.0 での改訂: 専用パネルの廃止と個別ツールパネルへの統合

v2.4.0 リリース後、ユーザーから「専用パネルと汎用実行パネルでセッション欄・start/stop・Duration が二重に見える」との指摘を受け、§3 の専用パネルを廃止して個別ツールパネル(汎用実行フロー)へ完全統合した。

### 変更内容

- **XAML**: 「パフォーマンス監視(perf-monitor)」パネル(§3.2)と7つの named 要素を削除。Grid.Row 構成を v2.3 以前の6行に戻した
- **PowerShell**: `Get-PerfMonitorStartArguments` / `Get-PerfMonitorStopArguments` / `Invoke-PerfMonitorStart` / `Invoke-PerfMonitorStop` と関連ボタン配線・FindName を削除。`$script:LastPerfSessionDir` と `Set-ParameterDefaults` の sessionDir 初期値シード(§3.4)は存続
- **カタログ**: 新パラメータ型 `directory` を追加(パス入力欄 + `...` フォルダ選択 + `開く` エクスプローラ起動を描画する汎用機構)。perf-monitor の `sessionDir` を `text` → `directory` に変更。`interval`(`-Interval`/`-i`、number、default 空 = ツール既定値)を追加し、旧専用パネルの「間隔(秒)」を代替
- **セッション自動検出**(§3.4)は、専用パネルのテキストボックスの代わりに、perf-monitor 選択中なら汎用パラメータ欄(`Get-ParameterControlByKey -Key 'sessionDir'`)へ直接反映するよう変更。非選択中は `$script:LastPerfSessionDir` 経由で次回描画時に反映(従来どおり)

### 操作フロー(v2.5.0 以降)

- 開始: ツール一覧で perf-monitor を選択 → アクション `start` → 実行。完了後セッション欄に自動入力
- 停止: アクション `stop` → 実行(セッションは自動入力済み)
- 状態確認/レポート: アクション `status` / `report` → 実行

### 既知の許容事項

- セッション欄に値が残った状態で `start` を再実行すると、位置引数としてセッションパスが渡るが、`PerfMonitor.ps1` の `start` は `$SessionDir` を無視するため無害(v2.2〜v2.4 の汎用フローと同じ挙動)
- 2連続 `start`(先行セッションを停止せずに開始)のガードは引き続きスコープ外(§3.5 の方針を踏襲)
