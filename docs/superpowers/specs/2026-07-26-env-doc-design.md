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
- `server-snapshot` の全 14 カテゴリの掲載
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

### 入力 JSON の構造上の注意

snapshot の JSON は、カテゴリによって形が大きく異なる。中間モデル構築時に吸収すべき点を挙げる。

#### `config_files` はパスをキーにしたマップ

配列ではない。3 箇所に現れる。

```json
"config_files": {
  "C:\\ProgramData\\ssh\\sshd_config": {
    "content": "...", "masked": false, "size_bytes": 1234,
    "sha256": "...", "readable": true, "reason": ""
  }
}
```

| 出現箇所 | 備考 |
|---|---|
| `middleware.<product>[].config_files` | ただし `sap` のみキー名が `profiles` |
| `services[].config_files` | sshd_config / ssh_config / smb.conf |
| `remote_access.<ssh\|rdp\|vnc>.config_files` | |

`readable = false` のときは `reason`（`not_found` / `permission_denied`）を、
`reason = too_large` のときは本文なしで `sha256` とサイズのみを表示する。

#### ミドルウェアのフィールド名は製品ごとに異なる

汎用の `instance` / `version` / `ports` は存在しない。`ServerSnapshot.ps1` の比較仕様
（`Compare-Middleware` の `$specs`）に合わせる。

| 製品 | 識別子 | 主要フィールド | ポート | 設定ファイル |
|---|---|---|---|---|
| `hana` | `sid` | `version` / `instance_no` / `state` | `ports`（配列） | `config_files` |
| `sap` | `sid` + `instance` | `kernel_version` / `type` / `state` | `ports`（配列） | **`profiles`** |
| `sqlserver` | `instance_name` | `version` / `edition` / `state` | `port`（スカラ） | `config_files` |
| `tomcat` | `name` + `catalina_base` | `version` / `java_version` / `state` | `connector_ports`（配列） | `config_files` |

製品キー自体、検出されなければ `middleware` から**省かれる**（空配列ではなくキーごと無い）。

#### `remote_access` は OS で構造が異なる

| OS | トップレベルキー |
|---|---|
| Windows | `rdp`（`enabled` / `nla_enabled` / `port_number` / `security_layer` / `min_encryption_level` / レジストリ値）、`remote_assistance`、`services[]`、`ssh.config_files`、`firewall_rules[]` |
| Linux | `ssh` / `rdp` / `vnc`（各 `services[]` + `config_files`） |

共通軸が作れないため、**横断表ではなく OS 別サブ表**として描画する。

#### 0〜1 件のカテゴリは配列にならない（最重要）

`ServerSnapshot.ps1` は `$result[$cat] = switch ($cat) { ... }` でカテゴリ値を詰めている。
PowerShell の配列アンロールにより、**要素 0 件のカテゴリは `null`、1 件のカテゴリは単一オブジェクト**
として JSON 化される（`filelist` だけが `,@()` で保護されている）。

そのため env-doc 側は、snapshot 由来の配列を `.Count` する前・`foreach` に渡す前に
**必ず `@()` でラップする**。これを怠ると、サービスが 1 個しかないサーバで件数が壊れる。
Linux 側（Python の `json.dump`）にこの問題はない。

#### 実際のフィールド名が直感と食い違うもの

設計時に想定した名前と実装が異なっていた箇所。実装を正とする。

| 想定しがちな名前 | 実際 |
|---|---|
| `network.ip_addresses` | `network.interfaces`（要素は `{name, address, prefix}`） |
| `network.dns_servers` = 文字列配列 | `[{interface, servers:[...]}]` の入れ子 |
| `network.ntp` | `network.time_sync` |
| `services[].start_mode` | `services[].start_type`（Windows は小文字化された値） |
| `packages[].publisher` | `packages[].vendor` |
| `tuning.power_plan` | `tuning.power_scheme` |
| `tuning.pagefile.size_mb` | `tuning.pagefile` は配列 `[{path, initial_mb, maximum_mb}]` |

#### 構造そのものが OS で違うもの

