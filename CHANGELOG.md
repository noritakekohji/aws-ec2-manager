# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.0] - 2026-07-02

### Changed
- ランチャーのセクション名を変更: 「スナップショット統合ツール」→
  「スナップショット一括実行」、「ツール」→「ツール個別実行」。
- ヘッダーボタンをアイコン付きに変更し、ラベルと開く先を整理:
  「保存先」→「ツール保存先」（tools を開く）、「ログ」→「出力先」
  （reports を開く）。「設定」にも歯車アイコンを付与。
- ランチャーのログ出力欄を各ツールペイン内から切り出し、ツール一覧と設定ペインの
  下に全幅の共通「ログ出力」ペインとして配置。全ツールで同じ位置・同じ高さになる。
- ランチャー右ペインの並び順を全ツール共通に統一: タイトル/説明 →
  コマンドプレビュー → 設定ファイル → 実行パラメーター。処理ボタン
  （プレビュー更新／実行／停止）はツール名の右側（右寄せ）に配置して専用行を廃止。
- ウィンドウ既定高を 780→860 に拡大（共通ログペイン追加に伴う調整）。
- ランチャーの実行パラメーター欄を動的レイアウト化し、コンソール表示ペインの
  つぶれを緩和。
  - 数字型パラメーター（`type: number`）を短幅フィールドにして横並び（自動折返し）
  - 短い文字列パラメーターに `width: short` を追加し、数字と同じ横並びに集約
    （例: log-collector の プリセット / 期間 / 最大 MB を 1 行、server-snapshot の
    アクション / ラベルを 1 行）
  - チェックボックスも横並びにまとめて行数を削減
  - `paramKey` ルーティングの設定ファイルは、専用行を廃止して該当パラメーター行に
    `...`（選択）と「開く」を統合。同じパスが2か所に出る重複を解消
  - 設定ファイル行のパス欄を編集可能にし、直接入力／`...`選択の両対応

## [1.3.0] - 2026-07-01

### Added
- server-snapshot に `filelist` カテゴリを追加。設定ファイル `filelist.conf` で
  指定したディレクトリ配下のファイル・ディレクトリ一覧を権限・オーナー情報付きで
  収集し、before/after 比較で差分を検出できる。
  - Windows: NTFS Owner / ACL、Linux: POSIX mode / uid / gid / owner / group
  - `hash = true` でファイル sha256 を計算し、内容変化も検出
  - `exclude` パターン、`depth` 制限、`max_entries_per_target` セーフガード対応
- ローカルツールランチャーで、各ツールの設定ファイルを「設定ファイル」セクション
  として表示。「...」でエクスプローラから別ファイルを選択、「開く」で関連付け
  エディタ起動。
  - 選択した override パスは `%LOCALAPPDATA%\aws-ec2-manager\tool-launcher.json`
    に per-tool per-label で永続化
  - routing を `tool-catalog.yaml` の `configFiles` で指定可能
    - `envVar`: 子プロセスの env var で渡す（server-snapshot の
      `_OPS_MW_CONF` / `_OPS_FILELIST_CONF`）
    - `argName`: CLI 引数として付与（log-collector `-ConfigFile`、
      perf-monitor `-Config`）
    - `paramKey`: 既存パラメータ textbox に反映（cert-check / network-check /
      port-inventory のターゲットリスト）

### Changed
- ランチャーの各ツール説明を短い日本語に置き換え、説明欄の余白を詰めて
  スペース節約。

### Fixed
- server-snapshot の compare で Windows 側 filelist エントリの `mode` / `group`
  が `System.Collections.Hashtable` と表示されていた件を修正（`Obj-To-Dict` が
  null 値を空 hashtable に変換する挙動を回避）。
- filelist の symlink `link_target` を PS 5.1 で scalar string として出力
  （元々 `IEnumerable<string>` で配列化されていた）。

## [1.2.2] - 2026-07-01

### Changed
- スナップショット統合ツールのラベルを「出力先」→「**出力対象ZIP**」に変更。実態（レポート生成の入力となる ZIP ファイル）が一目で分かるように
- ラベル列幅 (100→120) とツールチップ文言を統一
- 自動入力時のログメッセージ、未入力時のエラーメッセージも「出力対象ZIP」基準に更新

## [1.2.1] - 2026-07-01

