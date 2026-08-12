# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `collect-snapshot`: Snapshot Report の「差分のみ」チェックを比較器の既定動作に合わせ、チェック時は差分のみ、未チェック時は一致行も含めるように修正しました。
- `server-snapshot`: 比較レポートを標準で差分行のみの表示にし、`-IncludeSame` / `--include-same` を指定した場合だけ一致行を出力するように変更。HTML では差分のあるカテゴリだけを展開するため、大量のファイル・サービスがある環境でも確認しやすくなりました。
- `server-snapshot`: filelist のファイル内容は、双方に SHA-256 があればハッシュ、片方でも無ければファイルサイズで比較するように変更。更新日時 (`mtime`) は差分判定から除外しました。
- `server-snapshot`: OS の最終起動時刻・BIOS 日付、パッチのインストール日、時刻同期の最終同期時刻など、日時系フィールドを差分判定から除外しました。収集データ自体には保持します。
- `server-snapshot`: 環境定義と無関係な実行状態を比較対象から除外しました。サービス/RDP・SSH の稼働状態、NTP の同期状態・選択中サーバー、再起動保留、タスク状態、ミドルウェアの稼働状態・接続可否、OS インストール日、パッチ説明を収集値としては保持します。

### Fixed
- SSO ログインウィンドウに `ca_bundle` / `AWS_CA_BUNDLE` / `REQUESTS_CA_BUNDLE` の表示とパス確認を追加し、社内プロキシ等による自己署名 CA チェーンで SSL 検証に失敗した場合の設定案内を出すようにしました。
- SSO ログイン前に AWS OIDC エンドポイント (`oidc.<region>.amazonaws.com:443`) への接続確認を表示し、接続できない場合はプロキシ、ファイアウォール、NAT/Internet Gateway、DNS、HTTPS(443) の確認ポイントをログインウィンドウとログに残すようにしました。
- RDP/SSH 先のサーバで SSO ログインがブラウザ起動待ちのまま進まない状態を避けるため、ログイン用ウィンドウでは `aws sso login --no-browser --profile ...` を実行し、手元ブラウザで開く URL とコードを表示するようにしました。
- SSO ログインをログ付きの PowerShell ウィンドウで起動するようにし、AWS CLI が即時エラー終了しても画面にエラー内容が残り、`sso-login-*.log` に出力を保存できるようにしました。

## [2.16.0] - 2026-08-06

### Changed
- **`aws-instance-audit` の HTML レポート(Windows)を python3 不要にした**。
  `Get-AwsInstanceAudit.ps1` は `-HtmlReport` 指定時に python3 が無いと `exit 10` で
  止まっていた。`render_report.py` と同等の HTML を出力する PowerShell ネイティブ
  レンダラーを実装し、python3 があればそちらを優先(プラットフォーム間で出力が
  揃うため)、無ければ自動フォールバックするようにした。これで
  **launch.bat の GUI から SSM 経由で実行する 9 ツールすべてが、Windows 対象なら
  python3 なしで HTML レポートを生成できる**。
  Windows Store のダミー python のように「見つかるが実行できない」ケース
  (exit 9009 等)でも PS ネイティブへ倒す。
  なお Linux 版 `aws_instance_audit.sh` の `--html` は従来どおり python3 が必要。
- `aws-instance-audit/render_report.py`: メタ情報の `categories` を Python の
  リスト表記(`['instance', 'iam']`)ではなくカンマ区切り(`instance, iam`)で表示する
  ようにした。PowerShell ネイティブレンダラーと出力を揃えるため

### Added
- `tests/AwsInstanceAudit.HtmlRender.Tests.ps1`: PATH から python を隠した状態で
  HTML レポートを生成し、PS ネイティブレンダラーへフォールバックして全セクション
  (instance / IAM / SG / network)が出力されること、ポート範囲・全ポート表記、
  JSON 由来値の HTML エスケープを担保するテストを追加。python3 がある環境では
  両レンダラーの表示内容が完全一致することも検証する

## [2.15.0] - 2026-08-06

### Changed
- **`collect-snapshot` の差分レポート(compare)を python3 不要にした**。
  `ReportSnapshot.ps1` の compare モードは `compare_server_info.py` 専用のラッパーで、
  python3 が見つからないと `exit 10` で止まっていた。python3 があればそちらを優先し
  (プラットフォーム間で出力が揃うため)、無い場合は `ServerSnapshot.ps1` の
  PowerShell ネイティブ比較エンジンへ自動でフォールバックするようにした。
  比較ロジックは既存の PS 実装をそのまま使うため二重実装は発生しない。
  Windows Store のダミー python のように「見つかるが実行できない」ケース
  (exit 9009 等)でも PS ネイティブへ倒す。
  併せて README の前提表・終了コード表を実態に合わせ、`exit 10`(python3 不足)を廃止した
  (比較エンジンが両方見つからない場合は `exit 2`)。
  なお Linux 版 `server_snapshot.sh` は JSON 生成自体に python3 を使うため、
  従来どおり python3 が必要。

### Added
- `tests/ReportSnapshot.CompareFallback.Tests.ps1`: PATH から python を隠した状態で
  compare を実行し、PS ネイティブ比較エンジンへフォールバックして HTML 差分レポートが
  生成されること(サービス追加・バージョン変更の検出まで)を担保するテストを追加。
  python3 がある環境では `compare_server_info.py` 経路も同時に検証する

## [2.14.0] - 2026-08-06

### Changed
- **ツールランチャー: perf-monitor の出力先を「セッション」欄に合わせるようにした**。
  従来は実行のたびに作られる `reports/local-tools/perf-monitor/<実行時刻>/artifacts/`
  を常に `-OutputDir` に渡していたため、`start` のたびにセッションが別の場所へ
  散らばっていた。セッション欄が指定されている場合は、その場所に新しいセッションが
  並ぶように出力先を揃える(セッションディレクトリ自体を指定 → その親 /
  セッションを束ねるフォルダを指定 → そのフォルダ自体。空欄なら従来どおり実行ごとのフォルダ)。
  併せて「セッション」欄にこの挙動を説明するツールチップを追加
- ツールランチャー: `report` 実行後のレポート自動オープンが、指定セッション配下の
  `report.html` も探すようにした。`report` は実行フォルダではなくセッション配下へ
  出力するため、従来は自動オープンが空振りしていた

