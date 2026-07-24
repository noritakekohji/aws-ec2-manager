# File Transfer Check (SMB 往復疎通確認)

お客様端末からサーバの SMB 共有へ**テストファイルを実際に往復転送**し、
転送可否・整合性(SHA-256)・スループット(MB/s)を確認するスタンドアロンツールです。
**このフォルダ一式をコピーするだけで動きます。**

> 注意: 本ツールは他の `tools/` 配下ツールと異なり、**SSM ではなくお客様端末で直接実行**します。
> パスワード入力プロンプトが発生するため、意図的に GUI ツールランチャーからは起動できない構成
> (`menu: false`)にしています。Windows は bat をダブルクリック、Linux は sh を直接実行してください。

## 構成

```
tools/file-transfer-check/
├── Check-FileTransfer.ps1   # Windows 本体 (PowerShell 5.1)
├── Check-FileTransfer.bat   # Windows 起動用バッチ
├── check_file_transfer.sh   # Linux 本体 (smbclient)
├── shares.lst               # 対象共有リスト (サンプル)
└── README.md
```

## リスト形式 (shares.lst)

```
# <share-unc>, <username>, <expected>, <description>
#   username : 空欄=ログインユーザー(統合認証) / DOMAIN\user=専用ユーザー(実行時にPW入力)
#   expected : ok(転送できるはず) / ng(できないはず) / -(評価しない)
\\filesv01\upload,           , ok, 業務ファイル受け渡し共有
\\filesv01\readonly, svc_check, ng, 読取専用のはず
```

- パスワードはリストに書きません。専用ユーザー行があれば実行時に一度だけ入力を求めます。
- 注意: `description` に `#` を含めるとコメントとして切り詰められます。

## 使い方

### Windows
```
:: bat 冒頭の SET ブロックで既定値を設定してダブルクリック、
:: または追加引数を渡して上書き
Check-FileTransfer.bat -SizeMB 50 -HtmlReport report.html
```
ログは `Check-FileTransfer_<日時>.log` に記録されます。

### Linux
```bash
chmod +x check_file_transfer.sh   # 初回のみ
./check_file_transfer.sh -l shares.lst -s 10 -o report.html
```
前提: `smbclient` / `sha256sum` / `dd`。未導入なら終了コード 10。

## オプション

| Windows | Linux | 意味 | 既定 |
|---|---|---|---|
| `-ShareList` | `-l` | 対象リスト | 隣の shares.lst |
| `-SizeMB` | `-s` | テストサイズ MB | 10 |
| `-TimeoutSec` | `-t` | タイムアウト秒 | 60 |
| `-HtmlReport` | `-o` | HTML 出力 | なし |
| `-FailOnly` | `-f` | 失敗のみ表示 | off |

> `-TimeoutSec` は Linux (smbclient) では厳密に適用されます。Windows では OS の
> SMB タイムアウトに従うため実効的に効きにくい点に注意してください。

> Linux で統合認証(username 空欄)を使うには Kerberos チケット(`kinit`)が必要です。
> チケットが無い場合その行はスキップされます。非ドメイン端末では username を指定してください。

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 全て OK |
| 1 | NG または Warning あり |
| 2 | リストファイルが無い |
| 10 | 前提コマンドが無い |

## 手動結合テスト手順

実 SMB 共有が必要なため自動テストはありません。検証環境で以下を確認します。

1. 書込可能な共有を `expected=ok` で登録し、`OK` + 上下 MB/s が出ること。
2. 読取専用の共有を `expected=ng` で登録し、書込拒否→`OK`(期待どおり)になること。
3. 実行後、リモートに `conntest_*.tmp` が残っていないこと(後始末)。
4. 専用ユーザー行で PW プロンプトが一度だけ出ること。同一ユーザーの複数行で再入力されないこと。
5. HTML レポートにパスワードが一切含まれないこと。
6. 単体テスト: リポジトリルートで `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`(純ロジック)。
