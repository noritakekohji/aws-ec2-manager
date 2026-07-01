# server-snapshot: `filelist` カテゴリ設計

- 作成日: 2026-07-01
- 対象: `tools/server-snapshot`（Windows: `ServerSnapshot.ps1` / Linux: `server_snapshot.sh`）
- 目的: 設定ファイルで指定したディレクトリ配下のファイル・ディレクトリ一覧を、権限とオーナー情報付きで収集する新カテゴリを追加する。

## 1. 背景と動機

`server-snapshot` は既に 12 のカテゴリ（`os` / `network` / `services` / `packages` / `users` / `filesystem` / `environment` / `security` / `patches` / `tuning` / `scheduled` / `middleware`）でサーバー構成のスナップショットを収集する。

`filesystem` カテゴリはドライブ／マウントポイントの使用状況しか記録しない。一方、変更管理（例: デプロイ後のファイル差分検出、`/etc/nginx` 配下や `C:\ProgramData\<app>` 配下の権限変更検知）では、**特定ディレクトリ配下のファイル・ディレクトリ一覧と、それぞれの権限・オーナー**を追跡したい場面がある。

これを新カテゴリ `filelist` として追加する。既存の `middleware` カテゴリと同じく、独立した設定ファイル `filelist.conf` で対象を指定する。

## 2. 全体アーキテクチャ

| 項目 | 値 |
|---|---|
| 新カテゴリ名 | `filelist` |
| 追加先 | `tools/server-snapshot` |
| 設定ファイル | `tools/server-snapshot/filelist.conf` |
| 設定ファイル上書き環境変数 | `_OPS_FILELIST_CONF` |
| `-Category all` に含める | Yes（設定空なら無害にスキップ） |
| 対応 OS | Windows / Linux 両方 |
| 設定ファイルは OS で分けるか | 分けない（単一ファイル、対象ごとに `os` 指定） |
| symlink | 追跡しない（リンク自体のメタデータのみ記録） |
| ファイル内容 | 保存しない（メタデータのみ。`hash=true` のときのみ sha256 を追加） |

## 3. `filelist.conf` の書式

INI ライク（`middleware.conf` と同じ流儀）。`[target:<key>]` セクションを対象数だけ並べる。`<key>` はスナップショット内の識別キー（英数字とハイフン推奨）。

```ini
[target:etc-nginx]
path    = /etc/nginx
os      = linux                       # windows | linux | both（既定 both）
depth   = unlimited                   # 整数 or "unlimited"（既定 unlimited）
exclude = *.bak,cache/*,*.log         # カンマ区切り glob（対象ルートからの相対パス）
hash    = false                       # true でファイル sha256 を計算（既定 false）

[target:appdata-myapp]
path    = C:\ProgramData\MyApp
os      = windows
depth   = 2

[limits]
max_entries_per_target = 100000       # 1対象あたりのエントリ数上限（既定 100000）
```

### 各キーの意味と既定値

| キー | 既定 | 説明 |
|---|---|---|
| `path` | 必須 | 対象ディレクトリの絶対パス |
| `os` | `both` | `windows` / `linux` / `both`。現OSに合わなければ対象自体をスキップ |
| `depth` | `unlimited` | 整数（0 は対象ルート直下も辿らずルートのみ）または `unlimited` |
| `exclude` | 空 | カンマ区切りの glob。**対象ルートからの相対パス**に対してマッチ。ディレクトリにマッチした場合は配下ごと打ち切り |
| `hash` | `false` | `true` のときファイル sha256 を計算・記録 |
| `[limits] max_entries_per_target` | `100000` | 到達時に `truncated=true` を立てて途中で止める |

## 4. スナップショット JSON スキーマ

`snapshot.filelist` は対象の配列。空配列も許容（設定空時）。

```jsonc
{
  "filelist": [
    {
      "key": "etc-nginx",
      "path": "/etc/nginx",
      "os_matched": true,
      "exists": true,
      "depth": "unlimited",
      "hash_enabled": false,
      "excluded": ["*.bak", "cache/*", "*.log"],
      "entries": [
        {
          "rel_path": "nginx.conf",
          "type": "file",
          "size": 4321,
          "mtime": "2026-06-30T12:34:56Z",
          "mode": "0644",
          "uid": 0, "gid": 0,
          "owner": "root", "group": "root",
          "acl": null,
          "sha256": null
        },
        {
          "rel_path": "conf.d",
          "type": "dir",
          "size": null,
          "mtime": "2026-06-30T09:00:00Z",
          "mode": "0755",
          "uid": 0, "gid": 0,
          "owner": "root", "group": "root",
          "acl": null,
          "sha256": null
        },
        {
          "rel_path": "sites-enabled/default",
          "type": "symlink",
          "size": null,
          "mtime": "2026-06-30T09:00:00Z",
          "mode": "0777",
          "uid": 0, "gid": 0,
          "owner": "root", "group": "root",
          "acl": null,
          "sha256": null,
          "link_target": "/etc/nginx/sites-available/default"
        }
      ],
      "entry_count": 42,
      "truncated": false,
      "errors": [
        { "rel_path": "private/secret.key", "reason": "permission_denied" }
      ]
    }
  ]
}
```