### Fixed
- `perf-monitor`: ディスク使用率グラフで、検出ドライブが1台のみの場合に折れ線が
  描画されない問題を修正。PowerShell では、要素数1の配列を返す関数の戻り値を
  変数へ代入すると自動的にスカラー値へアンラップされる罠があり、`$diskDrives`
  が文字列 `"C:"` そのものになった結果、配列添字アクセス `$diskDrives[$i]` が
  「文字列の1文字目」を返してしまい、ドライブ名の照合が失敗して全データ点が
  欠測(null)扱いになっていた。関数の戻り値を受け取る箇所を `@(...)` で明示的に
  配列化することで解消(`PerfMonitor.ps1` の `Get-DiskDriveNames` /
  `Get-DiskDriveVals` / `Get-ChartValsForDrive` 呼び出し箇所)。

## [2.13.0] - 2026-08-06

### Added
- **`perf-monitor`: ディスク使用率(容量 %)の収集・グラフ化を追加**。検出された
  全ドライブ/マウントポイントを自動収集し、レポートにドライブごとの系列として
  グラフ化する(Windows は固定ディスクのみ、Linux は仮想 FS を除く全マウント)。
  `ThresholdDiskUsedPct`(既定 90.0%)のしきい値アラート・統計テーブル・サマリー
  カードにも対応（`render_report.py` / `PerfMonitor.ps1` 両レンダラー）。
- `ssm-tasks/{linux,windows}/tool-*.yaml`: 配備済み `tools/` のスクリプトを
  SSM Run Command から実行する定義を追加（雛形 + 全 9 ツール × 2 プラット
  フォーム = 20 ファイル）。対象は aws-instance-audit / cert-check /
  collect-snapshot / file-transfer-check / log-collector / network-check /
  perf-monitor / port-inventory / server-snapshot。
  集約側で動く env-doc と Snapshot Report はリモート実行の対象外。
  HTML 等の成果物はサーバ側の `<OpsRoot>/reports/local-tools/<tool-id>/<timestamp>/artifacts`
  に残し、SSM には実行サマリ（exit code / run ディレクトリ / 成果物一覧 /
  ログ末尾）だけをテキストで返す。SSM 応答の 24,000 文字上限を踏まえ、
  HTML 本体を SSM 経由で持ち帰る設計は採らない。
  Linux は非対話 CLI を持つ `local-tools-launcher.sh run <tool-id>` 経由、
  Windows は GUI 専用ランチャーに CLI が無いためツール本体を直接起動する。

### Fixed
- `perf-monitor`: SVG レポートのグラフ凡例・統計テーブル・サマリーカード・
  しきい値超過一覧に、ディスクのドライブ名/マウントポイント名を HTML エスケープ
  せずに埋め込んでいた問題を修正（`render_report.py` / `PerfMonitor.ps1` 両方）。
  細工された `data.jsonl` からの HTML インジェクションを防ぐ。
- `render_report.py`: ローカル変数 `html`（出力 HTML 文字列）が `import html`
  モジュールをシャドーイングし、`html.escape()` 呼び出しが `UnboundLocalError`
  になっていた問題を修正（変数名を `html_out` に変更）。
- `server-snapshot`: 1 カテゴリ内で例外が発生してもスクリプト全体が exit 4
  で停止してしまい JSON が書き出されなかった問題を修正。カテゴリ単位で例外を
  握り、失敗したカテゴリは `{ error = "..." }` として記録、他カテゴリの結果と
  合わせて必ず JSON を書き出すようにした（`meta.errors` に集約）。
- `server-snapshot` の `filelist`: 個別 target のパスがドライブ不存在や
  クォート混入で `Test-Path` / `Get-Item` が例外を投げても、他 target の収集を
  止めないよう保護。該当 target は `exists = false` + `errors[]` に理由を記録。

## [2.12.0] - 2026-07-28

### Changed
- **`tools/env-doc`: 掲載範囲を「定義」に限定し、実行時の状態と時刻を載せないようにした**。
  環境定義書は「どう設定されているか」を記録するものであり、「今どうなっているか」は
  `perf-monitor` / `port-inventory` など別ツールの役割であるため。除外したのは次のとおり。
  - サービスの稼働状態(`status`)。一覧は起動設定(`start_type`)でグループ化し、
    列も 起動設定 / 実行ユーザー / 実行ファイル に変更
  - `os.last_boot`(最終起動)
  - ミドルウェアの `state`
  - `remote_access` の各サービスの稼働状態(起動設定を出す)
  - filelist の `mtime`(更新日時)
  - 収集日時・生成日時

  この結果、**同じ入力からは毎回バイト単位で同じ HTML が出る**ようになった。
  2 世代を diff すればタイムスタンプのノイズに埋もれず構成変更だけを抽出できる
  (同一入力で 2 回生成し全ファイルの SHA-256 が一致することをテストで担保)

### Added
- **`tools/env-doc`: 上部に戻る導線を追加**。ヘッダを `position: sticky` で常時表示にし、
  長いページ(サービス全件 / ファイル一覧 / パッケージ / 設定ファイル)の末尾に
  「▲ ページ上部へ」を置いた。アンカーで飛んだ先が固定ヘッダに隠れないよう
  `scroll-margin-top` も併せて指定

## [2.11.0] - 2026-07-28

