# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `docs/samples/aws-config.example` / `docs/samples/aws-credentials.example` を追加（SSO セッション参照 / レガシー SSO / IAM Access Key / デフォルト / AssumeRole の各書き方サンプル）
- ヘッダに「SSO ログイン」ボタンを追加。選択中プロファイルで `aws sso login --profile <name>` を別ウィンドウ起動する（ブラウザ承認後「トークン確認」を押せばトークン状態を確認できる）
- ヘッダに「開く」ボタンを追加。AWS config を notepad で開く（config が無ければそのディレクトリをエクスプローラで開くフォールバック）
- ヘッダに「設定」ボタンを追加。`%LOCALAPPDATA%\aws-ec2-manager\settings.json` に AWS config ファイルのパスを保存し、`$env:AWS_CONFIG_FILE` 経由で `aws.exe` サブプロセスにも伝搬。`AppSettings.psm1` モジュール (`Get-AppSettings` / `Save-AppSettings` / `Get-EffectiveAwsConfigPath`) を新規追加
- `AwsConfig.psm1` の `Get-DefaultConfigPath` が `$env:AWS_CONFIG_FILE` を尊重するように変更

### Fixed
- `Get-AwsProfileDetail` が AWS CLI v2 形式 (`sso_session` 参照) のプロファイルで `sso_start_url` を `[sso-session <name>]` ブロックから解決するように修正。これにより `bedrock` 等の SSO セッション参照プロファイルでヘッダの SSO URL が空になっていた問題を解消
- `App.ps1` でプロファイル ComboBox に "String[] Array" と 1 項目だけ表示される問題を修正（`@(Get-AwsProfiles)` のラップで二重配列になっていたため、`[string[]]` キャストに変更）
- `Test-SsoToken` が `aws` CLI に引数を単一の連結文字列として渡してしまい `ParamValidation` エラーになっていた問題を修正（`Invoke-AwsCli @(...)` を `Invoke-AwsCli -Arguments @(...)` に変更）。引数形状を検証する Pester テストも追加
- `App.ps1` の `@(Get-Ec2Instances)` / `@(Get-VpcSecurityGroups)` / `@(Get-SsmYamlList)` 全 5 箇所が unary-comma 返り値を「1 要素 = 配列まるごと」に二重ラップしてしまい、Tab1 DataGrid / Tab2,3 ComboBox / Tab3 YAML 一覧が表示されなかった問題を修正（`[object[]]` キャストに統一）

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
