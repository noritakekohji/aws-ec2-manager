# aws-ec2-manager — 仕様書

**日付**: 2026-06-25
**バージョン**: 0.1.0

---

## 1. 目的

AWS EC2 を管理する Windows 11 / AVD 向けの WPF GUI ツール。
PowerShell 5.1 + XAML + AWS CLI v2（SSO プロファイル）+ SSM Run Command で構成し、
EC2 / セキュリティグループ / 各サーバ配備済みの運用スクリプトを 1 つのウィンドウから操作する。

CLI で AWS CLI を叩く手順を画面化することで、操作ミスと手順書参照を減らす。
SSH を使わず SSM 経由でリモート実行するため、踏み台や鍵管理が不要。

---

## 2. 動作環境

| 項目 | 値 |
|---|---|
| OS | Windows 11 / Azure Virtual Desktop |
| シェル | PowerShell 5.1（OS 同梱） |
| GUI フレームワーク | WPF（System.Windows） |
| 認証 | AWS CLI v2 + SSO |
| リモート実行 | AWS Systems Manager Run Command |

PS7 専用機能（`??` / `?:` / `?.` / `utf8NoBOM` 等）は使わない。
`.ps1` / `.psm1` は **UTF-8 BOM 付き**、`.sh` は **BOM なし + LF**、`.bat` は **CRLF**。

---

## 3. 機能要件

### 3.1 プロファイル管理

- `~/.aws/config` を読み、定義済みプロファイル一覧をドロップダウン表示
- 選択変更時に `aws sts get-caller-identity --profile <name>` で SSO トークンの有効性確認
- 無効ならステータスバーに警告表示、`aws sso login` をユーザに促す
- 選択中プロファイルの SSO URL / リージョン / アカウント ID をヘッダに表示

### 3.2 EC2 インスタンス管理（Tab 1）

- `aws ec2 describe-instances` の結果をテーブル表示
  - 列: Name タグ / InstanceId / State / InstanceType / AZ / PrivateIp / PublicIp / Platform
- 行選択 → 「起動」「停止」「再起動」ボタン
- アクションは `aws ec2 start-instances` / `stop-instances` / `reboot-instances`
- 「更新」ボタンで再取得
- 起動・停止は **ユーザ確認ダイアログ** を挟む

### 3.3 セキュリティグループ管理（Tab 2）

- インスタンス選択（Tab 1 と連動 or 別ドロップダウン）
- そのインスタンスの **VPC 内 SG 全リスト** を取得
- 左ペイン: **適用済み SG**、右ペイン: **未適用 SG**（VPC 内）
- `>` / `<` ボタンで付け外し
- 「適用」ボタンで `aws ec2 modify-instance-attribute --groups <ID...>` を実行
  （部分更新 API がないため、リスト全体を置換する）
- 適用前に確認ダイアログで diff（追加 / 削除）を表示

### 3.4 ツール実行 / SSM Run Command（Tab 3）

- インスタンス選択 → そのインスタンスの Platform（Linux / Windows）に応じて
  `ssm-tasks/linux/*.yaml` または `ssm-tasks/windows/*.yaml` を一覧表示
- YAML を選択 → 「実行」ボタンで `aws ssm send-command` を発行
- ドキュメント:
  - Linux: `AWS-RunShellScript`
  - Windows: `AWS-RunPowerShellScript`
- ポーリングで `get-command-invocation` を呼び、完了を待つ
- YAML の `output` 種別で表示方法を分岐:
  - `text` → WPF TextBox（モノスペースフォント）に表示
  - `html` → `%TEMP%/aws-ec2-manager/<task>-<timestamp>.html` に書き出し、
    `Start-Process msedge.exe <path>` で Edge で開く

### 3.5 SSM YAML フォーマット

```yaml
name: ネットワーク確認        # GUI に表示する名前
description: 外部疎通・DNS を確認
output: text                  # text または html
platform: Linux               # Linux または Windows（ディレクトリで決まるが冗長性のため）
timeout: 60                   # 秒（任意、デフォルト 300）
script: |
  curl -s --max-time 5 https://example.com
  dig +short example.com
```

最小要件: `name` / `output` / `script`。`description` / `timeout` / `platform` は任意。

YAML は **GUI 起動時にスキャン**して読み込む（再読込ボタンも提供）。
`script` 本体は **配備済み tools/ のスクリプトを呼ぶラッパー** にすることを基本とする。

例（Linux）:
```yaml
name: ネットワーク疎通チェック
output: text
script: |
  cd /opt/ops-scripts/tools/network-check
  bash check_network_connectivity.sh --target-list targets.lst
```

---

## 4. アーキテクチャ

### 4.1 ディレクトリ構成

