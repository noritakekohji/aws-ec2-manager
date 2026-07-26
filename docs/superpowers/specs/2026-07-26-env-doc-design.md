# env-doc — システム環境定義書ジェネレータ 設計

- 作成日: 2026-07-26
- ステータス: 設計確定（実装前）
- 対象: `tools/env-doc/`

## 1. 目的と背景

保守運用者が読むための **システム環境定義書** を、既存の収集ツールの出力から自動生成する。

現状、`server-snapshot` と `aws-instance-audit` は構成情報を JSON で収集できるが、
成果物は「収集した生データ」または「変更差分レポート」であり、
**システム全体の構成を人が読んで把握するためのドキュメント**にはなっていない。

本ツールは、収集済み JSON（事実）と手書きの定義 YAML（意味づけ）を突き合わせ、
マルチページの静的 HTML サイトとして環境定義書を生成する。

### 想定読者

インフラ保守エンジニア。シンプルで、階層と表で構造が分かることを最優先とする。
装飾より情報の見つけやすさを優先する。

### 成功条件

- 収集済み JSON を `input/` に置き、`system.yaml` を書けば定義書が生成される
- 「このシステムの全サーバで NTP はどうなっているか」が 1 ページで分かる
- 生成物ディレクトリをそのまま GitLab Pages の `public/` に置けば公開できる
- 実行環境に PowerShell 5.1 以外の依存がない

## 2. スコープ

### スコープ内

- システム単位（複数サーバ）の環境定義書生成
- `server-snapshot` の全 13 カテゴリの掲載
- `aws-instance-audit` の AWS 構成情報の掲載
- Windows / Linux 混在システムへの対応
- 比較グループ内での設定不一致ハイライト

### スコープ外（YAGNI）

| 項目 | 理由 |
|---|---|
| 前回生成との差分表示 | `server-snapshot compare` が既に担っている |
| 構成図の自動描画 | 手書き画像を YAML から参照する方式で足りる |
| `.gitlab-ci.yml` の同梱 | 出力構造を Pages 互換にしておき、CI 定義は移行時に作る |
| サイト内検索機能 | ブラウザの Ctrl+F で足りる |
| 印刷専用レイアウト | 最低限の `@media print` にとどめる |
| 複数サーバへの SSM 一括収集・自動回収 | 入力ディレクトリ規約で疎結合にする。将来 GUI から足せる |

## 3. 設計判断とその理由

| 判断 | 選んだもの | 理由 |
|---|---|---|
| ドキュメントの単位 | システム単位（複数サーバをまとめる） | 保守で見たいのは 1 台の詳細より全体構成と台間の差異 |
| 手書き情報の扱い | `system.yaml` と snapshot をマージ | 役割・担当・用途は自動収集できない。YAML なら Git で差分が追える |
| 出力形態 | マルチページ静的サイト | `file://` でも Pages でも動く。ページ分割で印刷・検索がしやすい |
| 実装言語 | PowerShell 5.1 のみ、外部依存ゼロ | 配布先 AVD に python3 / モジュールがある保証がない。`ServerSnapshot.ps1` に HTML 生成の前例あり |
| 入力の集め方 | 入力ディレクトリ規約のみ定める | 集め方（S3 / 共有フォルダ / 手コピー）は環境ごとに違う。疎結合にしてテスト可能性を確保 |
| 大量データ | 本文は要約、全件は別ページ | 通常導線を短く保ちつつ、必要なときは全件を見られる |
| 機密の扱い | 社内限定 Pages 前提。高機密カテゴリは既定非掲載 | snapshot 側のマスクに乗り、環境変数・設定ファイル全文は opt-in |
| 配置場所 | `tools/env-doc/` | `collect-snapshot/ReportSnapshot.ps1`（集約側で動く・Windows 専用・`menu: false`）の前例に乗る |

### 配置場所についての補足

`tools/` 配下は本来「各サーバに配備して現地で実行する」ツール群だが、
`collect-snapshot-report`（`ReportSnapshot.ps1`）が既に「集約側で動く後処理ツール」として
`tool-catalog.yaml` に `linuxPath: ""` / `menu: false` で登録されている。
env-doc も同じ性質のため、この前例に従う。

## 4. 入力

### ディレクトリ規約

```
input/
├── WEB01.snapshot.json      # server-snapshot collect の出力（必須）
├── WEB01.aws.json           # aws-instance-audit の出力（任意）
├── db01.snapshot.json
└── db01.aws.json
system.yaml                  # 手書きの定義
```

ファイル名は突合に使わない。**`meta.hostname` で突合する**（snapshot 側・aws 側とも `meta.hostname` を持つ）。

ファイル種別は `meta.tool` の有無で判別する。

