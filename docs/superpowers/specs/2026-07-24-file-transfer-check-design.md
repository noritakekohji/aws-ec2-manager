# file-transfer-check 設計書

- 作成日: 2026-07-24
- ステータス: ドラフト（ユーザー承認済み・実装プラン待ち）
- 対象: `tools/file-transfer-check/`

## 1. 目的と利用シナリオ

システムに詳しくないお客様が、**自端末からサーバの SMB 共有へ実際にテストファイルを往復転送**し、
「転送できるか／整合性が保たれるか／どの程度の速度が出るか」をワンクリックで確認するツール。

- 利用者はお客様（非技術者）。運用者が事前に対象共有リストと bat の設定を用意する。
- お客様は起動用 bat をダブルクリックするだけ（Windows）。Linux は同一仕様の shell スクリプト。
- 既存 `tools/network-check` と同じ「フォルダ一式コピーで動く」自己完結スタイルを踏襲する。

### 既存ツールとの位置づけの違い

`tools/` 配下の既存 8 ツールは**サーバ側に配備し SSM 経由**で実行する。
本ツールは例外で、**お客様端末（クライアント側）で直接実行**し、そこからサーバへの疎通を確認する。
SSM は介さない。ただしファイル構成・リスト形式・出力・終了コードの規約は既存ツールに揃える。

## 2. 確認方式（確定事項）

| 項目 | 決定 |
|---|---|
| 確認レベル | 実際に往復転送（アップロード→ダウンロード→整合性照合→後始末） |
| プロトコル | SMB（445）のみ。SFTP 等は対象外（将来拡張余地は名前で残す） |
| 認証 | 統合認証（ログインユーザー）と専用ユーザー（ユーザー名/パスワード）の両対応 |
| パスワード | 実行時に非エコー入力。平文保存・ログ出力は一切しない |
| 対象数 | リストファイルで複数指定 |
| テストファイル | サイズ指定可能。転送時間からスループット（MB/s）も算出 |
| 対応 OS | Windows（PS 5.1）／ Linux（smbclient）、同一仕様 |

## 3. 構成ファイル

```
tools/file-transfer-check/
├── Check-FileTransfer.ps1     # Windows 本体（PowerShell 5.1、UTF-8 BOM 付き）
├── Check-FileTransfer.bat     # Windows 起動用バッチ（CRLF）
├── check_file_transfer.sh     # Linux 本体（Bash + smbclient、UTF-8 BOM なし + LF）
├── shares.lst                 # 対象共有リスト（サンプル、UTF-8 BOM なし + LF）
└── README.md
```

## 4. リストファイル形式（`shares.lst`）

4 フィールドの CSV 風形式。`#` 始まりはコメント。**パスワードは書かない**（実行時入力）。

```
# <share-unc>, <username>, <expected>, <description>
#   share-unc: 共有の UNC パス（\\server\share または \\server\share\subdir）
#              Linux では //server/share 形式でも受け付ける（内部で正規化）
#   username : 空欄=ログインユーザー(統合認証) / "DOMAIN\user" or "user"=専用ユーザー(実行時にPW入力)
#   expected : ok(転送できるはず) / ng(できないはず) / -(評価しない)
#   description: 説明（任意）

\\filesv01\upload,           , ok, 業務ファイル受け渡し共有
\\filesv01\readonly, svc_check, ng, 読取専用のはず(書込失敗を期待)
```

- UNC パスにカンマは含まれないため、区切りはカンマで問題ない。
- `username` に `DOMAIN\user` のようにバックスラッシュが含まれてよい。
- 各フィールドは前後空白をトリムする。

## 5. 往復転送の手順（1 共有あたり）