### Added
- **`tools/env-doc`: 件数の多い情報へのアクセス性を改善**。実機ではサービスが 300 件近く、
  ファイル一覧が数千件になり 1 ページに並べるとスクロールが破綻するため、次を追加した。
  - **サービス全件を `servers/<host>-services.html` に分離**。サーバ詳細には総数・稼働中・
    **自動起動だが停止**の要約だけを残す。全件ページの先頭には **状態 × 起動設定のクロス集計**を置き、
    「自動起動なのに停止している」件数を折りたたみを開かずに把握できるようにした。
    Windows(`automatic`/`running`)と Linux(`enabled`/`active`)の語彙差は吸収する
  - **ファイル一覧をディレクトリツリー表示に変更**。`rel_path`(Windows は `\`、Linux は `/` 区切り)を
    分解して階層に組み直し、ディレクトリごとに折りたたむ。各階層の見出しに配下の
    ファイル数・ディレクトリ数を出し、開く前に規模が分かるようにした
  - **ページ内目次**をサーバ詳細・サービス全件・ファイル一覧に追加
  - 折りたたみは `<details>` のみで実現し JavaScript は使わない

### Changed
- **`tools/env-doc`: ナビゲーションの並びを 概要 / AWS / ネットワーク / OS / ミドルウェア に変更**。
  OS が土台でミドルウェアがその上に載る順序に合わせた

### Fixed
- **`tools/env-doc`: 空配列を返す関数で空行が出る問題を修正**。`ArrayList.ToArray()` を
  `return` すると空配列が `$null` にアンロールされ、`New-HtmlTable` 側で `@($null)` が
  1 要素になって `<tr><td></td></tr>` が描画されていた
- **`tools/env-doc`: サービスが 0 件のときのリンク切れを修正**。全件ページは 0 件だと
  生成されないのに、サーバ詳細が無条件にリンクしていた

## [2.10.0] - 2026-07-27

### Fixed
- `server-snapshot` の `filelist.conf` で、Windows ドライブ直下を `path = D:` や
  `path = "D:\"` のように指定した場合でも `D:\` として扱うようにし、引用符が
  `Test-Path -LiteralPath` に渡って対象なしになる問題を防止。

### Added
- **`tools/env-doc`**: システム環境定義書ジェネレータを追加。`server-snapshot` と `aws-instance-audit` の JSON、および手書きの `system.yaml` から、システム単位のマルチページ静的 HTML を生成する。トップにシステム概要とサーバ一覧、AWS / ネットワーク / ミドルウェア / OS の横断ページ、サーバごとの詳細ページと全件ページ(packages / filelist / 設定ファイル)を出力。比較グループ内で値が揃っていない行をハイライトし、Windows / Linux 混在システムでは OS 別サブ表に分けて比較する。PowerShell 5.1 のみで動作し外部モジュールに依存しない(YAML はサブセットを自前パース)。出力は相対リンクのみで構成され、ディレクトリごと GitLab Pages に配置できる。環境変数と設定ファイル全文は既定で非掲載(`show_environment` / `show_configs` で opt-in)
- **`server-snapshot remote_access` カテゴリを追加**。Windows は RDP/RDS
  (RDP 有効/無効、NLA、ポート、`RDP-Tcp` レジストリ、Terminal Services 系サービス)、
  Remote Assistance、OpenSSH、関連 Firewall ルールを収集。Linux は SSH / xrdp /
  VNC 系 systemd unit と代表設定ファイルを収集する。
- **`server-snapshot services` にサービス設定情報の収集を追加**。Windows は `Win32_Service`
  の実行パス・実行ユーザー・説明に加え、OpenSSH の `sshd_config` と SMB
  (`LanmanServer` / `LanmanWorkstation`) の `Parameters` レジストリを収集。Linux は
  systemd の `FragmentPath` / `ExecStart` / `User` / `Group` 等と、OpenSSH
  (`/etc/ssh/sshd_config`) / Samba (`/etc/samba/smb.conf`) の設定ファイルを収集。
  設定ファイル本文は既存のマスク処理を通して保存する。
- **file-transfer-check のお客様向け実施手順書(PowerPoint)を追加**。`output/file-transfer-check-手順.pptx`(全11ページ、Windows 環境向け)と生成スクリプト `source/build-file-transfer-check-deck.js`(pptxgenjs)。非技術者のお客様がフォルダのコピー → bat のダブルクリック → 結果送付までを実施できる構成。`.gitignore` に `!output/*.pptx` の例外を追加し、資料成果物を追跡対象にした

## [2.9.0] - 2026-07-25

### Added
- **`tools/file-transfer-check`**: SMB 共有への往復ファイル転送で疎通・整合性(SHA-256)・スループット(MB/s)を確認するスタンドアロンツールを追加。お客様端末で直接実行し(SSM を介さない)、サーバへのファイル転送可否を end-to-end で確認する。Windows(起動用 bat + PowerShell)/ Linux(smbclient)対応、統合認証・専用ユーザーの両対応でパスワードは実行時に非エコー入力(平文保存・ログ出力なし)。`shares.lst` で複数共有を一括確認し、`-HtmlReport` で HTML レポート出力。Windows の bat は SET ブロックの既定値でダブルクリック実行、またはコマンドライン引数で上書き可能。`tool-catalog.yaml` にも登録

## [2.8.1] - 2026-07-22

### Fixed
- LocalToolsLauncher の設定ダイアログで「ツールルート」/「出力先」を変更しても、選択中ツールのパラメータ欄・設定ファイル欄の表示に反映されない問題を修正。設定保存時に `Update-CommandPreview` だけでなく `Update-SelectedTool` を呼び、選択中ツールのパネルを新しい設定値で再構築するようにした

## [2.8.0] - 2026-07-22

### Changed
- **perf-monitor レポートのグラフ描画方式を Chart.js から純粋な SVG に変更**。`render_report.py` / `PerfMonitor.ps1` の両方で、折れ線グラフ(塗りつぶし・しきい値ライン・凡例含む)を JavaScript 実行に一切頼らない静的 SVG マークアップとして生成するように書き換えた。会社PCなど JS 実行がセキュリティポリシーで制限される環境や、同梱ライブラリ(`chart.umd.min.js`)が何らかの理由でファイルパス解決に失敗し CDN フォールバックに落ちてオフライン環境で読み込めないケースでも、確実にグラフが表示される
- 同梱していた `tools/perf-monitor/chart.umd.min.js`(Chart.js v4.5.1)を削除。外部ライブラリ依存が完全になくなったため不要

### Added
- LocalToolsLauncher の tool-catalog.yaml パラメータに `tooltip` フィールドを追加し、GUI 上でラベル/入力欄にホバーすると説明が表示されるように対応。perf-monitor の `report` 用範囲指定パラメータ(`from`/`to`)に ISO 8601 形式の入力例をツールチップとして表示

## [2.7.0] - 2026-07-21

### Added
- **SSM Run Command タブ用のインフラ調査タスクを追加**。`ssm-tasks/linux/` と `ssm-tasks/windows/` にそれぞれ12種類(OS基本情報、ディスク使用状況、メモリ使用状況、CPU/負荷状況、ネットワークI/F、ネットワーク接続/待受ポート、プロセス一覧、サービス状態、パッケージ/ソフトウェア一覧、ログ確認、ファイアウォール設定、ディスクI/O)を追加。distro差異が大きいコマンド(パッケージ管理、ファイアウォール)は自動判定するようにした

## [2.6.0] - 2026-07-19

### Fixed
- **perf-monitor レポートでグラフが表示されない問題を解消**。両レンダラー(`render_report.py` / `PerfMonitor.ps1` ネイティブフォールバック)とも Chart.js を CDN(cdn.jsdelivr.net)から読み込んでおり、インターネットに出られない踏み台/AVD 環境では描画に失敗していた。Chart.js v4.5.1(MIT)を `tools/perf-monitor/chart.umd.min.js` として同梱し、レポート HTML に inline 埋め込むよう変更(同梱ファイルが見つからない場合のみ CDN にフォールバック)

### Added
- **perf-monitor: サンプル数が多い場合の自動間引き**。グラフ描画のみ 2000 点を超えたら等間隔で間引き(統計値・しきい値超過一覧は常に全データが対象)。間引き発生時はレポートに注記を表示
- **perf-monitor: `report` コマンドに時間範囲フィルタを追加**(Windows: `-From`/`-To`、Linux: `-f`/`-t`。片方のみの指定も可)。絞り込み後の全データを対象に統計・アラートを計算
- LocalToolsLauncher のカタログに `directory` 型パラメータの `sessionDir` 連携と `from`/`to` パラメータを追加し、汎用実行フローからそのまま範囲指定可能に

## [2.5.0] - 2026-07-19

### Changed
- **perf-monitor 専用パネル(v2.4.0)を廃止し、個別ツールパネルへ統合**。専用パネルと汎用実行パネルでセッション欄・start/stop・Duration が二重に見える問題への対応。開始/停止はツール一覧の perf-monitor を選択し「アクション」ドロップダウン(start/stop)+「実行」で行う。セッションディレクトリの自動検出・自動入力は汎用パラメータ欄に対して行われる

### Added
- **カタログに `directory` 型パラメータを追加**(パス入力欄 + `...` フォルダ選択 + `開く` エクスプローラ起動)。perf-monitor の「セッション」で使用
- perf-monitor に「間隔秒」パラメータ(`-Interval`)を追加(空欄ならツール既定値の 5 秒)

## [2.4.1] - 2026-07-18

### Fixed
- `LocalToolsLauncher.ps1` の `Build-Command` が PSScriptAnalyzer `PSUseApprovedVerbs` に違反していた問題を解消(`New-ToolCommand` にリネーム)。v2.0.0 以前から存在していた既存の lint 漏れで、今回の select 型/perf-monitor 実装より前から存在

## [2.4.0] - 2026-07-18

### Added
- **LocalToolsLauncher(Windows GUI)に選択式パラメーター(`select`型)を追加**。`tool-catalog.yaml` の `parameters[].type: select` + `options` でコンボボックス化でき、`server-snapshot`/`perf-monitor` の「アクション」パラメーターを自由入力からドロップダウン選択(コード側 `ValidateSet` と一致する選択肢)に変更
- **perf-monitor 専用の開始/停止パネル**をヘッダー直下に追加(既存の「スナップショット一括実行」パネルと同じ配置)。間隔(秒)/時間(秒)を指定して「開始」でバックグラウンド収集を起動し、完了後にセッションディレクトリを自動検出してテキストボックスへ反映。「停止」で当該セッションを停止。セッションディレクトリはツール一覧の汎用実行パネル側にも初期値として共有される(一方向同期)

### Fixed
- **perf-monitor の「開始」実行時に GUI 全体がハングするデッドロックを解消**。バックグラウンド収集プロセス(検知プロセス)が標準出力/エラーのパイプハンドルを継承したまま保持し続けるため、`Invoke-ToolExecution` 側の出力読み取りが EOF を検知できず無期限にブロックしていた問題。プロセス終了自体は `WaitForExit()` で確定しているため、出力読み取りに 3 秒のタイムアウトを設けて解消(通常のツールは無影響)

## [2.3.2] - 2026-07-18

### Fixed
- CI 緑化の残り 2 件: App.ps1 のイベントハンドラ引数名(`$sender`/`$eventArgs` → PSSA 自動変数警告)をリネーム、既存テストの Pester v4 構文 `Assert-MockCalled` を `Should -Invoke` に置換(CI の最新 Pester で削除されていたため)。**これで CI(lint + Pester + Linux smoke)が全ジョブ緑**。

## [2.3.1] - 2026-07-18

### Fixed
- CI(PSScriptAnalyzer)が v2.0 以降ずっと失敗していた問題を解消。未承認動詞の関数をリネーム(`Render-*` → `Show-*`、`Load-*` → `Import-*`、`Append-Log` → `Add-LogLine`、`Poll-RunningProcess` → `Watch-RunningProcess`)し、設計上意図的なパターン(コールバック契約引数・ベストエフォート catch・Pester 構造の誤検知等)は理由コメント付きで lint ルールを除外。

## [2.3.0] - 2026-07-18

### Added
- **Linux ツールランチャー v2**(`local-tools-launcher.sh` を仕様書 [2026-07-18-linux-launcher-v2-design.md](docs/superpowers/specs/2026-07-18-linux-launcher-v2-design.md) に基づき再実装):
  - 対話フロー短縮: ツール選択 → 既定値一覧 + コマンドプレビュー表示 → **Enter で即実行 / e で編集 / n で中止**(毎回の全パラメーター質問を廃止)。必須パラメーターは実行前にチェック
  - **実行中のライブ出力**: stdout/stderr を画面表示しつつ run ディレクトリへ保存(tee)。完了後に成果物(artifacts)一覧を表示
  - 終了ステータスを Windows 版と同じ意味論に: exit 0 = `[ok]` / exit 1 = `[warn] NG 検出またはエラー` / exit 2+ = `[FAIL]` / 128+ = 中断
  - **AWS Profile を `~/.aws/config` からの番号選択に**(実行時は `AWS_PROFILE` を export)
  - ツール一覧に説明(description)を表示
  - **非対話モード**: `list`(TSV 一覧)/ `run <tool-id> [--set key=value ...] [--dry-run]`(既定値実行・exit code 透過)/ `archive [<id>]`(run の tar.gz 化)。cron / SSM Run Command からの定型実行に対応
- tool-catalog に `linuxArgument` / `linuxArgName` を追加し、Linux ツール(getopts / GNU 形式)の引数名をカタログで吸収(Windows 側パーサは未知キーを無視するため無影響)
- smoke テスト `tests/linux-launcher-smoke.sh`(48 項目)と CI の ubuntu ジョブを追加

### Fixed
- **v1 の Linux ランチャーがカタログの PowerShell 形式引数(`-TimeoutSec` 等)をそのまま .sh ツールへ渡しており、ツール実行が失敗していた問題を修正**(`linuxArgument` 対応で解消)

### Changed
- **ツールランチャー(LocalToolsLauncher)の UI を本体と統一**。パレット・ボタン/コンボ/リストのスタイル・ヘッダー・ステータスバーを aws-ec2-manager 本体と同一デザインに刷新(設定ダイアログも同様)。
- AWS Profile を手入力 TextBox から `~/.aws/config` のプロファイル一覧ドロップダウンに変更(本体と同じ AwsConfig.psm1 を利用)。
- ツール一覧を「名前 + 説明」の 2 行表示に変更し、ツール解決を表示文字列一致からオブジェクト参照に変更。
- 「プレビュー更新」ボタンを廃止(パラメーター変更で自動更新のため冗長)。コマンドプレビューはパラメーターの下に移動。
- 実行終了時のステータス表記を改善: 非 0 の ExitCode は「失敗」と断定せず「NG 検出またはエラー」と表示(cert-check / port-inventory 等はチェック NG で非 0 を返すため)。

### Added
- **実行成功時に HTML レポートを自動で開く**(設定 `OpenReportAfterRun` は従来から存在したが未実装だった)。NG 検出時(非 0 終了)もレポートがあれば開く。
- ログ欄に「実行結果フォルダ」(直近の実行ディレクトリを開く)と「クリア」ボタンを追加。
- 実行中インジケーター(ステータスバーのプログレスバー)を追加。ログ欄の高さを GridSplitter で調整可能に。
- tool-catalog: server-snapshot に HTML レポートオプションを追加(after/compare 時。ツール本体は対応済みだった)。
- テスト: LocalToolsLauncher のコントロール一覧チェックを追加。

### Fixed
- プロファイル一覧の取得で unary-comma 配列が 1 要素に化け、全プロファイルが連結表示される問題を修正。

### Added
- **SSM ログイン機能**。ツール実行タブの「SSM ログイン」ボタンで、選択インスタンスに Session Manager の対話セッションを別ウィンドウで開始する(`aws ssm start-session`)。
  - **対象ユーザー指定に対応(Linux のみ)**: ユーザー欄に OS ユーザー名を入れると `AWS-StartInteractiveCommand` + `sudo su - <user>` でそのユーザーとしてログイン。空欄なら既定の `ssm-user`。Windows インスタンスはユーザー指定不可(ssm-user 固定)で、指定時は案内を表示。
  - ガード: ロック中インスタンスはブロック、SSM が Online でない場合は案内、`session-manager-plugin` 未インストール時はインストール手順(winget)を案内。
  - ユーザー名は英数字と `. _ -` のみ許可(コマンドインジェクション防止)。

### Changed
- 公開ドキュメント(設計書・プラン)から検証用 SSO プロファイル名を除去。

### Changed
- **UI をマスター/ディテール型に全面再構成**。左ペインに常駐のインスタンス一覧(検索フィルタ + 電源操作 + ロック)、右ペインに選択インスタンス追従のタブ(詳細 / セキュリティグループ / インスタンスロール / ツール実行)。タブごとのインスタンス選択 ComboBox・更新ボタン・タブ間同期コード(約 500 行)を全廃し、選択は 1 箇所に統一。
- **全 AWS CLI 呼び出しを非同期化**。バックグラウンド Runspace + `Dispatcher.BeginInvoke` によるイベント駆動の実行基盤(`src/AsyncRunner.ps1`)を導入し、describe / 電源操作 / SG / ロール / SSM 実行のすべてで UI がフリーズしなくなった。UI 側に常時タイマー・定期ポーリングは置かない。実行中はステータスバーにプログレスとキャンセルボタンを表示し、aws プロセス kill + SSM リモート `cancel-command` で中断できる。
- App.ps1(3,237 行)を薄いエントリ(約 130 行)+ 機能別 `src/*.ps1`(AsyncRunner / AppState / UiCommon / HeaderPane / InstanceListPane / DetailTab / SgTab / RoleTab / SsmTab)に分割。
- SG / インスタンスロール情報はインスタンス ID 単位でキャッシュし、タブがアクティブになったときだけ遅延取得。手動「再取得」ボタンを各タブに配置。
- インスタンス詳細を別ウィンドウから右ペインの「詳細」タブに変更(一覧ダブルクリックで詳細タブへ。行ダブルクリックで値コピーは維持)。
- AWS CLI プロセスタイムアウトを 60 秒 → 120 秒に拡大(遅いネットワーク/プロキシ環境で `stop-instances` が 60 秒を超過する実測に対応)。

### Added
- インスタンス一覧の絞り込みフィルタ(Name / InstanceId / Private IP / Public IP の部分一致)。
- 一覧 0 件時・未選択時の案内表示(empty 状態)、タブ内の取得中表示(loading 状態)。
- `AwsManager.psm1` にキャンセルチャネル(`Set-AwsCliChannel`)を追加。実行中 aws プロセスの PID 公開と `CancelRequested` による SSM ポーリング中断・リモートキャンセルに対応。
- テスト追加: AsyncRunner(イベント駆動完了・進捗・キャンセル)、AppState(フィルタ・ロック・キャッシュ)、キャンセルチャネル、全 .ps1/.psm1 の構文 + UTF-8 BOM チェック、MainWindow コントロール一覧チェック。

### Fixed
- SG 差分 HTML 出力が `Get-SafeFileName -Text`(存在しないパラメータ)で失敗していた潜在バグを修正。
- ロック機能は現行仕様のまま維持(一覧のロック列、電源操作 / SG 適用 / ロール適用 / SSM 実行のブロック、設定ファイルへの永続化)。

### Fixed (v1.6.0 リリース後の未リリース修正分)
- `Invoke-AwsCli`（AwsManager 側）にプロセスレベルのタイムアウト（既定60秒）を追加。ネットワーク障害等で aws CLI プロセスが応答しなくなり、アプリ全体がフリーズする問題を防止。
- インスタンス起動・停止・再起動・SG適用が AWS CLI 失敗時に詳細を伏せたまま `$false` を返していた問題を修正し、CLI のエラー詳細を伴って例外を送出するよう統一。ステータスバー・ログに具体的な失敗理由が表示される。
- SSM 情報取得（`describe-instance-information`）が権限不足等で失敗した場合に「未登録」と誤表示していた問題を修正。取得失敗は「SSM情報取得失敗」として区別して表示する。あわせて、App.ps1 が設定する `$ErrorActionPreference = 'Stop'` の下では内部の `Write-Error` 自体が終了エラーとなり EC2 一覧全体が取得できなくなっていた回帰を修正（`-ErrorAction Continue` を明示）。
- SSM 実行・インスタンス操作・SG適用・インスタンスロール適用の実行中、DoEvents 相当の UI ポンプにより操作系ボタンが再クリックできてしまい、ハンドラが再入し得た問題を修正。処理中は関連ボタンを無効化するガードを追加。
- `AwsConfig.psm1` の `Invoke-AwsCli` が `AwsManager.psm1` と別実装（`& aws 2>&1` 方式）で挙動差の元になっていたため、プロセスタイムアウト付きの同一実装に統一。
- SSM タスク YAML の自作パーサ（`ConvertFrom-MinimalYaml`）が、インデント崩れ等で解釈できない行を黙って読み飛ばしていた問題を修正。認識できない行はまとめてエラーにし、意図と異なる内容がリモートで実行されるのを防ぐ。
- SSM コマンドがクライアント側のタイムアウトでポーリングを打ち切った後もリモートでは実行が続いていた問題を修正。タイムアウト時は `aws ssm cancel-command` でリモート側のキャンセルもベストエフォートで試みる。
- SG適用・インスタンスロール適用後、キャッシュ済み一覧の `SecurityGroupNames` が空に、`IamInstanceProfileArn` が空文字になったまま残っていた問題を修正。変更対象の1台だけ AWS から取り直して丸ごと差し替えるよう統一（`Get-Ec2Instances` に `-InstanceIds` フィルタを追加）。
- `Get-InstanceProfileAssociation` にあったほぼ同一のループ（associated優先→フォールバック）を共通関数 `ConvertTo-IamInstanceProfileAssociationObject` に抽出して重複を解消。
- アプリログ出力先に日付フォルダが無期限に溜まり続ける問題を修正。起動時に保持日数（既定30日）を超えた過去フォルダを自動削除するようにした。
- MainWindow.xaml / LocalToolsLauncher*.xaml の構文破損を起動前に検出できるよう、XamlReader での読み込みスモークテストを追加。
- SSM コマンド実行の確認ダイアログにタスク名しか表示されず、リモートで実際に何が実行されるか確認できなかった問題を改善。実行内容（スクリプト冒頭部分）をダイアログ内にプレビュー表示するようにした。

## [1.6.0] - 2026-07-07

### Added
- セキュリティグループ適用プレビューに「実効ルール差分」を追加。付け外しする SG のルールを集約し、instance として実際に増減するルール（Direction/Protocol/Port/Target、メモ欄は対象外）だけをネット差分として表示。画面・テキスト・HTML 出力に対応。
- インスタンスロール管理タブを追加。IAM Instance Profile の候補一覧から、EC2 インスタンスへのアタッチ、デタッチ、入れ替えを実行できるようにした。

### Changed
- インスタンス一覧の取得を初回表示時と EC2 インスタンスタブの「更新」ボタン押下時に限定し、SG / インスタンスロール / SSM タブはキャッシュ済み一覧を再利用するよう変更。

### Fixed
- セキュリティグループ移動時、実効ルールが 1 件だけの SG を含むとプレビュー再計算で落ちる問題を修正。
- セキュリティグループ移動時の ListBox 更新を ID ベースに変更し、選択中の ItemsSource 差し替えでアプリが落ちる可能性を低減。
- 未処理の UI イベント例外をステータスバーとログに記録し、操作中の例外でアプリ全体が終了しないように改善。
- SG 差分の GUI「HTML出力」ボタンで、HTML 出力後に Edge または既定ブラウザで確実に開くよう改善。HTML レポートには実効ルール差分の留意事項を追記。
- インスタンスロールタブの配置を SG タブと同じ左右ペイン + 中央操作 + 下段差分に揃え、入れ替え失敗時は AWS CLI の詳細エラーを表示するよう改善。
- インスタンスロールタブのインスタンス選択ヘッダーを SG タブと同じ固定幅 1 行レイアウトに統一し、選択済みインスタンスの再反映時にも詳細が必ず更新されるよう修正。
- インスタンスロールのデタッチ後、空文字の表示テキストや不要な InstanceProfileName パラメータで UI エラーになる問題を修正。
- インスタンスロール操作を SG と同じ「適用予定 / 候補 / 差分 / 適用」フローに統一し、アタッチ・デタッチ・入れ替えを `適用` ボタンで反映するよう修正。
- インスタンス一覧の選択変更時に SG / インスタンスロール詳細取得が連動して走り、画面操作が重くなる問題を修正。

## [1.5.0] - 2026-07-02

### Added
- スナップショット一括実行のレポート生成で、収集 ZIP に加えて
  `server-snapshot` JSON を直接指定できるようにした。比較対象も ZIP / JSON
  のどちらでも指定可能。
- 単体スナップショット HTML レポートに `filelist` セクションを追加。
  ターゲット概要、エントリ一覧、ACL 件数、SHA256、エラー一覧を表示する。

### Changed
- ツールランチャーのスナップショット入力欄を「ZIP / JSON」対応の文言と
  ファイル選択フィルターに更新。
- Linux 版ローカルツールランチャーを、カタログ駆動の対話メニュー、設定ファイル
  override、実行結果アーカイブに対応する形へ拡張。
- `launch-tools.bat` を `launch.bat` と同じ非同期・非表示起動に揃え、
  起動後にコンソールウィンドウが残らないようにした。

### Fixed
- `server-snapshot` / Linux 版 `server_snapshot.sh` の `filelist.conf` パーサーで、
  `path = D:\ # comment` のようなインラインコメントを値として扱ってしまい、
  指定ディレクトリが収集されない問題を修正。
- `compare_server_info.py` が UTF-8 BOM 付き JSON を読めず、ZIP 比較レポート生成が
  `Unexpected UTF-8 BOM` で失敗する問題を修正。

## [1.4.0] - 2026-07-02

### Changed
- ランチャーのセクション名を変更: 「スナップショット統合ツール」→
  「スナップショット一括実行」、「ツール」→「ツール個別実行」。
- ヘッダーボタンをアイコン付きに変更し、ラベルと開く先を整理:
  「保存先」→「ツール保存先」（tools を開く）、「ログ」→「出力先」
  （reports を開く）。「設定」にも歯車アイコンを付与。
- ランチャーのログ出力欄を各ツールペイン内から切り出し、ツール一覧と設定ペインの
  下に全幅の共通「ログ出力」ペインとして配置。全ツールで同じ位置・同じ高さになる。
- ランチャー右ペインの並び順を全ツール共通に統一: タイトル/説明 →
  コマンドプレビュー → 設定ファイル → 実行パラメーター。処理ボタン
  （プレビュー更新／実行／停止）はツール名の右側（右寄せ）に配置して専用行を廃止。
- ウィンドウ既定高を 780→860 に拡大（共通ログペイン追加に伴う調整）。
- ランチャーの実行パラメーター欄を動的レイアウト化し、コンソール表示ペインの
  つぶれを緩和。
  - 数字型パラメーター（`type: number`）を短幅フィールドにして横並び（自動折返し）
  - 短い文字列パラメーターに `width: short` を追加し、数字と同じ横並びに集約
    （例: log-collector の プリセット / 期間 / 最大 MB を 1 行、server-snapshot の
    アクション / ラベルを 1 行）
  - チェックボックスも横並びにまとめて行数を削減
  - `paramKey` ルーティングの設定ファイルは、専用行を廃止して該当パラメーター行に
    `...`（選択）と「開く」を統合。同じパスが2か所に出る重複を解消
  - 設定ファイル行のパス欄を編集可能にし、直接入力／`...`選択の両対応

## [1.3.0] - 2026-07-01

### Added
- server-snapshot に `filelist` カテゴリを追加。設定ファイル `filelist.conf` で
  指定したディレクトリ配下のファイル・ディレクトリ一覧を権限・オーナー情報付きで
  収集し、before/after 比較で差分を検出できる。
  - Windows: NTFS Owner / ACL、Linux: POSIX mode / uid / gid / owner / group
  - `hash = true` でファイル sha256 を計算し、内容変化も検出
  - `exclude` パターン、`depth` 制限、`max_entries_per_target` セーフガード対応
- ローカルツールランチャーで、各ツールの設定ファイルを「設定ファイル」セクション
  として表示。「...」でエクスプローラから別ファイルを選択、「開く」で関連付け
  エディタ起動。
  - 選択した override パスは `%LOCALAPPDATA%\aws-ec2-manager\tool-launcher.json`
    に per-tool per-label で永続化
  - routing を `tool-catalog.yaml` の `configFiles` で指定可能
    - `envVar`: 子プロセスの env var で渡す（server-snapshot の
      `_OPS_MW_CONF` / `_OPS_FILELIST_CONF`）
    - `argName`: CLI 引数として付与（log-collector `-ConfigFile`、
      perf-monitor `-Config`）
    - `paramKey`: 既存パラメータ textbox に反映（cert-check / network-check /
      port-inventory のターゲットリスト）

### Changed
- ランチャーの各ツール説明を短い日本語に置き換え、説明欄の余白を詰めて
  スペース節約。

### Fixed
- server-snapshot の compare で Windows 側 filelist エントリの `mode` / `group`
  が `System.Collections.Hashtable` と表示されていた件を修正（`Obj-To-Dict` が
  null 値を空 hashtable に変換する挙動を回避）。
- filelist の symlink `link_target` を PS 5.1 で scalar string として出力
  （元々 `IEnumerable<string>` で配列化されていた）。

## [1.2.2] - 2026-07-01

### Changed
- スナップショット統合ツールのラベルを「出力先」→「**出力対象ZIP**」に変更。実態（レポート生成の入力となる ZIP ファイル）が一目で分かるように
- ラベル列幅 (100→120) とツールチップ文言を統一
- 自動入力時のログメッセージ、未入力時のエラーメッセージも「出力対象ZIP」基準に更新

## [1.2.1] - 2026-07-01

### Fixed
- スナップショット統合ツールで「比較 ZIP」しか入れずに「レポート生成」を押すと「ZIP パスを指定してください。」エラーが出ていた件
  - エラー文を「出力先」基準に書き換え（収集実行で作成された ZIP のパスを指す旨を明記）
  - 「出力先」「比較 ZIP」「差分のみ」「収集実行 / レポート生成」ボタンにツールチップを追加
  - **「収集実行」成功時に、生成された ZIP のフルパスを「出力先」欄に自動入力**するように。続けて「レポート生成」を押すだけでよくなる

## [1.2.0] - 2026-07-01

### Changed
- ローカルツールランチャーのレイアウトを再構成
  - ヘッダーをスリム化し、AWS Profile と「保存先 / ログ / 設定」ボタンのみ常時表示
  - ツールルート・出力保存先・各種フラグは別ウィンドウの設定ダイアログ (`LocalToolsLauncherSettings.xaml`) に集約。`FolderBrowserDialog` で参照可能
  - スナップショット統合ツールセクションをヘッダー直下に独立配置
  - 「出力先」「比較 ZIP」に `OpenFileDialog` 連動の `...` 参照ボタンを追加
  - 左ペインにツール一覧、右ペインに実行パラメータ・コマンドプレビュー・実行/停止・ログを集約

## [1.1.0] - 2026-07-01

### Added
- ローカルツールランチャー（Windows WPF / Linux Bash）を追加。`tools/` 配下の運用ツールをサーバー上でローカル実行するための独立 GUI / CLI
  - `LocalToolsLauncher.ps1` / `LocalToolsLauncher.xaml` / `launch-tools.bat`: PowerShell 5.1 + WPF の独立ランチャー。バックグラウンド Runspace + DispatcherTimer によるノンブロッキング実行、Stop ボタン、stdout/stderr の UTF-8 エンコーディング指定、出力集約レイアウト（`reports/local-tools/<tool>/<timestamp>/`）
  - `tools/tool-catalog.yaml`: Windows / Linux の入口パスと GUI 入力欄を統合した共通カタログ。インデント幅判定方式の最小 YAML パーサで読み込み
  - `local-tools-launcher.sh`: Linux 対話式 CLI の暫定版。Windows 版確定後に同仕様で書き直す予定
- `docs/superpowers/specs/2026-06-29-local-tools-launcher.md` / `docs/superpowers/plans/2026-06-29-local-tools-launcher.md`: 仕様と実装計画

### Changed
- `.gitignore`: `reports/local-tools/` をランチャー実行ログとして無視

## [1.0.0] - 2026-06-27

### Changed
- GUI 全体をダークテーマに刷新し、ヘッダー、タブ、ボタン、DataGrid、ListBox、ステータスバーの視認性と操作感を改善
- メインウィンドウの初期サイズと最小サイズを調整し、EC2 / SG / SSM 各タブのレイアウト密度を改善

## [0.2.0] - 2026-06-26

### Added
- `Logger.psm1` モジュールを新規追加（`Initialize-AppLogger` / `Write-AppLog`）。`[yyyy-MM-dd HH:mm:ss] [LEVEL] メッセージ` 形式でプレーンテキストファイルに追記
- 設定ダイアログに「ログ出力先ファイルのパス」フィールドと参照ボタンを追加。空欄でログ無効
- `AppSettings.psm1` に `LogPath` フィールドを追加（`settings.json` に永続化）
- 操作ログ: プロファイル読込・選択、SSO トークン確認、SSO ログイン、インスタンス取得・起動・停止・再起動、SG 適用、SSM タスク実行の各操作を INFO/WARN/ERROR レベルで記録
- 設定変更時にログを再初期化するため、アプリ再起動なしにログパスを変更可能
- `docs/samples/aws-config.example` / `docs/samples/aws-credentials.example` を追加（SSO セッション参照 / レガシー SSO / IAM Access Key / デフォルト / AssumeRole の各書き方サンプル）
- ヘッダに「SSO ログイン」ボタンを追加。選択中プロファイルで `aws sso login --profile <name>` を別ウィンドウ起動する（ブラウザ承認後「トークン確認」を押せばトークン状態を確認できる）
- ヘッダに「開く」ボタンを追加。AWS config を notepad で開く（config が無ければそのディレクトリをエクスプローラで開くフォールバック）
- ヘッダに「設定」ボタンを追加。`%LOCALAPPDATA%\aws-ec2-manager\settings.json` に AWS config ファイルのパスを保存し、`$env:AWS_CONFIG_FILE` 経由で `aws.exe` サブプロセスにも伝搬。`AppSettings.psm1` モジュール (`Get-AppSettings` / `Save-AppSettings` / `Get-EffectiveAwsConfigPath`) を新規追加
- `AwsConfig.psm1` の `Get-DefaultConfigPath` が `$env:AWS_CONFIG_FILE` を尊重するように変更

### Fixed
- `aws` CLI の stderr（`Unable to parse config file: ...` など）がそのままコンソールに漏れていた問題を修正。`Invoke-AwsCli` を `2>&1` でstderrをキャプチャするように変更し、`Stderr` フィールドとして返すようにした（`AwsConfig.psm1` / `AwsManager.psm1` 両方）
- YAML ファイル読み込みが PS 5.1 既定の CP932 デコードで日本語が文字化けしていた問題を修正（`Get-Content -Raw -Encoding UTF8` に変更、`Get-SsmYamlList` / `Invoke-SsmTask` 両方）
- Tab3 で YAML が 1 件しかない場合に `Update-YamlListBoxForInstance` が PSCustomObject を ItemsSource に渡してしまい「PSCustomObject を IEnumerable に変換できません」例外が出ていた問題を修正
- `Get-AwsProfileDetail` が AWS CLI v2 形式 (`sso_session` 参照) のプロファイルで `sso_start_url` を `[sso-session <name>]` ブロックから解決するように修正
- `App.ps1` でプロファイル ComboBox に "String[] Array" と 1 項目だけ表示される問題を修正
- `Test-SsoToken` が `aws` CLI に引数を単一の連結文字列として渡してしまい `ParamValidation` エラーになっていた問題を修正
- `App.ps1` の Tab1/2/3 で unary-comma 返り値が二重ラップされていた問題を修正

## [0.1.0] - 2026-06-25

### Added
- `AwsConfig.psm1` モジュール: `Get-AwsProfiles` / `Get-AwsProfileDetail` / `Test-SsoToken` と Pester テスト
- `AwsManager.psm1` モジュール: EC2 列挙 / 起動・停止・再起動 / SG 取得・割当 / SSM Run Command (`Invoke-SsmTask`) と最小 YAML パーサ、Pester テスト
- `MainWindow.xaml` / `App.ps1` / `launch.bat`: WPF メインウィンドウ骨組み（プロファイル選択・SSO トークン確認・3 タブ構成のスタブ）
- Tab1（EC2 インスタンス管理）: DataGrid によるインスタンス一覧表示と更新 / 起動 / 停止 / 再起動ボタン（確認ダイアログ付き）
- Tab2（セキュリティグループ管理）: インスタンス選択 + 適用済み/未適用 SG の 2 ペイン UI、`<` / `>` ボタンで移動、`modify-instance-attribute` 経由で diff 確認後に適用
- Tab3（ツール実行）: `ssm-tasks/{linux,windows}` 配下の YAML を一覧表示し、選択インスタンスで `Invoke-SsmTask` を実行。`output: text` は TextBox に、`output: html` は `%TEMP%\aws-ec2-manager` に書き出して Edge で表示。サンプル YAML `ssm-tasks/linux/network-check.yaml` を追加
- プロジェクト初期化
- `ops-scripts-template/tools/` から 8 ツールを移植
  (aws-instance-audit / cert-check / collect-snapshot / log-collector /
   network-check / perf-monitor / port-inventory / server-snapshot)

### Changed
- `AwsConfig.psm1` の `Invoke-AwsCli` が `[PSCustomObject]` (`ExitCode` / `Output` / `Success`) を返すように変更。`$global:LASTEXITCODE` をヘルパー内部で捕捉し、呼び出し側で参照する必要をなくした
- `Get-Ec2Instances` の返すオブジェクトに `SecurityGroupIds` (string[]) プロパティを追加（describe-instances の `SecurityGroups[].GroupId` を抽出）
- `AwsManager.psm1` が `ConvertFrom-MinimalYaml` を export するように変更（App.ps1 の YAML スキャンから利用）。併せて単体テスト 2 件を追加
