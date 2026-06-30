# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