1. **接続**
   - Windows・統合認証（username 空欄）: 現在のログインユーザーで UNC を直接利用。
   - Windows・専用ユーザー: `New-PSDrive -Root <UNC> -Credential <PSCredential>` でマウントして利用。
   - Linux・統合認証（username 空欄）: Kerberos チケットがあれば `smbclient -k` を使用。
     チケットが無い場合、Linux 端末では統合認証は成立しないため、その行は
     **設定エラーとして Warning + スキップ**し、レポートに「Linux では username 指定が必要」と明示する
     （多くのお客様 Linux 端末は非ドメイン参加のため）。
   - Linux・専用ユーザー: `smbclient //server/share -U user`（パスワードは認証ファイル経由、6 項参照）。
2. **テストファイル生成**: サイズ N MB のランダムバイト列をローカル一時ファイルに作成し、ハッシュ（SHA-256）を算出。
3. **アップロード**: リモートへ `conntest_<yyyyMMdd-HHmmss>_<乱数>.tmp` として書き込み。所要時間から上り MB/s を算出。
4. **ダウンロード**: 別のローカル一時ファイルへ読み戻す。所要時間から下り MB/s を算出。
5. **整合性検証**: ダウンロードしたファイルのハッシュが元ファイルと一致するか照合。
6. **後始末**: リモート一時ファイルとローカル一時ファイルを削除。削除失敗は Warning（判定は落とさない）。
7. **判定**: expected（ok/ng）と実結果を突合。
   - expected=ok: 往復成功かつ整合一致 → OK、失敗 → NG
   - expected=ng: 往復が失敗（書込拒否など）→ OK（期待どおり到達不可）、成功してしまった → NG
   - expected=-: 実結果をそのまま表示（評価しない）

### タイムアウト

`-TimeoutSec`（既定 **60 秒**、接続および各転送に適用）。初回接続やサイズの大きいテストファイルで
遅延しても打ち切られないよう、余裕を持たせた既定値とする。
関連メモ: この環境の AWS CLI は非常に低速（[[aws-env-slow-cli]]）。ただし本ツールは SMB 直接転送で
AWS CLI を介さないため影響は限定的。

## 6. パスワードの扱い（セキュリティ）

- 専用ユーザーの行が 1 件でもあれば、**同一ユーザー名につき実行中 1 回だけ**パスワードを入力させる。
  - Windows: `Read-Host -AsSecureString`。`New-PSDrive` には `PSCredential` で渡す。
  - Linux: `read -s`。smbclient には `-U 'user%pass'` を**プロセス引数ではなく認証ファイル**（`--authentication-file`、実行後即削除）または環境変数経由で渡し、`ps` から見えないようにする。
- パスワードはメモリ上のみ。**平文でファイルに書かない・ログに出さない・HTML に出さない**。
- 一時的な認証ファイルを使う場合は、パーミッションを絞り（600）、処理後に確実に削除する。

## 7. 出力・終了コード（既存踏襲）

### コンソール出力（イメージ）

```
[SHARE] \\filesv01\upload  (業務ファイル受け渡し共有)
  Auth   : integrated (current user)
  Upload : OK   10.0 MB / 1.2s = 8.3 MB/s
  Download: OK  10.0 MB / 0.9s = 11.1 MB/s
  Verify : OK   (SHA-256 一致)
  Result : OK   expected=ok

[SHARE] \\filesv01\readonly  (読取専用のはず)
  Auth   : svc_check
  Upload : NG   書込拒否 (Access denied)
  Result : OK   expected=ng -> 期待どおり書込不可

──────────────────────────────────────────────────
  Shares: 2   OK: 2   NG: 0   Warning: 0
```

### オプション

| オプション（PS） | Linux | 意味 | 既定 |
|---|---|---|---|
| `-ShareList <path>` | `-l` | 対象リスト | スクリプト隣の `shares.lst` |
| `-SizeMB <n>` | `-s` | テストファイルサイズ MB | 10 |
| `-TimeoutSec <n>` | `-t` | タイムアウト秒 | 60 |
| `-HtmlReport <path>` | `-o` | HTML レポート出力 | なし |
| `-FailOnly` | `-f` | 失敗・警告のみ表示 | off |

### HTML レポート