| カテゴリ | Windows | Linux |
|---|---|---|
| `environment` | `{machine:{}, user:{}}` の 2 段 | `{machine:{}}` のみ（`user` キーなし） |
| `scheduled` | `{scheduled_tasks:[], startup:[]}` のオブジェクト | `{cron:[], systemd_timers:[]}` のオブジェクト |
| `security` ファイアウォール | `security.firewall_profiles[]` = `{name, enabled, ...}` | `security.firewall` = `{type, state}`。**firewalld / iptables が無ければキーごと欠落** |
| `security` アクセス制御 | `security.uac` = `{EnableLUA:<int>, ...}`（PascalCase・0/1） | `security.apparmor` = `{}` / `{available, summary}` / `{active}` の 3 形 |
| `tuning` | `power_scheme` / `pagefile[]` | `thp_enabled` / `cpu_governor`（**文字列配列**） |

`environment` と `scheduled` は「配列だと思って `.Count` を取ると常に 1 になる」ため、
特に事故を起こしやすい。

#### 収集側が未実装の予約フィールド

値が空でも「未収集」ではなく「収集側が未実装」であるため、`-` と表示する。

- `middleware.<hana|sap|tomcat>[].state` — 常に `''`
- `middleware.<hana|sap>[].ports` — 常に `[]`

ポートが実際に入るのは `sqlserver` の `port`（スカラ）と `tomcat` の `connector_ports`（配列）だけ。

## 5. 出力

### サイト構成

```
output/<system-id>/
├── index.html                      システム概要・サーバ一覧・生成メタ
├── aws.html                        AWS 構成（横断）
├── network.html                    ネットワーク + リモートアクセス（横断）
├── os-baseline.html                OS・ハードウェア・チューニング・パッチ（横断）
├── middleware.html                 ミドルウェア（横断）
├── servers/
│   ├── <host>.html                 サーバ詳細（目次つき・要約のみ）
│   ├── <host>-services.html        サービス全件（クロス集計 + 状態別の折りたたみ）
│   ├── <host>-packages.html        パッケージ全件
│   ├── <host>-filelist.html        ファイル一覧全件（ディレクトリツリー）
│   └── <host>-configs.html         設定ファイル全文（show_configs: true のときのみ）
└── assets/
    └── style.css
```

すべて相対リンクのみで構成する。`file://` で開けること、およびディレクトリごと
GitLab Pages の `public/` に配置して動作することを両立させる。

ナビゲーションは全ページ共通ヘッダに固定リンク（概要 / AWS / ネットワーク / OS / ミドルウェア）。
OS をミドルウェアより先に置くのは、OS が土台でミドルウェアがその上に載る順序に合わせるため。
サーバ一覧はナビの独立項目ではなく、概要ページ（`index.html`）内に表として掲載する。

### 件数の多い情報のナビゲーション

実機ではサービスが 300 件近く、`filelist` が数千件になる。1 ページに並べると
スクロールが破綻して目的の情報に到達できないため、次の 3 つで対処する。

| 手段 | 適用先 |
|---|---|
| 別ページへの分離 | サービス全件（`-services.html`）。詳細ページには総数・稼働中・**自動起動だが停止**の要約だけを残す |
| 折りたたみ（`<details>`） | サービスの状態別一覧、ファイル一覧のディレクトリ階層 |
| ページ内目次（`#` アンカー） | サーバ詳細、サービス全件、ファイル一覧 |

**JavaScript は使わない。** 折りたたみは `<details>` / `<summary>` だけで実現する
（`file://` でも GitLab Pages でも同じ挙動になり、CSP の制約も受けない）。

#### サービス: 状態 × 起動設定のクロス集計

サービス全件ページの先頭にクロス集計表を置く。
「起動設定が automatic なのに status が stopped」の件数が、折りたたみを開かずに読める。
これは保守で最初に確認する値であり、該当行は不一致ハイライトと同じ強調を掛ける。

Windows と Linux で語彙が違う（`automatic`/`enabled`、`running`/`active`）ため、
判定はどちらの語彙も受け付ける。

#### ファイル一覧: ディレクトリツリー

