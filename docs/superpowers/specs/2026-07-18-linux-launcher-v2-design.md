# Linux ツールランチャー v2 — 仕様検討

- 日付: 2026-07-18
- ステータス: **検討(仕様のみ・未実装)**。実装着手前にユーザーレビューを受ける
- 対象: `local-tools-launcher.sh`(bash CUI)
- 背景: Windows 版ランチャー(v2.2.0)の UI 統一・導線改善に合わせ、Linux 版の仕様を再設計する

## 前提と制約

- 実行環境はサーバー実機のターミナル(SSM Session Manager / SSH 経由)。**GUI なし・headless**
- 依存は現行方針を維持: **bash 4+ / awk / tar のみ**。ncurses / whiptail / dialog は使わない
  (SSM セッションの端末エミュレーションで崩れるリスクと、最小サーバー構成での依存追加を避ける)
- `tools/tool-catalog.yaml` を Windows 版と共用(単一ソース)。`linuxPath` を持つツールのみ対象
- 出力構造は Windows 版と同一規約: `reports/local-tools/<tool-id>/<timestamp>/{command.txt,stdout.log,stderr.log,exit-code.txt,artifacts/}`
- HTML レポートは Linux では開かない。**ZIP / tar.gz を Windows へ持ち帰り、Windows 版の
  「スナップショット一括実行 → レポート生成」で表示する**分業を維持する
- 配色は design-tokens の CLI 規約に従う: データは無色、状態のみ色付け(緑=成功 / 黄=警告 /
  赤=エラー / シアン=見出し)、`[ok]` / `[warn]` / `[FAIL]` の記号併用、`NO_COLOR` と
  リダイレクト時は色抑制(現行実装済みの挙動を維持)

## 現行(v1)の課題

| # | 課題 | Windows 版 v2.2 での対応 |
|---|---|---|
| 1 | 実行のたびに全パラメーターを 1 問ずつ聞かれる(Enter 連打) | 既定値入りフォームで即実行可能 |
| 2 | 実行中の出力が見えない(完了までファイルへリダイレクトされ無言。長時間ツールで不安) | 実行中プログレス + 完了時ログ反映 |
| 3 | 非 0 exit を一律「エラー」と表示(cert-check / port-inventory の「NG 検出」も) | 「NG 検出またはエラー」表記 |
| 4 | AWS Profile が手入力(タイポしやすい) | `~/.aws/config` からドロップダウン |
| 5 | ツール一覧に description が出ない(id + name のみ) | 説明付き 2 行表示 |
| 6 | 自動実行の口がない(cron / SSM Run Command から使えない) | (Windows は GUI のため対象外) |

## 提案する仕様(v2)

### 1. メインメニュー(現行踏襲 + 説明表示)

```text
==== Local Tools Launcher (Linux) v2 ====
ToolsRoot : /opt/aws-ec2-manager/tools
OutputRoot: /opt/aws-ec2-manager/reports/local-tools
AWS Profile: kohji

 c) スナップショット一括収集  (ZIP を作成し Windows でレポート化)

ツール個別実行:
  1) cert-check          Certificate Check    TLS 証明書の有効期限をチェック
  2) log-collector       Log Collector        プリセット別に障害対応ログを収集
  ...

  a) 直近 run を tar.gz 化   s) 設定   q) 終了
選択:
```

- 一覧に **description 列を追加**(dim 色)。課題 5 に対応
- `a)` **直近 run のアーカイブ**を追加: 実行直後に y/n を聞くだけだった tar.gz 化を、後からでも
  実行できるようにする(直近 run ディレクトリを記憶)

### 2. 実行フローの短縮(課題 1)

ツール選択後、**パラメーター既定値を一覧表示して「そのまま実行 / 編集」の 2 択**にする:

```text
▶ Certificate Check  (cert-check)
----------------------------------------------------------------
パラメーター(既定値):
  ターゲットリスト : /opt/.../cert-check/cert_targets.lst
  タイムアウト秒   : 10
  HTML レポート    : y
  失敗のみ         : n

コマンドプレビュー:
  bash /opt/.../CertCheck.ps1 相当のコマンドライン...

  Enter) この内容で実行   e) パラメーターを編集   n) 中止
```

- Enter 一発で既定実行(最頻ケースを最短化)
- `e` を選んだときだけ現行同様の per-parameter プロンプト(編集後に再プレビュー → 確認)
- 設定ファイル(configFiles)も同様: 既定(または保存済み override)を一覧に出し、編集時のみ質問
- required 空欄は実行前にチェックしてエラー(現行は警告のみで実行に進めてしまう)

### 3. 実行中のライブ出力(課題 2)

- `tee` で stdout をログ保存しつつ**画面にもリアルタイム表示**する
  (`bash entry ... > >(tee stdout.log) 2> >(tee stderr.log >&2)` 相当。bash 4 のプロセス置換)
