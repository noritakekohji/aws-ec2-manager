# aws-ec2-manager

AWS EC2 インスタンスを Windows 11 / AVD 上から GUI で操作する WPF ツール。
PowerShell 5.1 + XAML で実装し、AWS CLI（SSO プロファイル）と SSM Run Command
を組み合わせて、EC2 / セキュリティグループ / インスタンスロール / 配備済み運用スクリプトを 1 画面で扱う。

v2.0 でマスター/ディテール型 UI に全面再構成。左ペインのインスタンス一覧で選択すると、
右ペインの全タブ(詳細 / SG / ロール / ツール実行)が追従する。AWS 呼び出しはすべて
バックグラウンド実行され、UI はフリーズしない(実行中はキャンセル可能)。

## 主な機能

- **インスタンス一覧(左ペイン)**: Name / ID / IP の部分一致フィルタ、起動 / 停止 / 再起動、ロック / ロック解除
- **詳細タブ**: 選択インスタンスの全プロパティ表示(行ダブルクリックで値コピー)
- **セキュリティグループ**: VPC 内 SG リストから選択して `modify-instance-attribute` で置換。適用前に実効ルール差分をプレビュー、HTML レポート出力
- **インスタンスロール**: 適用予定を作ってから `適用` で IAM Instance Profile をアタッチ / デタッチ / 入れ替え
- **ツール実行（SSM）**: `ssm-tasks/{linux,windows}/*.yaml` の定義から選択して SSM Run Command で実行
  - 結果 `text` → WPF TextBox 表示
  - 結果 `html` → 一時ファイルに書き出して Edge で開く
  - 実行中の途中経過表示とキャンセル(リモート側も `cancel-command`)
- **SSM ログイン**: Session Manager の対話セッションを別ウィンドウで開始(要 [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html))
  - Linux は対象 OS ユーザーを指定可能(`sudo su - <user>` 方式)。空欄なら既定の `ssm-user`
  - Windows はユーザー指定不可(ssm-user 固定)
- **ロック**: 操作してはいけないインスタンスを登録し、電源操作 / SG 適用 / ロール適用 / SSM 実行をブロック(設定に永続化)
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

`~/.aws/config` / `~/.aws/credentials` の書き方サンプルは
[docs/samples/aws-config.example](docs/samples/aws-config.example) /
[docs/samples/aws-credentials.example](docs/samples/aws-credentials.example) を参照。
デフォルト以外のパスに置きたい場合は GUI の「設定」ボタン、または環境変数
`AWS_CONFIG_FILE` で指定できます。

## 使い方

`launch.bat` をダブルクリックで GUI 起動。
`launch-tools.bat` でローカルツールランチャー(tools/ 配下の運用スクリプトをローカル実行)を起動。

Linux サーバー上では `local-tools-launcher.sh` を使用:

```bash
bash local-tools-launcher.sh                 # 対話メニュー(Enter で既定値実行 / e で編集)
bash local-tools-launcher.sh list            # ツール一覧 (TSV)
bash local-tools-launcher.sh run cert-check --set timeoutSec=5   # 非対話実行
bash local-tools-launcher.sh run cert-check --dry-run            # コマンド確認のみ
bash local-tools-launcher.sh archive cert-check                  # 最新 run を tar.gz 化
```

HTML レポートは Linux では開かず、run 出力(tar.gz)を Windows へ持ち帰って
Windows 版ランチャーの「スナップショット一括実行 → レポート生成」等で確認する。
プロファイルを選択 → タブで操作対象を切替（インスタンス / SG / インスタンスロール / ツール）。

詳細は [`docs/superpowers/specs/`](docs/superpowers/specs/) を参照。

## ディレクトリ構成

```
.
├── App.ps1                  # エントリ（モジュール/XAML 読み込み + src/ の配線）
├── MainWindow.xaml          # UI レイアウト（マスター/ディテール）
├── src/
│   ├── AsyncRunner.ps1      # イベント駆動の非同期実行基盤（Runspace + Dispatcher push）
│   ├── AppState.ps1         # 選択状態・フィルタ・ロック・キャッシュの一元管理
│   ├── UiCommon.ps1         # 共通 UI ヘルパ（ビジー制御・確認ダイアログ等）
│   ├── HeaderPane.ps1       # プロファイル / SSO / 設定
│   ├── InstanceListPane.ps1 # 左ペイン（一覧・フィルタ・電源・ロック）
│   ├── DetailTab.ps1        # 詳細タブ
│   ├── SgTab.ps1            # セキュリティグループタブ
│   ├── RoleTab.ps1          # インスタンスロールタブ
│   └── SsmTab.ps1           # ツール実行（SSM）タブ
├── AwsManager.psm1          # EC2 / SG / SSM 操作（キャンセルチャネル対応）
├── AwsConfig.psm1           # プロファイル管理
├── launch.bat
├── tools/                   # 各サーバへ配備する運用スクリプト群（PS1/sh/bat）
│   └── env-doc/             # 集約側で動く環境定義書ジェネレータ（HTML 出力）
├── ssm-tasks/{linux,windows}/  # GUI から呼ぶ SSM YAML 定義
├── tests/                   # Pester
└── docs/superpowers/        # spec / plan
```

## バージョン

現在: **2.12.0** — 変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照。

## ライセンス

[MIT](LICENSE)