| 種別 | 判定条件 |
|---|---|
| aws-instance-audit | `meta.tool` が `aws_instance_audit` |
| server-snapshot | `meta.tool` が存在せず、`meta.os_type` と `meta.categories` を持つ |
| 上記以外 | 警告を出してスキップ |

Linux の `hostname` は小文字、Windows の `$env:COMPUTERNAME` は大文字を返すため、
突合は大文字小文字を区別せずに行う。

### `system.yaml` スキーマ

```yaml
system:
  id: order-mgmt                          # 必須。出力ディレクトリ名になる（半角英数・ハイフン・アンダースコアのみ）
  name: 受注管理システム                    # 必須
  owner: インフラ運用課                     # 任意
  contact: infra-ops@example.com          # 任意
  description: 受注入力から出荷指示までを担う基幹システム   # 任意
  diagram: assets/system-diagram.png      # 任意。手書き構成図を参照

servers:
  - hostname: WEB01                       # 必須。snapshot の meta.hostname と突合
    role: Web/AP サーバ                    # 任意
    note: 冗長構成のプライマリ                # 任意
    show_configs: false                   # 既定 false。設定ファイル全文の掲載
    show_environment: false               # 既定 false。環境変数の掲載
  - hostname: db01
    role: DB サーバ

compare_groups:                           # 任意。省略時は os_type × role で自動グループ化
  - name: Web 冗長ペア
    servers: [WEB01, WEB02]
```

`system.id` は出力ディレクトリ名になるため、`^[A-Za-z0-9_-]+$` に一致しない場合は
引数不正（終了コード 1）として扱う。パス区切り文字の混入を防ぐ目的も兼ねる。

### YAML サブセットの範囲

外部依存ゼロのため自前パーサ（`YamlLite.ps1`）を実装する。
**対応範囲を明示的に区切り、範囲外の構文は黙って無視せず行番号付きでエラー終了させる。**
静かに誤った値を読むことが最大のリスクであるため、曖昧なものはすべて拒否する。

| 対応する | 対応しない（検出したらエラー） |
|---|---|
| 2 スペースインデントのマップ | タブインデント |
| `-` によるシーケンス | アンカー・エイリアス（`&` / `*`） |
| スカラ（文字列・数値・真偽） | 複数行スカラ（`\|` / `>`） |
| `#` コメント | フローマップ `{}` |
| `'…'` / `"…"` クォート | 複数ドキュメント区切り `---` |
| `[a, b]` インラインシーケンス | タグ（`!!str` 等） |

## 5. 出力

### サイト構成

```
output/<system-id>/
├── index.html                      システム概要・サーバ一覧・生成メタ
├── aws.html                        AWS 構成（横断）
├── network.html                    ネットワーク（横断）
├── middleware.html                 ミドルウェア（横断）
├── os-baseline.html                OS・ハードウェア・チューニング・パッチ（横断）
├── servers/
│   ├── <host>.html                 サーバ詳細（要約）
│   ├── <host>-packages.html        パッケージ全件
│   ├── <host>-filelist.html        ファイル一覧全件
│   └── <host>-configs.html         設定ファイル全文（show_configs: true のときのみ）
└── assets/
    └── style.css
```

すべて相対リンクのみで構成する。`file://` で開けること、およびディレクトリごと
GitLab Pages の `public/` に配置して動作することを両立させる。

ナビゲーションは全ページ共通ヘッダに固定リンク（概要 / AWS / ネットワーク / ミドルウェア / OS / サーバ一覧）。

### 横断ページの設計方針

保守で実際に問われるのは「サーバ 1 台の詳細」より
「このシステムの全サーバで NTP はどうなっているか」「Tomcat のバージョンは揃っているか」である。
そのため、カテゴリごとにサーバを列に並べた **横断表** を主とし、
サーバ詳細ページは補助と位置づける。

横断表には **不一致ハイライト** を入れる。
比較グループ内で値が揃っている行は淡色、1 台でも異なる行は強調する。
「揃っているべきものが揃っていない」ことの発見を最優先の機能とする。

### `aws.html` の構成

Security Group と IAM ロールは複数サーバで共有されるのが通常であり、
サーバごとに繰り返すと冗長で読めない。**リソース単位に正規化し、逆引き（適用サーバ）を併記する。**

| セクション | 内容 |
|---|---|
| インスタンス一覧 | Name タグ / instance-id / instance-type / AMI / AZ / private・public IP / Subnet / VPC / タグ |
| ネットワーク構成 | VPC(CIDR) → Subnet(CIDR/AZ) → 所属サーバ の階層表、および Route Table |
| Security Group | SG 単位に 1 カード（group_id / name / description / ingress・egress 表）＋ 適用サーバ一覧 |
| IAM | ロール単位に 1 カード（managed / inline ポリシー）＋ 使用サーバ一覧 |

