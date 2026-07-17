# ローカルツールランチャー要件定義

**日付**: 2026-06-29
**対象**: aws-ec2-manager / tools 配下の運用ツール
**ステータス**: 要件定義

---

## 1. 目的

`tools/` 配下にあるローカル運用ツールを、Windows では独立した PowerShell/WPF GUI から、Linux では対話式 CLI ランチャーから実行できるようにする。

Windows 版と Linux 版は UI 方式こそ異なるが、同じツール群、同じ基本アクション、同じ設定項目を扱えるようにし、運用者が環境ごとに実行手順を覚え直さなくて済む状態を目指す。

今回の GUI は EC2 管理 GUI 本体とは独立させ、RDP または SSH でログインしたサーバ上でローカル実行する想定とする。

---

## 2. 前提

- Windows 版は PowerShell 5.1 + WPF で実装する。
- Windows 版 GUI は既存 `App.ps1` / `MainWindow.xaml` には組み込まず、独立した起動スクリプトとして提供する。
- Linux 版は Bash で実装し、ターミナル上の番号選択メニューで操作する。
- `tools/` の物理配置は固定せず、設定ファイルでツールルートを指定できるようにする。
- 出力先も設定ファイルで指定し、各ツールの実行結果やレポートを集約する。
- AWS 認証が必要なツールは SSO プロファイル前提とし、アクセスキー直書きは禁止する。
- 課金を伴う AWS 操作、新規作成、インスタンスタイプ変更などは今回のランチャー対象外とする。
- `.ps1` / `.psm1` は UTF-8 BOM 付き、`.sh` は UTF-8 BOM なし + LF、`.bat` は CRLF を維持する。

---

## 3. 対象ツール

対象は `tools/` 配下の既存ツールとする。

| ID | 表示名 | Windows 入口 | Linux 入口 | 備考 |
|---|---|---|---|---|
| `aws-instance-audit` | AWS インスタンス監査 | `Get-AwsInstanceAudit.ps1` | `aws_instance_audit.sh` | AWS CLI 利用 |
| `cert-check` | 証明書チェック | `CertCheck.ps1` | `cert_check.sh` | ターゲットリストあり |
| `collect-snapshot` | ローカルスナップショット収集 | `CollectSnapshot.ps1` | `collect_snapshot.sh` | ローカル状態収集 |
| `collect-snapshot-report` | スナップショットレポート生成 | `ReportSnapshot.ps1` | 未定 | Windows 側既存入口あり |
| `log-collector` | ログ収集 | `LogCollector.ps1` | `log_collector.sh` | プリセット指定あり |
| `network-check` | ネットワーク疎通チェック | `Check-NetworkConnectivity.ps1` | `check_network_connectivity.sh` | ターゲットリストあり |
| `perf-monitor` | パフォーマンス監視 | `PerfMonitor.ps1` | `perf_monitor.sh` | start / stop / status / report |
| `port-inventory` | ポート棚卸し | `PortInventory.ps1` | `port_inventory.sh` | 期待ポートリストあり |
| `server-snapshot` | サーバスナップショット | `ServerSnapshot.ps1` | `server_snapshot.sh` | collect / before / after / compare / list |

`collect-snapshot-report` は Linux 入口が未整理のため、初期実装では Windows のみ対応、または Python/PowerShell Core なしで実現できる範囲を別途判断する。

---

## 4. 設定ファイル

ランチャー共通の設定ファイルを用意する。

候補:

- Windows: `%LOCALAPPDATA%\aws-ec2-manager\tool-launcher.json`
- Linux: `${XDG_CONFIG_HOME:-$HOME/.config}/aws-ec2-manager/local-tools-launcher.conf`

最低限の設定項目:

| キー | 内容 | 例 |
|---|---|---|
| `ToolsRoot` | ツール群のルートディレクトリ | `C:\ops\tools` / `/opt/ops/tools` |
| `OutputRoot` | 実行結果の集約先 | `D:\ops-output` / `/var/tmp/ops-output` |
| `DefaultAwsProfile` | 既定 AWS SSO プロファイル | `<sso-profile>` |
| `OpenReportAfterRun` | HTML レポート生成後に開くか | `true` |
| `KeepConsoleOpen` | Windows 実行時にコンソールを残すか | `false` |

初回起動時に設定ファイルが存在しない場合:

- Windows GUI は設定画面を表示し、`ToolsRoot` と `OutputRoot` の入力を必須にする。
- Linux CLI は対話入力で `ToolsRoot` と `OutputRoot` を設定し、設定ファイルを作成する。

