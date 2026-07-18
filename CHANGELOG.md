# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