インスタンス一覧の各行から `servers/<host>.html` にリンクする。
サーバ詳細ページの先頭にも AWS 要約（type / AZ / IP / SG / ロール）を再掲する。

## 6. OS 混在への対応

`server-snapshot` の出力には `meta.os_type`（`windows` / `linux`）が含まれるため、これで分岐する。
横断表に Windows と Linux をそのまま並べると意味が壊れる列があるため、3 層に分けて扱う。

### ① OS 非依存の共通軸 — 1 つの表に統合

Windows 版・Linux 版でフィールド名が揃っている項目は、そのまま 1 表に並べる。

`hostname` / `os_name` / `os_version` / `architecture` / `cpu_model` / `cpu_cores` /
`total_memory_gb` / `timezone` / `hardware.virtualization` / `last_boot` /
IP アドレス / DNS / NTP / プロキシ / ファイルシステム使用率

### ② 意味が OS で異なる項目 — 同一ページ内で OS 別サブ表

見出しを `Linux (3 台)` / `Windows (2 台)` に分け、別テーブルとして描画する。

| カテゴリ | Linux | Windows |
|---|---|---|
| `packages` | rpm / dpkg | インストール済みプログラム |
| `services` | systemd unit | Windows サービス |
| `security` | AppArmor / firewalld | UAC / Windows ファイアウォール |
| `tuning` | sysctl / THP / CPU ガバナー | ページファイル / 電源プラン |
| `patches` | rpm / dpkg 更新履歴 | HotFix |
| `scheduled` | cron / systemd timer | スケジュールタスク / スタートアップ |

### ③ 不一致ハイライトは比較グループ内でのみ判定

Windows と Linux でカーネルが異なるのは当然であり、全台一括で比較すると
すべての行が強調されて意味を失う。

- 既定の比較グループ: **同一 `os_type` × 同一 `role`**
- `role` が未設定のサーバは、意図せず同一グループに束ねられることを避けるため比較対象外とする
- `system.yaml` の `compare_groups` を書いた場合、既定の自動グループ化は行わず、明示指定のみを使う
- メンバーが 1 台のグループは比較対象なしとし、ハイライトを出さない

## 7. 内部構造

```
tools/env-doc/
├── EnvDoc.ps1              エントリ（引数解析・オーケストレーション）
├── env_doc.bat             起動バッチ
├── lib/
│   ├── YamlLite.ps1        YAML サブセットパーサ
│   ├── Model.ps1           snapshot + aws + yaml → 中間モデル
│   ├── Compare.ps1         比較グループ内の不一致判定
│   ├── Html.ps1            エスケープ・ナビ・テーブルヘルパ
│   ├── PageIndex.ps1
│   ├── PageAws.ps1
│   ├── PageNetwork.ps1
│   ├── PageMiddleware.ps1
│   ├── PageOsBaseline.ps1
│   └── PageServer.ps1
├── assets/style.css
├── system.sample.yaml
└── README.md
```

`ServerSnapshot.ps1` が単一ファイルで 1718 行に達している前例があるため、
env-doc は最初から責務ごとに分割する。
`lib/` を含めてフォルダごとコピーすれば動作する規約は維持する。

### 中間モデル — 核となる設計判断

**レンダラは snapshot JSON を直接参照しない。**
`Model.ps1` が正規化済みの中間モデルを組み立て、各ページレンダラはそれのみを見る。

これにより、
- snapshot のスキーマが変わった場合、修正箇所は `Model.ps1` に限定される
- レンダラを実データなしで単体テストできる
- AWS 情報のリソース単位正規化（SG・IAM の逆引き）をモデル構築時に一度だけ行える

モデルの形状:

```
$model = @{
  System  = @{ Id; Name; Owner; Contact; Description; Diagram }
  Servers = @( @{
      Hostname; Role; Note; OsType;
      Os; Network; Services; Packages; Users; Filesystem; Environment;
      Security; Patches; Tuning; Scheduled; Middleware; Filelist;
      Aws;                       # 当該サーバの AWS 要約
      ShowConfigs; ShowEnvironment;
      MissingCategories = @()    # 未収集カテゴリ
  } )
  Aws     = @{ Instances; Vpcs; Subnets; SecurityGroups; IamRoles; RouteTables }   # 正規化済み
  Groups  = @( @{ Name; Members = @(); Mismatches = @() } )
  Meta    = @{ GeneratedAt; ToolVersion; InputFiles = @(); Warnings = @() }
}
```