`filelist` の `rel_path` はフラットな文字列（Windows は `\`、Linux は `/` 区切り）で来る。
そのまま表にすると数千行の平坦な一覧になり、どのディレクトリに何があるか読み取れない。

そのためパスを分解して階層に組み直し、ディレクトリごとに `<details>` で折りたたむ。
各ディレクトリの `<summary>` には配下の総ファイル数・総ディレクトリ数を出し、
開く前に規模が分かるようにする。
途中のディレクトリが `entries` に含まれていなくても階層は構築する。

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
| `services` | systemd unit（`FragmentPath` / `ExecStart` / `User`） | Windows サービス（`service_type` / `start_name` / `path_name`） |
| `remote_access` | `ssh` / `rdp`(xrdp) / `vnc` | `rdp` / `remote_assistance` / `ssh` / `firewall_rules` |
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

（実装後の追記: 当初はこの節で「レンダラは snapshot JSON を直接参照しない」という
原則を掲げつつ、後述の実装フェーズでは `Server.Snapshot = $Snapshot` を中間モデルに
そのまま保持する指示を出しており、計画自体に内部矛盾があった。418 件のテストが通って
いる実装済みコードを正規化モデルへ書き直すのは割に合わないため、ここでは実装の実態に
合わせて記述を修正する。）

**レンダラは `Model.ps1` が構築した中間モデルの `Server.Snapshot`（生の snapshot JSON）を、
共通アクセサ `Get-JsonValue -Path` 経由でのみ読む。** レンダラ側で生 JSON を直接
`ConvertFrom-Json` することはない（入力読み込みは `Model.ps1` の `Read-EnvDocInput` に閉じている）。

- `Get-JsonValue` がドット区切りパスの安全な参照（`$null` 安全、既定値）を提供するため、
  レンダラは snapshot のキー欠落やカテゴリ未収集に対して個別の防御コードを書かずに済む
- 完全な正規化（製品固有フィールドの共通化、OS 差異の吸収）はモデル層ではなく描画時に
  行っている（例: `PageMiddleware.ps1` の `$script:EnvDocMwProducts` テーブル）。
  将来モデル層へ正規化を持ち上げる場合の入口は、各レンダラの `Get-JsonValue` 呼び出し箇所である
- AWS 情報のリソース単位正規化（SG・IAM の逆引き）は `Add-EnvDocAwsModel`（`Model.ps1`）が
  モデル構築時に一度だけ行う。これは実装どおりで、当初の設計判断と食い違いはない

モデルの形状（実装どおり。`Build-EnvDocModel` / `New-EnvDocServerEntry` の戻り値）:

```
$model = @{
  System  = @{ Id; Name; Owner; Contact; Description; Diagram }
  Servers = @( @{
      Hostname; Key; Role; Note; ShowConfigs; ShowEnvironment;
      OsType; Snapshot;          # 生 snapshot JSON。レンダラは Get-JsonValue 経由でのみ読む
      CollectedAt; Categories;   # meta.categories(-Category all は既知カテゴリ一覧に展開済み)
      Aws;                       # 当該サーバの aws-instance-audit の生 JSON(無ければ $null)
      HasSnapshot                # snapshot が無いサーバ(system.yaml のみ定義)は $false
  } )
  Aws     = @{ Instances; Vpcs; Subnets; SecurityGroups; IamRoles; RouteTables }   # 正規化済み
  Groups  = @( @{ Name; MemberKeys = @() } )   # 比較グループ(Get-EnvDocCompareGroup が設定)
  Meta    = @{ GeneratedAt; Warnings = @() }
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
| `aws.json` が無いサーバ | AWS 列は `未収集`。AWS データが 1 件も無くても `aws.html` は生成する(ナビゲーションに固定リンクがあるためリンク切れを避ける)。この場合、各セクションが空データ表示になる |
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
- `show_configs` の対象は `middleware`（`config_files` / `sap` は `profiles`）だけでなく、
  **`services[].config_files` と `remote_access.*.config_files` も含む**。
  sshd_config や smb.conf はミドルウェアではないが機密濃度は同等であり、
  opt-in の外に漏れないようにする
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
