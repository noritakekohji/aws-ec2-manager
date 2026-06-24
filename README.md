# aws-ec2-manager

AWS EC2 インスタンスを Windows 11 / AVD 上から GUI で操作する WPF ツール。
PowerShell 5.1 + XAML で実装し、AWS CLI（SSO プロファイル）と SSM Run Command
を組み合わせて、EC2 / セキュリティグループ / 配備済み運用スクリプトを 1 画面で扱う。

## 主な機能

- **インスタンス管理**: 一覧表示 / 起動 / 停止
- **セキュリティグループ**: VPC 内 SG リストから選択して `modify-instance-attribute` で置換
- **ツール実行（SSM）**: `tools/{linux,windows}/*.yaml` の定義から選択して SSM Run Command で実行
  - 結果 `text` → WPF TextBox 表示
  - 結果 `html` → 一時ファイルに書き出して Edge で開く
- **プロファイル管理**: `~/.aws/config` を読みドロップダウン表示。SSO トークン有効性を再確認

## セットアップ

前提:
- Windows 11 / AVD
- PowerShell 5.1（OS 標準）
- AWS CLI v2（SSO 認証）

```powershell
# プロファイル確認
aws configure list-profiles
aws sso login --profile <profile>

# 起動
.\launch.bat
```

## 使い方

`launch.bat` をダブルクリックで GUI 起動。
プロファイルを選択 → タブで操作対象を切替（インスタンス / SG / ツール）。

詳細は [`docs/superpowers/specs/`](docs/superpowers/specs/) を参照。

## ディレクトリ構成

```
.
├── App.ps1                  # WPF 起動・イベントハンドラ
├── MainWindow.xaml          # UI レイアウト
├── AwsManager.psm1          # EC2 / SG / SSM 操作
├── AwsConfig.psm1           # プロファイル管理
├── launch.bat
├── tools/                   # 各サーバへ配備する運用スクリプト群（PS1/sh/bat）
├── ssm-tasks/{linux,windows}/  # GUI から呼ぶ SSM YAML 定義
├── tests/                   # Pester
└── docs/superpowers/        # spec / plan
```

## バージョン

現在: **0.1.0** — 変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照。

## ライセンス

[MIT](LICENSE)