### エントリの型と OS 別フィールド

| フィールド | Linux | Windows |
|---|---|---|
| `type` | `file` / `dir` / `symlink` | 同左 |
| `size` | ファイルバイト数（dir/symlink は `null`） | 同左 |
| `mtime` | ISO8601 (UTC) | 同左 |
| `mode` | 8進文字列 `"0644"` | `null` |
| `uid` / `gid` | POSIX の UID / GID | `null` |
| `owner` / `group` | POSIX 名 | `owner` は NTFS Owner（例 `BUILTIN\Administrators`）、`group` は `null` |
| `acl` | `null` | 主要 ACE の配列（下記） |
| `sha256` | `hash=true` かつ `type=file` のとき算出、他は `null` | 同左 |
| `link_target` | `type=symlink` のときリンク先の生パス | 同左 |

### Windows `acl` フィールド

```jsonc
"acl": [
  { "principal": "NT AUTHORITY\\SYSTEM",     "rights": "FullControl", "type": "Allow" },
  { "principal": "BUILTIN\\Administrators",  "rights": "FullControl", "type": "Allow" },
  { "principal": "BUILTIN\\Users",           "rights": "ReadAndExecute", "type": "Allow" }
]
```

- 元データは `Get-Acl` の `Access`。`IdentityReference` / `FileSystemRights` / `AccessControlType` をそのまま格納。
- 継承の詳細（`IsInherited`、`InheritanceFlags`、`PropagationFlags`）は out of scope（本設計では格納しない）。

## 5. compare（before / after）挙動

`middleware` と同じ設計に揃える。

- **突き合わせキー**: `target.key` + `rel_path`
- **対象単位**:
  - 対象キーが片方にしかない → `ADDED` / `REMOVED`（`filelist/<key>`）
- **エントリ単位**（対象キーが両方にある場合）:
  - `ADDED`: after だけに存在
  - `REMOVED`: before だけに存在
  - `CHANGED`: 以下いずれかが変化
    - `type` / `size` / `mtime` / `mode` / `uid` / `gid` / `owner` / `group` / `acl` / `sha256`（`hash_enabled` 双方 `true` のときのみ）
    - `symlink` の `link_target` 変更も `CHANGED`
- `truncated=true` の対象は比較結果に `warning="truncated"` を付ける（欠落と差分の区別のため）
- HTML レポートは既存の `Compare-List` / `New-HtmlReport` の枠組みに乗せ、セクション名 `filelist/<key>` として出力

## 6. エラー処理・セーフガード

| 事象 | 挙動 |
|---|---|
| `filelist.conf` 未検出 | `snapshot.filelist = []` を返す（無害） |
| `[target:*]` セクションが 0 件 | `snapshot.filelist = []` |
| `path` 未指定 | セクションをスキップし、収集ログに WARN |
| `path` 未存在 | 対象を `exists=false` で 1 件出力、配下スキャンなし |
| `os` 不一致 | 対象を `os_matched=false` で 1 件出力、配下スキャンなし |
| 個別ファイル / ディレクトリ読み取り失敗（ACL / Permission） | `entries` にはメタデータの取得できた分を入れ、`errors[]` に `{ rel_path, reason: "permission_denied" }` として記録。他ファイルの収集は継続 |
| `max_entries_per_target` 到達 | `truncated=true` を立てて走査打ち切り。`entry_count` は上限値 |
| symlink | リンク自体を 1 エントリとして記録、配下は辿らない |
| exclude マッチ（ディレクトリ） | 配下ごとスキップ、エントリ自体も出力しない |
| exclude マッチ（ファイル） | エントリを出力しない |
| `depth` 到達 | それより深いエントリを出力しない |

## 7. 実装レイアウト

### Windows: `ServerSnapshot.ps1`

追加する関数（既存 `middleware` 系と同じ位置に置く）:

- `Read-FilelistConf` — `filelist.conf` のパース（`Read-MwConf` のパターンに合わせる）
- `Get-FilelistInfo` — 収集本体
- `Get-FilelistTarget` — 単一対象を走査（内部で再帰）
- `Test-FilelistExclude` — glob マッチ判定
- `Compare-Filelist` — before / after 比較

修正箇所:

