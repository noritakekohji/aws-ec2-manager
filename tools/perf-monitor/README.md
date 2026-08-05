# Performance Monitor

負荷テスト中のサーバーリソース（CPU / メモリ / ディスク I/O / ディスク使用率 / ネットワーク / ロード）を
**定期収集** して JSON Lines に保存し、終了後に **HTML レポート** を生成する運用補助ツールです。

ディスク使用率は検出された全ドライブ（Windows は固定ディスクのみ、Linux は仮想 FS を除く
全マウントポイント）を自動収集し、レポートではドライブごとの系列としてグラフ化されます。

**このフォルダ一式をコピーすれば動きます。**

```
tools/perf-monitor/
├── PerfMonitor.ps1        # Windows 本体（コレクタ + レポート生成）
├── perf_monitor.bat       # Windows 起動用バッチ
├── perf_monitor.sh        # Linux 本体（コレクタ + レポート生成）
├── perf_monitor.conf      # 既定設定（しきい値・収集間隔など）
└── render_report.py       # python3 製の HTML レポート生成器（共通）
```

---

## 前提

| 実行環境 | 必要なもの |
|---|---|
| Windows | PowerShell 5.1+ |
| Linux   | Bash 4+, `python3`, `ping` |

> **python3 は Windows では任意**: PerfMonitor.ps1 は python3 が見つからない場合、
> PowerShell ネイティブの簡易レンダラーにフォールバックします。
> セキュリティで python3 が制限されている環境でも `report` が動作します。
>
> **グラフは外部ライブラリ・インターネット接続不要**: 両レンダラーとも折れ線グラフを
> JavaScript ライブラリ(Chart.js 等)に頼らず、純粋な SVG として静的に描画します。
> ブラウザの JS 実行がポリシーで制限されている環境や、ファイル配布の都合でライブラリ
> 本体が欠落した場合でも、SVG は HTML の一部としてそのまま描画されるため影響を受けません。

---

## コマンド体系

| コマンド | 説明 |
|---|---|
| `start`  | 計測開始（独立プロセスとして collector を起動） |
| `stop`   | 計測停止（session を指定しない場合は最新を自動検出） |
| `report` | 蓄積した data.jsonl から HTML レポートを生成 |
| `status` | 現在の収集状態と最新サンプルを表示 |
| `list`   | セッション一覧を表示 |

### Windows

```cmd
:: 起動（既定: 5秒間隔・停止まで継続）
perf_monitor.bat start

:: 5秒間隔で30分間
perf_monitor.bat start -Interval 5 -Duration 1800 -OutputDir C:\results

:: 状態確認 / 停止 / レポート
perf_monitor.bat status
perf_monitor.bat stop
perf_monitor.bat report .\perf_20260518-100000
:: 特定の時間帯だけレポート化（片方のみの指定も可）
perf_monitor.bat report .\perf_20260518-100000 -From "2026-05-18T10:15:00" -To "2026-05-18T10:30:00"
perf_monitor.bat list
```

### Linux

```bash
# 起動
./perf_monitor.sh start

# 5秒間隔で30分間
./perf_monitor.sh start -i 5 -d 1800 -o /var/log/perf

# 停止 / レポート
./perf_monitor.sh stop
./perf_monitor.sh report ./perf_20260518-100000
# 特定の時間帯だけレポート化（片方のみの指定も可）
./perf_monitor.sh report ./perf_20260518-100000 -f "2026-05-18T10:15:00" -t "2026-05-18T10:30:00"
./perf_monitor.sh status
./perf_monitor.sh list
```

---

## 設定ファイル (`perf_monitor.conf`)

| キー | 既定値 | 説明 |
|---|---|---|
| `Interval` | 5 | 収集間隔（秒） |
| `Duration` | 0 | 計測時間（秒）。0 で stop まで継続 |
| `OutputDir` | `.` | セッションディレクトリの親 |
| `OutputPrefix` | `perf` | セッションディレクトリ名のプレフィックス |
| `Metrics` | `all` | 収集メトリクス（カンマ区切り: `cpu,mem,disk,net,load` または `all`。`disk` にディスク I/O とディスク使用率の両方が含まれる） |
| `ThresholdCpuPct` | 80.0 | CPU 使用率しきい値 (%) |
| `ThresholdMemPct` | 85.0 | メモリ使用率しきい値 (%) |
| `ThresholdDiskReadMBps` | 500.0 | ディスク Read しきい値 (MB/s) |
| `ThresholdDiskWriteMBps` | 500.0 | ディスク Write しきい値 (MB/s) |
| `ThresholdDiskUsedPct` | 90.0 | ディスク使用率しきい値 (%、全ドライブ/マウント共通) |
| `ThresholdNetRxMbps` | 900.0 | NIC Rx しきい値 (Mbps) |
| `ThresholdNetTxMbps` | 900.0 | NIC Tx しきい値 (Mbps) |
| `ThresholdLoadAvg1` | 4.0 | Load avg(1) しきい値（Linux のみ） |

---

## 大量サンプル時のグラフ表示について

長時間・短間隔で収集すると `data.jsonl` のサンプル数が数千件を超えることがあります。

- **統計値（最小/平均/最大/95パーセンタイル）としきい値超過一覧は、常に全サンプルを対象に計算されます。**
  間引きの影響を受けません。
- **グラフ描画のみ**、サンプル数が 2000 件を超えると自動的に等間隔で間引かれます
  （例: 5000 件なら 3 件おきに 1 件抽出）。間引きが発生した場合、レポート上部に
  「グラフは間引いて表示しています（全 N 件中 M 点）」という注記が出ます。
- 特定の時間帯だけを詳しく見たい場合は、`report` コマンドの `-From`/`-To`（Linux は `-f`/`-t`）
  で範囲を絞り込んでからレポートを生成してください。絞り込み後の件数が 2000 件以下であれば
  全点がそのままグラフに描画されます。

---

## セッションディレクトリの中身

```
perf_YYYYMMDD-HHMMSS/
├── data.jsonl        # 1 サンプル = 1 行の JSON Lines
├── session.conf      # 計測時の設定スナップショット
├── status.txt        # 最新サンプルの 1 行サマリ
├── collector.pid     # コレクタプロセスの PID
├── collector.log     # コレクタの stdout ログ
└── report.html       # report コマンド実行後に生成
```

---

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 引数不正 |
| 4 | セッション/データが見つからない |
| 5 | レポート生成失敗 |
| 10 | 前提コマンド不足 |

---

## Windows のセキュリティ制限環境について

エンタープライズ Windows で GPO / AppLocker が厳格な場合、以下のコマンドが利用できないことがあります。
PerfMonitor.ps1 はこれらをすべて代替実装で回避しています。

| 制限されることがあるコマンド | 代替手段 |
|---|---|
| `Get-Counter`     | `Win32_PerfFormattedData_*` CIM クエリ |
| `Get-Process`     | `Win32_Process` CIM クエリ |
| `Stop-Process`    | `taskkill.exe` |
| `python3`         | PowerShell ネイティブ HTML レンダラーへフォールバック |

`start` が動けば `status` / `stop` / `report` も基本的に動くように作られています。
