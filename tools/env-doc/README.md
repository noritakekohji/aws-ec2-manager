# env-doc

`server-snapshot` / `aws-instance-audit` が収集した JSON と、手書きの `system.yaml` から
**システム環境定義書**（マルチページ静的 HTML）を生成します。

収集ツールが各サーバ上で動くのに対し、env-doc は **集約側（AVD 等）で動く後処理ツール**です。

---

## 前提

| 項目 | 内容 |
|---|---|
| 実行場所 | 集約側の Windows 端末 |
| 必須 | PowerShell 5.1+ |
| 外部依存 | **なし**（python3 / powershell-yaml 等は不要） |

---

## 使い方

```cmd
:: バッチ起動
env_doc.bat -InputDir .\input -SystemFile .\system.yaml -OutputDir .\output
```

```powershell
# PowerShell 直接実行
.\EnvDoc.ps1 -InputDir .\input -SystemFile .\system.yaml -OutputDir .\output -Force
```

| パラメータ | 既定 | 説明 |
|---|---|---|
| `-InputDir` | `.\input` | snapshot / aws の JSON を置いたディレクトリ |
| `-SystemFile` | `.\system.yaml` | システム定義 YAML |
| `-OutputDir` | `.\output` | 出力先。配下に `<system-id>/` を作る |
| `-Force` | なし | 既存の出力ディレクトリを削除して作り直す |

---

## 入力

ファイル名は自由です。**`meta.hostname` で突合**します（大文字小文字は区別しません）。

```
input/
├── WEB01.snapshot.json      # server_snapshot.bat collect の出力（必須）
├── WEB01.aws.json           # aws_instance_audit.bat の出力（任意）
└── db01.snapshot.json
```

種別は `meta.tool` で判定します。`aws_instance_audit` なら AWS 監査、
`meta.tool` が無く `meta.os_type` と `meta.categories` があれば snapshot として扱い、
どちらでもない JSON は警告してスキップします。

---

## `system.yaml`

`system.sample.yaml` をコピーして書き換えてください。

外部依存を避けるため YAML はサブセットのみ対応しています。
**範囲外の構文は黙って無視せず、行番号付きでエラーになります。**

| 対応する | 対応しない |
|---|---|
| 2 スペースインデントのマップ | タブインデント |
| `-` シーケンス | アンカー・エイリアス（`&` `*`） |
| スカラ（文字列・数値・真偽） | 複数行スカラ（`|` `>`） |
| `#` コメント、クォート | フローマップ `{}` |
| `[a, b]` インラインシーケンス | ドキュメント区切り `---` |

---

## 出力

```
output/<system-id>/
├── index.html          システム概要・サーバ一覧・警告
├── aws.html            AWS 構成（SG / IAM はリソース単位 + 適用サーバ逆引き）
├── network.html        IP / DNS / 時刻同期 / プロキシ / FW / Listen ポート（横断）+ リモートアクセス（OS 別）
├── os-baseline.html    共通項目（横断）+ OS 別サブ表
├── middleware.html     MW バージョン・状態・Listen ポート（横断）
├── servers/<host>.html            サーバ詳細（目次つき・要約のみ）
├── servers/<host>-services.html   サービス全件（クロス集計 + 状態別の折りたたみ）
├── servers/<host>-packages.html   パッケージ全件
├── servers/<host>-filelist.html   ファイル一覧全件（ディレクトリツリー）
├── servers/<host>-configs.html    設定ファイル全文（opt-in 時のみ）
└── assets/style.css
```

すべて相対リンクのみです。`index.html` をダブルクリックすればそのまま閲覧できます。

### 件数の多い情報の見せ方

実機ではサービスが 300 件近く、ファイル一覧が数千件になります。1 ページに並べると
スクロールが破綻するため、次の方針で分けています。

| 情報 | 見せ方 |
|---|---|
| サービス | サーバ詳細には **総数・稼働中・自動起動だが停止** の要約だけを出し、全件は `-services.html` へ |
| ファイル一覧 | `rel_path` を分解して **ディレクトリツリー**に組み直し、各階層を折りたたむ |
| パッケージ / 設定ファイル | 従来どおり別ページ |

サービス全件ページの先頭には **状態 × 起動設定のクロス集計**を出します。
「自動起動なのに停止している」件数が折りたたみを開かずに分かるため、
保守時に最初に見る値になります。

折りたたみは `<details>` だけで実現しており JavaScript は使いません。
ページ内の目次（`#` アンカー）から各セクションへ直接飛べます。

### 不一致ハイライト

横断表では、**比較グループ内で値が揃っていない行**を強調します。
既定のグループは「同一 OS 種別 × 同一 role」です（role 未設定のサーバは比較対象外）。
`compare_groups` を書くと自動グループ化は行わず、明示指定のみを使います。

Windows と Linux を同じグループに入れないのは、カーネルやパッケージ形式が違うのは当然であり、
全台一括で比較すると全行が強調されて意味を失うためです。

### 「未収集」と「なし」

| 表示 | 意味 |
|---|---|
| `未収集` | `-Category` で絞ったなどの理由で、そのカテゴリを収集していない |
| `なし` | 収集したが該当データが 0 件 |

---

## 機密の扱い

- **社内限定での公開を前提**としています
- パスワード等のマスクは `server-snapshot` 側の既存マスクに依存します
- **環境変数と設定ファイル全文は既定で非掲載**です。掲載するには `system.yaml` の
  該当サーバに `show_environment: true` / `show_configs: true` を書いてください

---

## GitLab Pages への移行

出力された `<system-id>/` ディレクトリをそのままリポジトリの `public/` に置き、
`.gitlab-ci.yml` で `pages` ジョブの artifact に指定するだけです。
絶対 URL を含まないため、追加の書き換えは不要です。

---

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 引数不正 / YAML 構文エラー / 出力先が既存（`-Force` なし） |
| 2 | 入力ディレクトリまたは JSON が見つからない |
| 4 | 処理エラー |

---

## テスト

```powershell
Invoke-Pester -Path ..\..\tests\EnvDoc.*.Tests.ps1
```

---

## 設計

`docs/superpowers/specs/2026-07-26-env-doc-design.md`