network-check 同様の自己完結 HTML（外部 CDN 依存なし）。共有パス・ユーザー名・上下速度・整合性・判定・サマリを掲載。
**パスワードは出力しない。**

### 終了コード

| Code | 意味 |
|---|---|
| 0 | 全て OK（Warning なし） |
| 1 | 1 件以上 Failed |
| 2 | リストファイルが見つからない |
| 10 | 前提コマンドが見つからない（Linux で smbclient 未導入等） |

## 8. Windows 起動用 bat（引数の扱い）

ご要望「できるだけ引数は bat で渡せるように」を反映し、**対話入力を排し、bat 側で引数を渡す**方式にする。

- bat 冒頭に**編集可能な `SET` ブロック**を置き、運用者がここに各オプションを事前設定する。
  お客様はダブルクリックするだけで設定済みの引数で実行される。
- 加えて、**コマンドライン引数 `%*` を後ろに付与**し、必要なら実行時に上書き・追加できる。
- 実行ログは `<bat名>_<日時>.log` に Transcript（既存 network-check 同様）。

イメージ（構造のみ）:

```bat
@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

:: ===== 運用者が編集する既定値 =====
set "SHARE_LIST=%~dp0shares.lst"
set "SIZE_MB=10"
set "TIMEOUT_SEC="
set "HTML_REPORT="
set "FAIL_ONLY="
:: =================================

set "PSARGS=-ShareList "!SHARE_LIST!" -SizeMB !SIZE_MB!"
if not "!TIMEOUT_SEC!"=="" set "PSARGS=!PSARGS! -TimeoutSec !TIMEOUT_SEC!"
if not "!HTML_REPORT!"=="" set "PSARGS=!PSARGS! -HtmlReport "!HTML_REPORT!""
if /I "!FAIL_ONLY!"=="on"  set "PSARGS=!PSARGS! -FailOnly"

:: コマンドライン引数があれば末尾に付与して上書き可能に
powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Check-FileTransfer.ps1" !PSARGS! %*

pause
```

## 9. カタログ登録（`tool-catalog.yaml`）

`menu: true` で追加。ただし本ツールは**クライアント端末で実行**する性質のため、
GUI から SSM 実行する他ツールとは運用が異なる点を README に明記する
（GUI 起動の可否は実装時に既存ランチャーの前提と整合を取る。SSM 前提のカタログ実行に馴染まない場合は
`menu: false` とし、README でスタンドアロン起動を案内する選択肢も残す）。

想定パラメータ: `shareList` / `sizeMB` / `timeoutSec` / `html`(checkbox) / `failOnly`(checkbox)。

## 10. テスト・検証

- **単体テスト（Pester）**: リストパーサ（コメント・空白・フィールド数）、判定ロジック
  （expected × 実結果のマトリクス）、ハッシュ照合ヘルパ。SMB I/O はモック化。
- **結合テスト（手動）**: 検証環境の共有に対する実往復。手順を README に明記。
  実 SMB サーバ無しでは自動化しない旨も明記。
- Linux は `bash -n` 構文チェックと、可能なら smbclient を用いたローカル共有への手動確認。

## 11. YAGNI（今回対象外）

- Excel 版リストエディタ（`targets-editor.xlsm` 相当）
- SMB 以外のプロトコル（SFTP/FTPS/HTTPS 等）
- 並列転送・帯域制御
- パスワードの永続保存や資格情報マネージャー連携（今回は実行時入力に統一）

将来 SFTP 等を足す場合も、ツール名 `file-transfer-check` のままプロトコル分岐で拡張できる余地を残す。

## 12. 命名

- ツール id / フォルダ: `file-transfer-check`
- Windows 本体: `Check-FileTransfer.ps1`（Verb-Noun、既存 network-check に倣う）
- Linux 本体: `check_file_transfer.sh`（snake_case）

SMB 特化のため `smb-transfer-check` も候補だが、将来のプロトコル拡張余地を優先し
`file-transfer-check` を採用する。