- `$validCategories` に `filelist` を追加（行 39 付近）
- `$allCategories` に `filelist` を追加（`Invoke-Collect` 内、行 731 付近）
- `Invoke-Collect` の dispatch に `'filelist' { Get-FilelistInfo }` を追加（行 767 付近）
- `Invoke-Compare` の dispatch に `'filelist' { @(Compare-Filelist $bCat $aCat) }` を追加（行 1250 付近）
- `Compare-Category` HTML セクション名対応

### Linux: `server_snapshot.sh`（python 部）

追加する関数:

- `_load_filelist_conf()` — INI パース
- `_filelist_scan(target)` — 単一対象の走査
- `_filelist_should_exclude(rel_path, globs)` — glob マッチ判定
- `collect_filelist()` — 収集本体

修正箇所:

- `all_cats` の bash 側リストに `filelist` 追加（行 131 付近）
- python dispatch 辞書に `'filelist': collect_filelist` 追加（行 836 付近）
- `bash` 側 case の対応

### 比較エンジン: `compare_server_info.py`

- `filelist` 用の比較ロジックを既存のカテゴリパターンに沿って追加
- 対象単位（`ADDED` / `REMOVED`）とエントリ単位の差分検出
- `truncated` フラグの伝播と警告出力

### 設定ファイルテンプレート

- `tools/server-snapshot/filelist.conf` を空テンプレートとして同梱（`middleware.conf` と同じ扱い）
- コメントで各キーの意味と `os` / `depth` / `exclude` / `hash` の書式例を記載

## 8. テスト方針

`tests/` 配下に Pester テストを追加する。

### `Filelist.Config.Tests.ps1`

- 空ファイル → 対象 0 件
- 単一 `[target:*]`（既定値のみ）
- 複数 `[target:*]`（順序保持）
- `depth = unlimited` / 整数 / 不正値のパース
- `exclude` のカンマ区切り、空、空白トリム
- `hash = true` / `false` / 不正値
- `[limits] max_entries_per_target` のパースと既定値

### `Filelist.Collect.Tests.ps1`

一時ディレクトリを `New-TempDir` で作成し、以下を検証:

- 存在しない `path` → `exists=false`、`entries=[]`
- `os = linux` を Windows で実行 → `os_matched=false`
- `depth = 0` → 対象ルートのみ
- `depth = 1` → 直下のみ
- `exclude = *.tmp` → `*.tmp` が出力されない
- `exclude = cache/*` → `cache/` 配下がスキップ、`cache/` 自体は出力
- `hash = true` → ファイルの `sha256` が正しい値
- `hash = false` → ファイルの `sha256` が `null`
- Windows: `owner` と `acl` が入る、`mode` / `uid` / `gid` / `group` が `null`
- `max_entries_per_target = 5` → 5 件で `truncated=true`
- ACL 読み取り不可のケース → `errors[]` に `permission_denied` 記録、他エントリは継続

### `Filelist.Compare.Tests.ps1`

- 対象キーの追加 / 削除 → `ADDED` / `REMOVED`
- エントリの `ADDED` / `REMOVED`
- `size` 変更 → `CHANGED`
- `owner` 変更 → `CHANGED`
- `mode` 変更 → `CHANGED`
- Windows: `acl` 変更 → `CHANGED`
- `hash_enabled=true` 双方で `sha256` 変更 → `CHANGED`
- `hash_enabled` 片方だけ `true` → `sha256` は比較対象外
- `truncated=true` の対象 → 比較結果に `warning="truncated"` が付く

### Linux 側

既存の Bats/Pytest 資産がなければ smoke テストとして:

- PowerShell から `bash server_snapshot.sh collect -c filelist` を呼び、JSON 構造が Windows と揃うこと
- `compare_server_info.py` の python ユニットテスト（既存パターンがあればそれに合わせる）

## 9. スコープ外（YAGNI）

- ファイル内容のフルテキスト保存（`middleware` にはあるが `filelist` では不要）
- symlink 追跡（リンク先の実体走査、循環検出、重複除去）
- ACL の全 ACE ダンプ（継承フラグ・伝播フラグ・監査 ACE 等の詳細）
- `include` パターン
- サイズ以外のバイナリ判定・MIME 判定
- 拡張属性（xattr）、SELinux ラベル、代替データストリーム（Windows ADS）
- Windows と Linux の設定ファイル物理分離（対象ごとの `os` フィールドで足りる）

## 10. 完了条件

- `filelist.conf` の空テンプレートが `tools/server-snapshot/` に存在する
- `server_snapshot.bat collect -Category filelist` が Windows で動く
- `bash server_snapshot.sh collect -c filelist` が Linux で動く
- `before` / `after` 比較で追加・削除・権限変更が検出される
- HTML レポートに `filelist/<key>` セクションが表示される
- `-Category all` で他カテゴリと同時に収集され、既存カテゴリの結果に影響しない
- README にカテゴリ表と `filelist.conf` の説明を追記
- 上記 Pester テストが全てグリーン