```
aws-ec2-manager/
├── App.ps1                  # 起動エントリポイント
├── MainWindow.xaml          # WPF UI
├── AwsManager.psm1          # EC2 / SG / SSM 操作
├── AwsConfig.psm1           # ~/.aws/config パーサ・SSO 確認
├── launch.bat               # ダブルクリック起動用
│
├── tools/                   # 各サーバへ配備する運用スクリプト群（8 ツール）
│   ├── aws-instance-audit/  ※ Tab1 の Audit ボタンで GUI ローカル実行も可能
│   ├── cert-check/
│   ├── collect-snapshot/
│   ├── log-collector/
│   ├── network-check/
│   ├── perf-monitor/
│   ├── port-inventory/
│   └── server-snapshot/
│
├── ssm-tasks/               # GUI が SSM 経由で呼ぶ YAML 定義
│   ├── linux/
│   └── windows/
│
├── tests/                   # Pester
│   ├── AwsConfig.Tests.ps1
│   └── AwsManager.Tests.ps1
│
├── docs/superpowers/
│   ├── specs/
│   └── plans/
│
├── VERSION / CHANGELOG.md / README.md / CLAUDE.md / LICENSE
├── .gitignore / .gitattributes
└── .github/workflows/ci.yml
```

### 4.2 モジュール責務

**`AwsConfig.psm1`** — `~/.aws/config` の読み込みと SSO 状態確認

| 関数 | 役割 |
|---|---|
| `Get-AwsProfiles` | プロファイル名一覧を返す |
| `Get-AwsProfileDetail -Name <string>` | SSO URL / リージョン / アカウント ID |
| `Test-SsoToken -Name <string>` | `aws sts get-caller-identity` 成功で `$true` |

**`AwsManager.psm1`** — AWS 操作ラッパー（EC2 / SG / SSM）

| 関数 | 役割 |
|---|---|
| `Get-Ec2Instances` | `describe-instances` の整形済み配列を返す |
| `Start-Ec2Instance -InstanceId <id>` | 起動 |
| `Stop-Ec2Instance -InstanceId <id>` | 停止 |
| `Restart-Ec2Instance -InstanceId <id>` | 再起動 |
| `Get-VpcSecurityGroups -VpcId <id>` | VPC 内 SG 一覧 |
| `Set-InstanceSecurityGroups -InstanceId <id> -GroupIds <id[]>` | SG 置換 |
| `Invoke-SsmTask -InstanceId <id> -YamlPath <path>` | SSM Run Command 実行・結果取得 |

**`App.ps1`** — XAML 読込・イベント配線・ウィンドウ起動

### 4.3 AWS CLI 呼び出し方針

- すべての AWS CLI 呼び出しに `--profile $SelectedProfile --output json` を付与
- JSON は `ConvertFrom-Json` でオブジェクト化
- エラーは `$LASTEXITCODE -ne 0` で検出し、stderr をダイアログで表示
- 重い呼び出し（describe-instances 等）は **非同期**化を検討（PS5.1 では `Start-Job` ではなく Runspace を使う）

---

## 5. 非機能要件

| 項目 | 要件 |
|---|---|
| 起動時間 | 5 秒以内（プロファイル一覧読込まで） |
| EC2 一覧取得 | 3 秒以内（〜50 インスタンス想定） |
| SSM 実行 | タイムアウト既定 300 秒。YAML で上書き可能 |
| ログ | `%LOCALAPPDATA%/aws-ec2-manager/log/app-YYYYMMDD.log` |
| エラーハンドリング | AWS CLI 非ゼロ exit はモーダルで表示し操作続行可能に |

---

## 6. テスト戦略

- Pester で AwsConfig / AwsManager の単体テスト
- AWS CLI 呼び出しは `Mock` で偽装（実 AWS には触らない）
- WPF イベントハンドラはテスト対象外（手動確認）
- CI（GitHub Actions）で Pester + PSScriptAnalyzer 実行

---

## 7. 制約・前提

- **EC2 に SSM Agent と適切な IAM Role が設定済み**であること
  （AmazonSSMManagedInstanceCore 相当）
- **tools/ 配下のスクリプトは各サーバの所定のパスに配備済み**であること
- `tools/` 自体の中身改修は本ツールの範囲外（`ops-scripts-template` 由来の規約に従う）

---

## 8. スコープ外（将来検討）

- 複数アカウント間の AssumeRole
- インスタンス新規作成・タイプ変更
- CloudWatch メトリクスのグラフ表示
- 操作履歴の永続化（DB 化）
- WSL / Linux 上での動作

---

## 9. 参照

- 移植元: `C:\Users\kohji\data\ai-work\projects\ops-scripts-template\tools\`
- AWS CLI Reference: https://docs.aws.amazon.com/cli/latest/reference/ec2/
- SSM Run Command: https://docs.aws.amazon.com/systems-manager/latest/userguide/execute-remote-commands.html