設定値の検証:

- `ToolsRoot` が存在すること。
- 対象ツールの入口ファイルが存在すること。
- `OutputRoot` が存在しない場合は作成確認を出す。
- `OutputRoot` に書き込み可能であること。

---

## 5. 共通ツールカタログ

Windows GUI と Linux CLI で表示名や基本アクションがズレないよう、ツール定義を共通化する。

定義ファイル:

`tools/tool-catalog.yaml`

主な定義項目:

| キー | 内容 |
|---|---|
| `id` | ツール ID |
| `name` | 表示名 |
| `description` | 短い説明 |
| `menu` | 左メニューへ表示するか |
| `windowsPath` | `ToolsRoot` からの Windows 入口相対パス |
| `linuxPath` | `ToolsRoot` からの Linux 入口相対パス |
| `workingDirectory` | 実行時の作業ディレクトリ |
| `actions` | 基本実行、レポート生成などのアクション |
| `defaultArguments` | 初期引数 |
| `outputPatterns` | 生成物検出パターン |
| `parameters` | GUI 入力欄とコマンド引数の対応定義 |

YAML は PowerShell 5.1 / Bash の標準機能だけで読めるよう、ランチャー用の単純なリスト形式に限定する。
外部 YAML パーサー、`jq`、PowerShell 7 は必須にしない。

`parameters` は以下のキーを持つ。

| キー | 内容 |
|---|---|
| `key` | パラメーター識別子 |
| `label` | GUI に表示するラベル |
| `type` | `text` / `checkbox` / `hidden` |
| `argument` | PowerShell / Shell へ渡す引数名。空文字なら位置引数として値だけ渡す |
| `default` | GUI 入力欄の既定値 |
| `value` | `checkbox` / `hidden` で渡す値 |
| `required` | 必須入力か |

Windows GUI 初期版は、通常ツールについて `text` 最大 3 項目、`checkbox` 最大 2 項目、`hidden` 任意数に対応する。
今後ツールを追加するときは、`tool-catalog.yaml` にツール定義と `parameters` を追加すれば、PowerShell 側の個別分岐なしで基本実行に乗せられる。

---

## 6. Windows GUI 要件

### 6.1 起動

独立 GUI として以下を追加する。

- `LocalToolsLauncher.ps1`
- `LocalToolsLauncher.xaml`
- `launch-tools.bat`

`launch-tools.bat` は PowerShell 5.1 を `-NoProfile -ExecutionPolicy Bypass` 付きで起動する。

### 6.2 画面構成

画面は運用ツールとして密度高めにし、既存アプリの暗色 UI に合わせる。

主な領域:

- ヘッダー: 設定中の `ToolsRoot` / `OutputRoot` / AWS プロファイル表示
- 左ペイン: ツール一覧
- 中央ペイン: 選択ツールの説明、基本アクション、最低限の入力項目
- 右または下ペイン: 実行ログ、終了コード、生成物一覧
- フッター: 実行、停止、設定、出力フォルダを開く

### 6.3 初期実装で提供する操作

まずは「基本実行」を中心にする。

- ツールを選択する。
- 必要な最小引数を入力する。
- 実行前にコマンドプレビューを表示する。
- 実行ボタンでローカル実行する。
- stdout / stderr / 終了コードを GUI に表示する。
- 出力ファイルを `OutputRoot` 配下に集約する。
- HTML レポートが生成された場合は一覧から開ける。

### 6.4 基本入力項目

ツールごとの初期入力は最小限にする。

| ツール | 初期入力 |
|---|---|
| `aws-instance-audit` | AWS プロファイル、リージョン、HTML レポート有無 |
| `cert-check` | ターゲットリスト、HTML レポート有無 |
| `collect-snapshot` | ラベル、出力先 |
| `collect-snapshot-report` | ZIP パス、比較対象 ZIP、HTML 出力先 |
| `log-collector` | プリセット、期間、出力先 |
| `network-check` | ターゲットリスト、HTML レポート有無 |
| `perf-monitor` | start / stop / status / report、間隔、時間 |
| `port-inventory` | 期待ポートリスト、HTML レポート有無 |
| `server-snapshot` | collect / before / after / compare / list、カテゴリ |

---

## 7. Linux CLI 要件

### 7.1 起動

Windows 版と同じ階層にランチャーを置く。

候補:

- `local-tools-launcher.sh`

ただし実行対象の `tools/` ルートは設定ファイルで指定するため、ランチャー配置場所に依存しない。

### 7.2 操作フロー