`Aws.SecurityGroups` / `Aws.IamRoles` の各要素は `AppliedTo = @('WEB01','WEB02')` を持ち、
逆引き表示に用いる。

## 8. 欠損とエラーの扱い

### 「未収集」と「該当なし」の区別

この 2 つを混同すると定義書として誤読を生むため、必ず区別して表示する。

| 状況 | 表示 |
|---|---|
| `-Category` で絞って収集し、そのカテゴリが JSON にない | `未収集`（グレー表示） |
| 収集したが該当データが 0 件 | `なし` |
| `aws.json` が無いサーバ | AWS 列は `未収集`。全サーバに無ければ `aws.html` 自体を生成しない |
| `system.yaml` にあるが snapshot が無い | 警告を出して継続。一覧に `未収集` で掲載し、取り漏らしを可視化する |
| snapshot にあるが `system.yaml` に無い | 警告を出して継続。role 未設定で掲載し、定義漏れを可視化する |

警告は標準エラー出力と `index.html` の生成メタ欄の両方に出す。

### CLI

```
EnvDoc.ps1 -InputDir <path> -SystemFile <path> -OutputDir <path> [-Force]
```

| パラメータ | 既定 | 説明 |
|---|---|---|
| `-InputDir` | `.\input` | snapshot / aws JSON を置いたディレクトリ |
| `-SystemFile` | `.\system.yaml` | システム定義 YAML |
| `-OutputDir` | `.\output` | 出力先。配下に `<system-id>/` を作る |
| `-Force` | なし | 既存の出力ディレクトリを上書きする |

### 終了コード

既存ツール群の規約に合わせる。

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 引数不正 / YAML 構文エラー / 出力先が既存（`-Force` なし） |
| 2 | 入力ディレクトリまたは JSON が見つからない |
| 4 | 処理エラー |

## 9. セキュリティ

- 公開範囲は **社内限定 GitLab Pages** を前提とする
- パスワード等のマスクは `server-snapshot` 側の既存マスクに乗る。本ツールで再マスクはしない
- `environment`（環境変数）と設定ファイル全文は **既定で非掲載**。
  `system.yaml` の `show_environment` / `show_configs` を `true` にしたサーバのみ掲載する
- HTML 出力時はすべての値を HTML エスケープする（`<` `>` `&` `"` `'`）。
  snapshot 由来の値がそのままマークアップとして解釈されることを防ぐ
- テストフィクスチャは実データを使わず、ダミー値で作成する

## 10. 文字コード

- 生成 HTML: UTF-8（BOM なし）、`<meta charset="utf-8">` を明記
- `.ps1`: UTF-8 BOM 付き（CP932 環境での文字化け回避。プロジェクト規約）
- `.bat`: CRLF
- `system.yaml`: UTF-8。BOM 付き / なしの双方を読めるようにする

## 11. テスト方針

Pester で実施する。

| 対象 | 内容 |
|---|---|
| `YamlLite` | 正常系（ネスト・シーケンス・コメント・クォート・日本語）／異常系（タブ・アンカー・複数行スカラ・フローマップ）で行番号付きエラーになること |
| `Model` | フィクスチャ（Windows 1 台 + Linux 2 台、aws あり/なし、カテゴリ欠損あり）から期待モデルが構築されること。SG / IAM の逆引きが正しいこと |
| `Compare` | 一致 / 不一致 / メンバー 1 台のグループ / 明示 `compare_groups` の上書き |
| `Html` | エスケープ（`<` `>` `&` `"` と日本語）、BOM なし UTF-8 で出力されること |
| E2E | フィクスチャ一式から生成し、期待ファイルが存在すること、および **相対リンク切れがゼロ** であること |

## 12. 実装フェーズ案

| Phase | 内容 |
|---|---|
| 1 | `YamlLite.ps1` + テスト |
| 2 | `Model.ps1`（snapshot のみ、AWS なし）+ フィクスチャ + テスト |
| 3 | `Html.ps1` + `PageIndex` + `PageServer`（最小構成で生成が通ること） |
| 4 | 横断ページ（`PageNetwork` / `PageMiddleware` / `PageOsBaseline`）+ `Compare.ps1` |
| 5 | AWS 対応（`Model` 拡張 + `PageAws`） |
| 6 | 全件ページ（packages / filelist / configs）+ opt-in 制御 |
| 7 | `tool-catalog.yaml` 登録、README、CHANGELOG、リリース |

## 13. 参照

- 入力元: `tools/server-snapshot/README.md`
- 入力元: `tools/aws-instance-audit/README.md`
- 前例（集約側ツール）: `tools/collect-snapshot/ReportSnapshot.ps1`
- ツール登録: `tools/tool-catalog.yaml`