- 完了後の `tail -30` 事後表示は廃止(ライブ表示に置き換え)
- `Ctrl-C` を trap し、exit-code.txt に `130` を記録して「中断」と表示(run ディレクトリは残す)

### 4. 終了ステータス表記(課題 3)

Windows 版 v2.2 と同一の意味論:

```text
[ok]   完了 (exit=0)  出力: reports/local-tools/cert-check/20260718-...
[warn] 終了 (exit=1)  NG 検出またはエラー。stdout.log とレポートを確認してください
[FAIL] 失敗 (exit=2 以上 / 起動失敗)  stderr.log を確認してください
```

- exit 1 は cert-check / port-inventory 等の「チェック NG」を含むため warn(黄)扱い
- exit 2 以上と起動そのものの失敗を FAIL(赤)とする
  (ops-scripts-template 規約: 1 = 引数エラー等のツールもあるが、「ログを見る」導線は同じ)

### 5. AWS Profile の選択式入力(課題 4)

- `~/.aws/config`(`AWS_CONFIG_FILE` 対応)から `[profile xxx]` / `[default]` を awk で抽出し
  番号選択メニューを出す。抽出 0 件・読み取り不可時は現行どおり自由入力にフォールバック
- 設定メニュー `s)` と初回セットアップの両方に適用

### 6. 非対話モード(新規・課題 6)

cron / SSM Run Command / aws-ec2-manager 本体(SSM 経由)からの自動実行用に
サブコマンド形式を追加する:

```text
local-tools-launcher.sh                 # 引数なし → 対話メニュー(現行互換)
local-tools-launcher.sh list            # ツール一覧を TSV で出力(id, name, description)
local-tools-launcher.sh run <tool-id> [--set key=value ...] [--dry-run]
local-tools-launcher.sh archive [<tool-id>]   # 直近 run を tar.gz 化しパスを stdout へ
```

- `run`: カタログ既定値で実行。`--set key=value` でパラメーター上書き。確認プロンプトなし
- `--dry-run`: コマンドラインと run ディレクトリを表示するだけで実行しない(テスト・確認用)
- 出力規約: **stdout = データ(生成物パス等)、stderr = 進捗・診断**。exit code はツールの
  exit code を透過(dry-run は 0)。課金・破壊的操作を伴うツールは現状ないため確認省略を許容
- これにより aws-ec2-manager 本体の SSM タスク(YAML)から
  `bash /path/local-tools-launcher.sh run cert-check` のような定型実行が可能になる

### 7. 設定・その他

- 設定ファイル(`~/.config/aws-ec2-manager/local-tools-launcher.conf`)は現行形式を維持
  (キー追加: `LAST_RUN_DIR`)
- `collect-snapshot` の `--menu` 委譲は現行維持
- 文言・用語は Windows 版と統一(「実行結果」「NG 検出またはエラー」「コマンドプレビュー」等)

### 8. 状態設計(CLI 読み替え / design-tokens 準拠)

| 状態 | 表示 |
|---|---|
| empty | 対象ツール 0 件: 「linuxPath を持つツールがカタログにありません」+ カタログパス表示 |
| loading | 実行中のライブ出力(§3)。長い処理でも無言にしない |
| error | `[FAIL]` 赤 + stderr.log パス + exit code |
| success | `[ok]` 緑 + run ディレクトリ + 成果物一覧(artifacts 内ファイル名) |

### 9. テスト・検証方針

- **bats 等のテストフレームワークは導入しない**(依存追加を避ける)。代わりに:
  - `--dry-run` と `list` を使った smoke テストシェルスクリプト(`tests/linux-launcher-smoke.sh`)を
    追加し、カタログ全ツールのコマンド生成が成功すること・引数が期待形になることを assert
  - CI(GitHub Actions)に ubuntu ジョブを追加して smoke を実行(現行 CI は Windows のみ)
- 実機検証: WSL または検証サーバー(proxy インスタンス)で対話メニュー・run・archive を確認

## 検討した代替案(不採用)

- **whiptail / dialog による TUI 化**: 見た目は GUI に近づくが、依存追加と SSM セッションでの
  端末互換リスクが利点を上回らない。テキストメニューで十分
- **PowerShell 7 (pwsh) で Windows とロジック共有**: サーバー全台への pwsh 導入が前提になり
  非現実的。カタログ(YAML)共有で仕様の一貫性は担保できている
- **Linux 側での HTML レポート生成・閲覧**: headless 前提のため不採用。Windows 持ち帰り分業を維持

## 未決事項(レビューで確認したい点)

1. 非対話モード(§6)の優先度 — 本体 SSM タスクからの定型実行まで見据えるか、対話改善のみ先行するか
2. `run --set` のキー名はカタログの `key`(例: `timeoutSec`)で良いか
3. CI への ubuntu ジョブ追加の要否(現行 CI 構成に手を入れる)