1. 設定ファイルを読む。
2. 未設定なら `ToolsRoot` と `OutputRoot` を対話入力する。
3. ツール一覧を番号付きで表示する。
4. ツールを選択する。
5. 基本アクションを選択する。
6. 必要な入力値を確認する。
7. 実行コマンドを表示して確認する。
8. 実行する。
9. 終了コードと出力先を表示する。
10. メニューに戻る。

### 7.3 依存

- Bash
- 標準的な GNU coreutils
- 各ツールが個別に必要とするコマンド

`jq`、`dialog`、`whiptail` は必須にしない。

---

## 8. 出力集約

`OutputRoot` 配下にランチャー管理の出力を集約する。

推奨構成:

```text
<OutputRoot>/
  <tool-id>/
    <yyyyMMdd-HHmmss>/
      command.txt
      stdout.log
      stderr.log
      exit-code.txt
      artifacts/
```

要件:

- 実行ごとにタイムスタンプディレクトリを作る。
- 実行したコマンドラインを `command.txt` に保存する。
- 標準出力と標準エラーを分けて保存する。
- 終了コードを保存する。
- ツールが生成したファイルを可能な範囲で `artifacts/` に集約する。
- GUI / CLI ともに直近実行の出力ディレクトリを表示する。

---

## 9. リモートログイン先での利用

今回のランチャーは、RDP または SSH でログインしたサーバ上で実行する。

含めること:

- ログイン先サーバに配置済みの `tools/` を指定して実行する。
- サーバ上のローカルパスを `ToolsRoot` と `OutputRoot` に指定できる。
- Windows Server 上では GUI ランチャーを RDP セッションで起動する。
- Linux サーバ上では CLI ランチャーを SSH セッションで起動する。

含めないこと:

- aws-ec2-manager GUI から対象サーバへ接続する機能。
- RDP / SSH セッションの開始機能。
- SSM でツールを配布する機能。
- SSM 経由でランチャーを遠隔実行する機能。

将来拡張として、SSM Run Command 経由で対象サーバ上のランチャーまたは個別ツールを呼ぶ導線は検討可能とする。

---

## 10. エラー処理

- 入口ファイルが存在しない場合は、ツール一覧で「未検出」と表示する。
- 実行前に必須入力が不足している場合は実行できない。
- 終了コードが 0 以外の場合も、stdout / stderr / 出力ディレクトリを確認できるようにする。
- AWS CLI 認証エラーは、SSO ログインが必要であることを明示する。
- 長時間実行中は二重実行を防ぐ。
- `perf-monitor` のような常駐系コマンドは、初期実装では既存ツールの start / stop / status を呼び分ける。

---

## 11. テスト方針

Windows:

- XAML が `XamlReader` で読み込めること。
- PowerShell 5.1 で構文エラーがないこと。
- 設定ファイルの初期作成、読み込み、保存ができること。
- ダミーの `ToolsRoot` とテスト用スクリプトで stdout / stderr / exit code を保存できること。

Linux:

- `bash -n local-tools-launcher.sh` が通ること。
- 一時ディレクトリのダミーツールでメニュー実行できること。
- `OutputRoot` 配下に期待するログ一式が作成されること。

共通:

- `tool-catalog` の定義と実ファイルの対応が取れていること。
- 出力ディレクトリ名が重複しないこと。
- パスに空白が含まれても実行できること。

---

## 12. 初期実装スコープ

初期実装で行うこと:

- Windows 独立 GUI ランチャーを追加する。
- Linux 対話式 CLI ランチャーを追加する。
- ツールルートと出力先を設定ファイル化する。
- 基本実行を中心に対象ツールを呼び出せるようにする。
- 実行ログと生成物を `OutputRoot` に集約する。
- 起動用 `.bat` と `.sh` を用意する。

初期実装で行わないこと:

- 既存 EC2 管理 GUI への組み込み。
- リモートログイン機能そのもの。
- SSM 経由の遠隔配布・遠隔実行。
- 全オプションの完全 GUI 化。
- 高度なスケジューリング。
- 複数ツールの一括実行ワークフロー。

---

## 13. 未決事項

- 共通カタログを JSON にするか TSV にするか。
- Linux 側の `collect-snapshot-report` を初期実装に含めるか。
- HTML レポート生成オプションを初期実装でどのツールまで有効にするか。
- `perf-monitor` の start 後に GUI がどこまで状態追跡するか。
- `OutputRoot` へ生成物をコピーするか、ツール側の出力先自体を `OutputRoot` に向けるか。