### Fixed
- スナップショット統合ツールで「比較 ZIP」しか入れずに「レポート生成」を押すと「ZIP パスを指定してください。」エラーが出ていた件
  - エラー文を「出力先」基準に書き換え（収集実行で作成された ZIP のパスを指す旨を明記）
  - 「出力先」「比較 ZIP」「差分のみ」「収集実行 / レポート生成」ボタンにツールチップを追加
  - **「収集実行」成功時に、生成された ZIP のフルパスを「出力先」欄に自動入力**するように。続けて「レポート生成」を押すだけでよくなる

## [1.2.0] - 2026-07-01

### Changed
- ローカルツールランチャーのレイアウトを再構成
  - ヘッダーをスリム化し、AWS Profile と「保存先 / ログ / 設定」ボタンのみ常時表示
  - ツールルート・出力保存先・各種フラグは別ウィンドウの設定ダイアログ (`LocalToolsLauncherSettings.xaml`) に集約。`FolderBrowserDialog` で参照可能
  - スナップショット統合ツールセクションをヘッダー直下に独立配置
  - 「出力先」「比較 ZIP」に `OpenFileDialog` 連動の `...` 参照ボタンを追加
  - 左ペインにツール一覧、右ペインに実行パラメータ・コマンドプレビュー・実行/停止・ログを集約

## [1.1.0] - 2026-07-01

### Added
- ローカルツールランチャー（Windows WPF / Linux Bash）を追加。`tools/` 配下の運用ツールをサーバー上でローカル実行するための独立 GUI / CLI
  - `LocalToolsLauncher.ps1` / `LocalToolsLauncher.xaml` / `launch-tools.bat`: PowerShell 5.1 + WPF の独立ランチャー。バックグラウンド Runspace + DispatcherTimer によるノンブロッキング実行、Stop ボタン、stdout/stderr の UTF-8 エンコーディング指定、出力集約レイアウト（`reports/local-tools/<tool>/<timestamp>/`）
  - `tools/tool-catalog.yaml`: Windows / Linux の入口パスと GUI 入力欄を統合した共通カタログ。インデント幅判定方式の最小 YAML パーサで読み込み
  - `local-tools-launcher.sh`: Linux 対話式 CLI の暫定版。Windows 版確定後に同仕様で書き直す予定
- `docs/superpowers/specs/2026-06-29-local-tools-launcher.md` / `docs/superpowers/plans/2026-06-29-local-tools-launcher.md`: 仕様と実装計画

### Changed
- `.gitignore`: `reports/local-tools/` をランチャー実行ログとして無視

## [1.0.0] - 2026-06-27

### Changed
- GUI 全体をダークテーマに刷新し、ヘッダー、タブ、ボタン、DataGrid、ListBox、ステータスバーの視認性と操作感を改善
- メインウィンドウの初期サイズと最小サイズを調整し、EC2 / SG / SSM 各タブのレイアウト密度を改善

## [0.2.0] - 2026-06-26

### Added
- `Logger.psm1` モジュールを新規追加（`Initialize-AppLogger` / `Write-AppLog`）。`[yyyy-MM-dd HH:mm:ss] [LEVEL] メッセージ` 形式でプレーンテキストファイルに追記
- 設定ダイアログに「ログ出力先ファイルのパス」フィールドと参照ボタンを追加。空欄でログ無効
- `AppSettings.psm1` に `LogPath` フィールドを追加（`settings.json` に永続化）
- 操作ログ: プロファイル読込・選択、SSO トークン確認、SSO ログイン、インスタンス取得・起動・停止・再起動、SG 適用、SSM タスク実行の各操作を INFO/WARN/ERROR レベルで記録
- 設定変更時にログを再初期化するため、アプリ再起動なしにログパスを変更可能
- `docs/samples/aws-config.example` / `docs/samples/aws-credentials.example` を追加（SSO セッション参照 / レガシー SSO / IAM Access Key / デフォルト / AssumeRole の各書き方サンプル）
- ヘッダに「SSO ログイン」ボタンを追加。選択中プロファイルで `aws sso login --profile <name>` を別ウィンドウ起動する（ブラウザ承認後「トークン確認」を押せばトークン状態を確認できる）
- ヘッダに「開く」ボタンを追加。AWS config を notepad で開く（config が無ければそのディレクトリをエクスプローラで開くフォールバック）
- ヘッダに「設定」ボタンを追加。`%LOCALAPPDATA%\aws-ec2-manager\settings.json` に AWS config ファイルのパスを保存し、`$env:AWS_CONFIG_FILE` 経由で `aws.exe` サブプロセスにも伝搬。`AppSettings.psm1` モジュール (`Get-AppSettings` / `Save-AppSettings` / `Get-EffectiveAwsConfigPath`) を新規追加
- `AwsConfig.psm1` の `Get-DefaultConfigPath` が `$env:AWS_CONFIG_FILE` を尊重するように変更

