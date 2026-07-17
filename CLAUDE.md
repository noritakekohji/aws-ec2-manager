# aws-ec2-manager — Claude Code プロジェクトメモリ

AWS EC2 を WPF GUI で管理するツール。PowerShell 5.1 + XAML + AWS CLI（SSO）+ SSM Run Command。
Windows 11 / AVD 上で動作する前提。

v2.0 構成: App.ps1 は薄いエントリで、機能は `src/*.ps1` に分割(dot-source、全ファイルが
同一スクリプトスコープを共有)。AWS 呼び出しは `src/AsyncRunner.ps1` 経由の
バックグラウンド Runspace で実行され、完了・進捗は `Dispatcher.BeginInvoke` で UI へ push
される(UI 側にタイマー・ポーリングは置かない)。

**非同期コールバックの注意**: `Start-AsyncTask` の OnSuccess/OnError scriptblock は
定義元関数のローカル変数を参照できない(実行時には定義元スコープが消滅)。
必要な値は `-Context` で渡し、`param($result, $ctx)` で受け取ること。
`GetNewClosure()` は `$script:` 参照を壊すため使わない。

## 重要方針

- **PS 5.1 互換必須**。`??` / `?:` / `?.` / `utf8NoBOM` は禁止
- **.ps1 / .psm1 は UTF-8 BOM 付き** で保存（CP932 環境の文字化け回避）
- **.sh は UTF-8 BOM なし + LF**、**.bat は CRLF**
- AWS 認証は **SSO プロファイル** のみ。アクセスキー直書きは禁止
- SSH は使わず **SSM Run Command** でリモート実行
- 課金を伴う AWS 操作（インスタンスタイプ変更・新規作成等）はユーザー明示承認後

## tools/ の出自

`tools/` 配下の 8 ツール（aws-instance-audit / cert-check / collect-snapshot /
log-collector / network-check / perf-monitor / port-inventory / server-snapshot）は
`ops-scripts-template` から移植したもの。各サーバに配備されている前提で SSM 経由で呼ぶ。
ops-scripts-template の規約（5-phase 構造・lib/config 解決等）はそのまま踏襲する。

## テスト

```powershell
Invoke-Pester -Path tests/
```

## ドキュメント

- 設計: `docs/superpowers/specs/`
- プラン: `docs/superpowers/plans/`

## 関連プロジェクト

- 移植元: `C:\Users\kohji\data\ai-work\projects\ops-scripts-template`
- GitHub: https://github.com/noritakekohji/aws-ec2-manager
