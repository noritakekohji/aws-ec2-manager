# ツールランチャー実装計画

**日付**: 2026-06-29
**対象仕様**: `docs/superpowers/specs/2026-06-29-local-tools-launcher.md`

## 方針

- 既存 EC2 管理 GUI には組み込まず、独立した Windows WPF GUI を追加する。
- Linux は同じ階層に対話式 Bash ランチャーを追加する。
- Windows GUI の表示名は「ツールランチャー」とする。
- `ToolsRoot` と `OutputRoot` は全ツール共通設定として画面上部に置き、設定ファイルで保存する。
- Windows GUI では利用者に生の引数文字列を編集させず、ツールごとの必要パラメーター欄からコマンドを組み立てる。
- Windows/Linux の表示名と入口は `tools/tool-catalog.yaml` で共通化する。
- ツールパスは、ランチャー設定の `ToolsRoot` からの相対パスで定義する。
- Windows GUI の入力欄とコマンド引数の対応も `tools/tool-catalog.yaml` の `parameters` で定義する。

## 追加ファイル

- `LocalToolsLauncher.ps1`
- `LocalToolsLauncher.xaml`
- `launch-tools.bat`
- `local-tools-launcher.sh`
- `tools/tool-catalog.yaml`

## 実装ステップ

1. 共通カタログを YAML で追加する。
2. Windows GUI を追加し、設定読み書き、ツール選択、パラメーター入力、コマンドプレビュー、実行、ログ保存を実装する。
3. Linux CLI を追加し、設定読み書き、番号メニュー、引数編集、実行、ログ保存を実装する。
4. Windows は XAML 読み込みと PowerShell 構文を検証する。
5. Linux は `bash -n` で構文検証する。
6. 改行と BOM 規約を確認する。

## 初期版の制約

- ツールごとの全オプション GUI 化は行わない。
- RDP/SSH の接続開始は行わない。
- SSM 経由の配布・遠隔実行は行わない。
- `collect-snapshot-report` の Linux 入口は未定義のため、Windows 側のみ実行可能とする。