### Fixed
- `aws` CLI の stderr（`Unable to parse config file: ...` など）がそのままコンソールに漏れていた問題を修正。`Invoke-AwsCli` を `2>&1` でstderrをキャプチャするように変更し、`Stderr` フィールドとして返すようにした（`AwsConfig.psm1` / `AwsManager.psm1` 両方）
- YAML ファイル読み込みが PS 5.1 既定の CP932 デコードで日本語が文字化けしていた問題を修正（`Get-Content -Raw -Encoding UTF8` に変更、`Get-SsmYamlList` / `Invoke-SsmTask` 両方）
- Tab3 で YAML が 1 件しかない場合に `Update-YamlListBoxForInstance` が PSCustomObject を ItemsSource に渡してしまい「PSCustomObject を IEnumerable に変換できません」例外が出ていた問題を修正
- `Get-AwsProfileDetail` が AWS CLI v2 形式 (`sso_session` 参照) のプロファイルで `sso_start_url` を `[sso-session <name>]` ブロックから解決するように修正
- `App.ps1` でプロファイル ComboBox に "String[] Array" と 1 項目だけ表示される問題を修正
- `Test-SsoToken` が `aws` CLI に引数を単一の連結文字列として渡してしまい `ParamValidation` エラーになっていた問題を修正
- `App.ps1` の Tab1/2/3 で unary-comma 返り値が二重ラップされていた問題を修正

## [0.1.0] - 2026-06-25

### Added
- `AwsConfig.psm1` モジュール: `Get-AwsProfiles` / `Get-AwsProfileDetail` / `Test-SsoToken` と Pester テスト
- `AwsManager.psm1` モジュール: EC2 列挙 / 起動・停止・再起動 / SG 取得・割当 / SSM Run Command (`Invoke-SsmTask`) と最小 YAML パーサ、Pester テスト
- `MainWindow.xaml` / `App.ps1` / `launch.bat`: WPF メインウィンドウ骨組み（プロファイル選択・SSO トークン確認・3 タブ構成のスタブ）
- Tab1（EC2 インスタンス管理）: DataGrid によるインスタンス一覧表示と更新 / 起動 / 停止 / 再起動ボタン（確認ダイアログ付き）
- Tab2（セキュリティグループ管理）: インスタンス選択 + 適用済み/未適用 SG の 2 ペイン UI、`<` / `>` ボタンで移動、`modify-instance-attribute` 経由で diff 確認後に適用
- Tab3（ツール実行）: `ssm-tasks/{linux,windows}` 配下の YAML を一覧表示し、選択インスタンスで `Invoke-SsmTask` を実行。`output: text` は TextBox に、`output: html` は `%TEMP%\aws-ec2-manager` に書き出して Edge で表示。サンプル YAML `ssm-tasks/linux/network-check.yaml` を追加
- プロジェクト初期化
- `ops-scripts-template/tools/` から 8 ツールを移植
  (aws-instance-audit / cert-check / collect-snapshot / log-collector /
   network-check / perf-monitor / port-inventory / server-snapshot)

### Changed
- `AwsConfig.psm1` の `Invoke-AwsCli` が `[PSCustomObject]` (`ExitCode` / `Output` / `Success`) を返すように変更。`$global:LASTEXITCODE` をヘルパー内部で捕捉し、呼び出し側で参照する必要をなくした
- `Get-Ec2Instances` の返すオブジェクトに `SecurityGroupIds` (string[]) プロパティを追加（describe-instances の `SecurityGroups[].GroupId` を抽出）
- `AwsManager.psm1` が `ConvertFrom-MinimalYaml` を export するように変更（App.ps1 の YAML スキャンから利用）。併せて単体テスト 2 件を追加
