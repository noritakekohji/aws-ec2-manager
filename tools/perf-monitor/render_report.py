#!/usr/bin/env python3
"""
render_report.py  -  perf_monitor の JSON Lines データから HTML レポートを生成

使い方:
    python3 render_report.py <data.jsonl> <output.html> [--from ISO日時] [--to ISO日時]

    --from / --to は ts フィールド（ISO 8601）に対する範囲フィルタ。
    片方のみの指定も可。統計値・しきい値超過一覧はフィルタ後の全データを対象に計算する
    （間引きの対象はグラフの描画データのみ）。

環境変数（しきい値、未設定 or 0 で無効）:
    PERF_THR_CPU      CPU使用率しきい値 (%)
    PERF_THR_MEM      メモリ使用率しきい値 (%)
    PERF_THR_DISK_R   ディスク読み込みしきい値 (MB/s)
    PERF_THR_DISK_W   ディスク書き込みしきい値 (MB/s)
    PERF_THR_NET_RX   ネット受信しきい値 (Mbps)
    PERF_THR_NET_TX   ネット送信しきい値 (Mbps)
    PERF_THR_LOAD     ロードアベレージ1分しきい値
"""
from __future__ import annotations
import html, json, math, os, sys, statistics
from pathlib import Path
from datetime import datetime

# グラフに描画する最大点数。超えた場合は等間隔で間引く（統計・アラートには影響しない）。
MAX_CHART_POINTS = 2000

# SVG グラフの描画領域(viewBox 座標系。CSS で width:100% にして横方向は追従させる)
SVG_WIDTH  = 880
SVG_MARGIN = {'left': 46, 'right': 12, 'top': 10, 'bottom': 22}

# ─────────────────────────────────────────────────────────────
# しきい値読み込み
# ─────────────────────────────────────────────────────────────
def _thr(key: str, default: float = 0.0) -> float:
    try:
        v = float(os.environ.get(key, default))
        return v if v > 0 else 0.0
    except ValueError:
        return 0.0

THR = {
    'cpu_pct':         _thr('PERF_THR_CPU',    80.0),
    'mem_used_pct':    _thr('PERF_THR_MEM',    85.0),
    'disk_read_mbps':  _thr('PERF_THR_DISK_R', 500.0),
    'disk_write_mbps': _thr('PERF_THR_DISK_W', 500.0),
    'net_rx_mbps':     _thr('PERF_THR_NET_RX', 900.0),
    'net_tx_mbps':     _thr('PERF_THR_NET_TX', 900.0),
    'load_avg_1':      _thr('PERF_THR_LOAD',    4.0),
}

# ─────────────────────────────────────────────────────────────
# データ読み込み・統計
# ─────────────────────────────────────────────────────────────
def load_data(path: str) -> list[dict]:
    records = []
    with open(path, encoding='utf-8-sig') as f:  # utf-8-sig handles optional BOM
        for line in f:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return records

def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    idx = min(int(len(values) * p / 100), len(values) - 1)
    return round(sorted(values)[idx], 2)

def stats(records: list[dict], key: str) -> dict | None:
    vals = [r[key] for r in records if r.get(key) is not None]
    if not vals:
        return None
    return {
        'min':  round(min(vals), 2),
        'max':  round(max(vals), 2),
        'avg':  round(statistics.mean(vals), 2),
        'p95':  pct(vals, 95),
        'count': len(vals),
    }

def parse_range_bound(value: str | None, name: str) -> datetime | None:
    """--from/--to の値を datetime にパースする。失敗時は警告を出して None（フィルタ無効）を返す。"""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        print(f'[WARN] {name} の日時形式を解釈できません（無視します）: {value}', file=sys.stderr)
        return None

def filter_by_range(records: list[dict], from_dt: datetime | None, to_dt: datetime | None) -> list[dict]:
    if from_dt is None and to_dt is None:
        return records
    filtered = []
    for r in records:
        try:
            ts = datetime.fromisoformat(r.get('ts', ''))
        except ValueError:
            continue  # ts をパースできないレコードは範囲指定時のみ除外
        if from_dt is not None and ts < from_dt:
            continue
        if to_dt is not None and ts > to_dt:
            continue
        filtered.append(r)
    return filtered

def decimate(records: list[dict], max_points: int) -> list[dict]:
    """グラフ描画用に等間隔で間引く。統計・アラート計算には使わない。"""
    n = len(records)
    if n <= max_points or max_points <= 0:
        return records
    step = math.ceil(n / max_points)
    return records[::step]

def ts_label(ts_str: str) -> str:
    """ISO timestamp → 表示用短縮文字列"""
    try:
        dt = datetime.fromisoformat(ts_str)
        return dt.strftime('%H:%M:%S')
    except Exception:
        return ts_str[:19].replace('T', ' ')

def duration_str(sec: float) -> str:
    h = int(sec // 3600); m = int((sec % 3600) // 60); s = int(sec % 60)
    if h > 0:
        return f"{h}時間{m}分{s}秒"
    if m > 0:
        return f"{m}分{s}秒"
    return f"{s}秒"

# ─────────────────────────────────────────────────────────────
# SVG チャート生成（JavaScript 不使用。静的マークアップとして描画されるため
# JS 実行環境やライブラリ配布の問題に一切左右されない）
# ─────────────────────────────────────────────────────────────
def make_chart(
    chart_id: str,
    title: str,
    labels: list[str],
    datasets: list[dict],       # {label, data, color, fill}
    y_label: str = '',
    threshold: float = 0.0,
    threshold_label: str = '',
    y_max: float | None = None,
    height: int = 220,
) -> str:
    """静的 SVG 折れ線グラフの HTML を返す"""
    m = SVG_MARGIN
    w, h = SVG_WIDTH, height
    plot_w = w - m['left'] - m['right']
    plot_h = h - m['top'] - m['bottom']

    n = len(labels)
    all_vals = [v for ds in datasets for v in ds['data'] if v is not None]
    if threshold > 0:
        all_vals.append(threshold)
    computed_max = max(all_vals) * 1.1 if all_vals else 1.0
    y_hi = y_max if y_max is not None else computed_max
    y_hi = y_hi if y_hi > 0 else 1.0

    def x_at(i: int) -> float:
        if n <= 1:
            return m['left'] + plot_w / 2
        return m['left'] + i * (plot_w / (n - 1))

    def y_at(v: float) -> float:
        return m['top'] + plot_h - (v / y_hi) * plot_h

    y0 = y_at(0)

    # ── 横方向グリッド線・Y軸ラベル(5分割) ──
    grid_svg = []
    for i in range(5):
        v = y_hi * i / 4
        gy = y_at(v)
        grid_svg.append(f'<line x1="{m["left"]}" y1="{gy:.1f}" x2="{w - m["right"]}" y2="{gy:.1f}" '
                         f'stroke="#f1f5f9" stroke-width="1"/>')
        grid_svg.append(f'<text x="{m["left"] - 6}" y="{gy + 3:.1f}" text-anchor="end" '
                         f'font-size="10" fill="#64748b">{v:.0f}{y_label}</text>')

    # ── X軸ラベル(最大12個。間引いて重なりを防ぐ) ──
    x_label_svg = []
    x_step = max(1, math.ceil(n / 12)) if n > 12 else 1
    for i in range(0, n, x_step):
        x_label_svg.append(f'<text x="{x_at(i):.1f}" y="{h - 6}" text-anchor="middle" '
                            f'font-size="10" fill="#64748b">{html.escape(labels[i])}</text>')

    # ── データセット(折れ線 + 塗りつぶし) ──
    dataset_svg = []
    legend_items = []
    for ds in datasets:
        pts = [(x_at(i), y_at(v)) for i, v in enumerate(ds['data']) if v is not None]
        if pts:
            pts_str = ' '.join(f'{x:.1f},{y:.1f}' for x, y in pts)
            if ds.get('fill'):
                poly_str = pts_str + f' {pts[-1][0]:.1f},{y0:.1f} {pts[0][0]:.1f},{y0:.1f}'
                dataset_svg.append(f'<polygon points="{poly_str}" fill="{ds["color"]}" fill-opacity="0.15" stroke="none"/>')
            dataset_svg.append(f'<polyline points="{pts_str}" fill="none" stroke="{ds["color"]}" stroke-width="1.5"/>')
        legend_items.append((ds['color'], ds['label'], False))

    # ── しきい値ライン ──
    if threshold > 0:
        ty = y_at(threshold)
        thr_label = threshold_label or f'しきい値 ({threshold})'
        dataset_svg.append(f'<line x1="{m["left"]}" y1="{ty:.1f}" x2="{w - m["right"]}" y2="{ty:.1f}" '
                            f'stroke="#ef4444" stroke-width="1.5" stroke-dasharray="6,4"/>')
        legend_items.append(('#ef4444', thr_label, True))

    legend_html = ''.join(
        f'<span class="legend-item{" legend-dash" if dashed else ""}">'
        f'<span class="legend-swatch" style="background:{color}"></span>{label}</span>'
        for color, label, dashed in legend_items
    )

    svg = (
        f'<svg viewBox="0 0 {w} {h}" preserveAspectRatio="none" style="width:100%;height:{h}px" '
        f'role="img" aria-label="{title}">'
        + ''.join(grid_svg) + ''.join(x_label_svg) + ''.join(dataset_svg) +
        '</svg>'
    )

    return f"""
<div class="chart-box">
  <div class="chart-title">{title}</div>
  <div class="chart-legend">{legend_html}</div>
  {svg}
</div>"""

# ─────────────────────────────────────────────────────────────
# アラート検出
# ─────────────────────────────────────────────────────────────
def find_alerts(records: list[dict]) -> list[dict]:
    alerts = []
    for r in records:
        violations = []
        for key, thr in THR.items():
            if thr <= 0:
                continue
            v = r.get(key)
            if v is not None and v >= thr:
                violations.append({'metric': key, 'value': v, 'threshold': thr})
        if violations:
            alerts.append({'ts': r.get('ts', ''), 'violations': violations})
    return alerts

# ─────────────────────────────────────────────────────────────
# HTML レポート生成
# ─────────────────────────────────────────────────────────────
def render(data_path: str, output_path: str, from_str: str | None = None, to_str: str | None = None) -> None:
    all_records = load_data(data_path)
    if not all_records:
        print(f'[ERROR] No data in {data_path}', file=sys.stderr)
        sys.exit(1)

    from_dt = parse_range_bound(from_str, '--from')
    to_dt   = parse_range_bound(to_str, '--to')
    records = filter_by_range(all_records, from_dt, to_dt)
    if not records:
        print(f'[ERROR] 指定範囲内にデータがありません（--from {from_str} --to {to_str}）', file=sys.stderr)
        sys.exit(1)
    range_filtered = (from_dt is not None or to_dt is not None)

    # メタ情報
    hostname = records[0].get('hostname', 'unknown')
    os_name  = records[0].get('os', 'unknown')
    ts_first = records[0].get('ts', '')
    ts_last  = records[-1].get('ts', '')
    n_samples = len(records)
    try:
        dt_first = datetime.fromisoformat(ts_first)
        dt_last  = datetime.fromisoformat(ts_last)
        elapsed  = (dt_last - dt_first).total_seconds()
        start_str = dt_first.strftime('%Y-%m-%d %H:%M:%S')
        end_str   = dt_last.strftime('%Y-%m-%d %H:%M:%S')
        dur_str   = duration_str(elapsed)
    except Exception:
        start_str = ts_first[:19]; end_str = ts_last[:19]; dur_str = '不明'

    is_linux   = (os_name == 'linux')
    gen_time   = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    # ── グラフ描画用データ(間引き。統計・アラートは records=全件のまま使う) ──
    chart_records  = decimate(records, MAX_CHART_POINTS)
    chart_decimated = len(chart_records) < len(records)
    labels = [ts_label(r.get('ts', '')) for r in chart_records]

    # ── 統計値 ────────────────────────────────────────────────
    st = {k: stats(records, k) for k in [
        'cpu_pct', 'mem_used_pct', 'mem_used_gb', 'mem_free_gb', 'mem_total_gb',
        'swap_used_pct', 'swap_used_gb',
        'disk_read_mbps', 'disk_write_mbps',
        'net_rx_mbps', 'net_tx_mbps',
        'load_avg_1', 'load_avg_5', 'load_avg_15',
        'proc_count',
    ]}

    # ── アラート ──────────────────────────────────────────────
    alerts = find_alerts(records)
    alert_count = len(alerts)

    def peak(key: str, unit: str = '') -> str:
        s = st.get(key)
        if not s:
            return 'N/A'
        return f"{s['max']}{unit} (avg {s['avg']}{unit})"

    # ── サマリーカード ────────────────────────────────────────
    def card(title: str, value: str, color: str) -> str:
        return f"""<div class="card" style="border-top:3px solid {color}">
    <div class="card-title">{title}</div>
    <div class="card-value">{value}</div>
  </div>"""

    cpu_peak = peak('cpu_pct', '%')
    mem_peak = peak('mem_used_pct', '%')
    dr_peak  = peak('disk_read_mbps', 'MB/s')
    dw_peak  = peak('disk_write_mbps', 'MB/s')
    rx_peak  = peak('net_rx_mbps', 'Mbps')
    tx_peak  = peak('net_tx_mbps', 'Mbps')
    ld_peak  = peak('load_avg_1', '') if is_linux else 'N/A (Windows)'
    alert_color = '#ef4444' if alert_count > 0 else '#16a34a'

    cards_html = ''.join([
        card('CPU ピーク',       cpu_peak, '#3b82f6'),
        card('メモリ ピーク',     mem_peak, '#8b5cf6'),
        card('Disk Read ピーク', dr_peak,  '#f59e0b'),
        card('Disk Write ピーク',dw_peak,  '#f97316'),
        card('Net Rx ピーク',    rx_peak,  '#06b6d4'),
        card('Net Tx ピーク',    tx_peak,  '#0891b2'),
        card('Load Avg ピーク',  ld_peak,  '#22c55e'),
        card('しきい値超過',      f'{alert_count} 回', alert_color),
    ])

    # ── データ抽出(グラフ用。間引き後の chart_records を使う) ──────
    def vals(key: str) -> list:
        return [r.get(key) for r in chart_records]

    # ── グラフ生成 ────────────────────────────────────────────
    charts_html = ''

    # 1. CPU
    charts_html += make_chart(
        'chartCpu', 'CPU 使用率', labels,
        [{'label': 'CPU (%)', 'data': vals('cpu_pct'), 'color': '#3b82f6', 'fill': True}],
        '%', THR['cpu_pct'], f"しきい値 ({THR['cpu_pct']}%)", y_max=100,
    )

    # 2. メモリ
    charts_html += make_chart(
        'chartMem', 'メモリ使用率', labels,
        [
            {'label': 'Memory (%)', 'data': vals('mem_used_pct'), 'color': '#8b5cf6', 'fill': True},
            {'label': 'Swap (%)',   'data': vals('swap_used_pct'), 'color': '#c084fc', 'fill': False},
        ],
        '%', THR['mem_used_pct'], f"しきい値 ({THR['mem_used_pct']}%)", y_max=100,
    )

    # 3. メモリ容量
    mem_total = st.get('mem_total_gb')
    y_max_mem = (mem_total['max'] if mem_total else None)
    charts_html += make_chart(
        'chartMemGB', 'メモリ容量 (GB)', labels,
        [
            {'label': '使用 (GB)',  'data': vals('mem_used_gb'), 'color': '#7c3aed', 'fill': True},
            {'label': '空き (GB)',  'data': vals('mem_free_gb'), 'color': '#a78bfa', 'fill': False},
            {'label': 'スワップ (GB)', 'data': vals('swap_used_gb'), 'color': '#c084fc', 'fill': False},
        ],
        'GB', 0, '', y_max=y_max_mem,
    )

    # 4. ディスク I/O
    charts_html += make_chart(
        'chartDisk', 'ディスク I/O', labels,
        [
            {'label': 'Read (MB/s)',  'data': vals('disk_read_mbps'),  'color': '#f59e0b', 'fill': False},
            {'label': 'Write (MB/s)', 'data': vals('disk_write_mbps'), 'color': '#f97316', 'fill': False},
        ],
        'MB/s', max(THR['disk_read_mbps'], THR['disk_write_mbps']), 'しきい値',
    )

    # 5. ネットワーク
    charts_html += make_chart(
        'chartNet', 'ネットワークスループット', labels,
        [
            {'label': 'Rx (Mbps)', 'data': vals('net_rx_mbps'), 'color': '#06b6d4', 'fill': False},
            {'label': 'Tx (Mbps)', 'data': vals('net_tx_mbps'), 'color': '#0891b2', 'fill': False},
        ],
        'Mbps', max(THR['net_rx_mbps'], THR['net_tx_mbps']), 'しきい値',
    )

    # 6. ロードアベレージ（Linux のみ）
    if is_linux:
        charts_html += make_chart(
            'chartLoad', 'ロードアベレージ', labels,
            [
                {'label': 'Load 1min',  'data': vals('load_avg_1'),  'color': '#22c55e', 'fill': False},
                {'label': 'Load 5min',  'data': vals('load_avg_5'),  'color': '#4ade80', 'fill': False},
                {'label': 'Load 15min', 'data': vals('load_avg_15'), 'color': '#86efac', 'fill': False},
            ],
            '', THR['load_avg_1'], f"しきい値 ({THR['load_avg_1']})",
        )

    # 7. プロセス数
    if any(r.get('proc_count') is not None for r in records):
        charts_html += make_chart(
            'chartProc', 'プロセス数', labels,
            [{'label': 'Processes', 'data': vals('proc_count'), 'color': '#64748b', 'fill': False}],
            '',
        )

    # ── 統計サマリーテーブル ──────────────────────────────────
    def stat_row(label: str, key: str, unit: str) -> str:
        s = st.get(key)
        if not s:
            return f'<tr><td>{label}</td><td colspan="4" class="na">N/A</td></tr>'
        thr_v  = THR.get(key, 0)
        max_cls = ' class="alert"' if thr_v > 0 and s['max'] >= thr_v else ''
        avg_cls = ' class="warn"'  if thr_v > 0 and s['avg'] >= thr_v * 0.8 else ''
        return (f'<tr><td>{label}</td>'
                f'<td>{s["min"]}{unit}</td>'
                f'<td{avg_cls}>{s["avg"]}{unit}</td>'
                f'<td{max_cls}>{s["max"]}{unit}</td>'
                f'<td>{s["p95"]}{unit}</td></tr>')

    stat_rows = ''.join([
        stat_row('CPU 使用率',           'cpu_pct',        '%'),
        stat_row('メモリ使用率',          'mem_used_pct',   '%'),
        stat_row('メモリ使用量',          'mem_used_gb',    'GB'),
        stat_row('スワップ使用率',        'swap_used_pct',  '%'),
        stat_row('ディスク Read',         'disk_read_mbps', 'MB/s'),
        stat_row('ディスク Write',        'disk_write_mbps','MB/s'),
        stat_row('ネット受信',            'net_rx_mbps',    'Mbps'),
        stat_row('ネット送信',            'net_tx_mbps',    'Mbps'),
    ] + ([
        stat_row('ロードアベレージ 1min', 'load_avg_1',     ''),
        stat_row('ロードアベレージ 5min', 'load_avg_5',     ''),
    ] if is_linux else []) + [
        stat_row('プロセス数',            'proc_count',     ''),
    ])

    # ── しきい値超過テーブル ──────────────────────────────────
    alert_rows_html = ''
    if alerts:
        rows = []
        for a in alerts[:200]:   # 最大200行表示
            ts_disp = ts_label(a['ts'])
            for v in a['violations']:
                rows.append(
                    f'<tr><td>{ts_disp}</td>'
                    f'<td>{v["metric"]}</td>'
                    f'<td class="alert">{v["value"]}</td>'
                    f'<td>{v["threshold"]}</td></tr>'
                )
        alert_rows_html = '\n'.join(rows)
        if len(alerts) > 200:
            alert_rows_html += f'<tr><td colspan="4">... 他 {len(alerts)-200} 件</td></tr>'

    # ── しきい値設定テーブル ──────────────────────────────────
    thr_rows = ''
    thr_map = [
        ('CPU 使用率', 'cpu_pct', '%'),
        ('メモリ使用率', 'mem_used_pct', '%'),
        ('ディスク Read', 'disk_read_mbps', 'MB/s'),
        ('ディスク Write', 'disk_write_mbps', 'MB/s'),
        ('ネット受信', 'net_rx_mbps', 'Mbps'),
        ('ネット送信', 'net_tx_mbps', 'Mbps'),
        ('ロードアベレージ 1min', 'load_avg_1', ''),
    ]
    for label, key, unit in thr_map:
        tv = THR.get(key, 0)
        if tv > 0:
            thr_rows += f'<tr><td>{label}</td><td>{tv}{unit}</td></tr>'

    # ── HTML 組み立て ─────────────────────────────────────────
    html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Performance Monitor Report</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}}
.header{{background:#1e293b;color:#fff;padding:20px 24px}}
.header h1{{font-size:22px;font-weight:700}}
.header .sub{{font-size:12px;color:#94a3b8;margin-top:4px}}
.meta-bar{{display:flex;gap:12px;padding:14px 24px;flex-wrap:wrap;background:#fff;border-bottom:1px solid #e2e8f0}}
.meta-item{{font-size:12px;color:#475569}}
.meta-item span{{font-weight:600;color:#1e293b;margin-left:4px}}
.section{{padding:16px 24px}}
.section-title{{font-size:14px;font-weight:700;color:#1e293b;margin-bottom:12px;
    padding-left:8px;border-left:3px solid #3b82f6}}
.cards{{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}}
.card{{background:#fff;border-radius:8px;padding:14px 18px;min-width:160px;
    box-shadow:0 1px 3px rgba(0,0,0,.1);flex:1}}
.card-title{{font-size:11px;color:#64748b;margin-bottom:6px}}
.card-value{{font-size:14px;font-weight:700;color:#1e293b}}
.charts-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(480px,1fr));gap:16px}}
.chart-box{{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
.chart-title{{font-size:13px;font-weight:600;color:#1e293b;margin-bottom:6px}}
.chart-legend{{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:8px}}
.legend-item{{display:inline-flex;align-items:center;font-size:11px;color:#475569}}
.legend-swatch{{display:inline-block;width:12px;height:12px;border-radius:2px;margin-right:5px}}
.legend-dash .legend-swatch{{border-radius:0;height:2px;margin-top:5px;align-self:flex-start}}
table{{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;
    overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
th{{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;
    color:#475569;font-size:12px;border-bottom:2px solid #e2e8f0}}
td{{padding:7px 12px;border-bottom:1px solid #f1f5f9;font-size:12px}}
tr:last-child td{{border-bottom:none}}
td.alert{{color:#dc2626;font-weight:700}}
td.warn{{color:#d97706;font-weight:600}}
td.na{{color:#94a3b8}}
.alert-badge{{display:inline-block;background:#fee2e2;color:#b91c1c;
    padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}}
.ok-badge{{display:inline-block;background:#dcfce7;color:#15803d;
    padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}}
.range-badge{{display:inline-block;background:#dbeafe;color:#1d4ed8;
    padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}}
.chart-note{{font-size:11px;color:#64748b;margin-bottom:10px}}
.footer{{text-align:center;padding:16px;font-size:11px;color:#94a3b8}}
</style>
</head>
<body>

<div class="header">
  <h1>&#128200; Performance Monitor Report</h1>
  <div class="sub">Generated: {gen_time}</div>
</div>

<div class="meta-bar">
  <div class="meta-item">ホスト<span>{hostname}</span></div>
  <div class="meta-item">OS<span>{os_name}</span></div>
  <div class="meta-item">開始<span>{start_str}</span></div>
  <div class="meta-item">終了<span>{end_str}</span></div>
  <div class="meta-item">計測時間<span>{dur_str}</span></div>
  <div class="meta-item">サンプル数<span>{n_samples} 件</span></div>
  <div class="meta-item">しきい値超過
    <span>{"<span class='alert-badge'>" + str(alert_count) + " 回</span>" if alert_count > 0 else "<span class='ok-badge'>なし</span>"}</span>
  </div>
  {'<div class="meta-item">表示範囲<span class="range-badge">' + (from_str or '(先頭)') + ' 〜 ' + (to_str or '(末尾)') + '</span></div>' if range_filtered else ''}
</div>

<div class="section">
  <div class="section-title">サマリー</div>
  <div class="cards">{cards_html}</div>
</div>

<div class="section">
  <div class="section-title">リソース推移グラフ</div>
  {'<div class="chart-note">サンプル数が多いため、グラフは間引いて表示しています（全 ' + str(n_samples) + ' 件中 ' + str(len(chart_records)) + ' 点）。統計値・しきい値超過一覧は全データを対象に計算しています。</div>' if chart_decimated else ''}
  <div class="charts-grid">
    {charts_html}
  </div>
</div>

<div class="section">
  <div class="section-title">統計サマリー</div>
  <table>
    <thead><tr><th>メトリクス</th><th>最小</th><th>平均</th><th>最大</th><th>95パーセンタイル</th></tr></thead>
    <tbody>{stat_rows}</tbody>
  </table>
</div>

{"" if not alerts else f'''
<div class="section">
  <div class="section-title">しきい値超過一覧（{alert_count} 件）</div>
  <table>
    <thead><tr><th>時刻</th><th>メトリクス</th><th>値</th><th>しきい値</th></tr></thead>
    <tbody>{alert_rows_html}</tbody>
  </table>
</div>
'''}

{"" if not thr_rows else f'''
<div class="section">
  <div class="section-title">しきい値設定</div>
  <table style="max-width:400px">
    <thead><tr><th>メトリクス</th><th>しきい値</th></tr></thead>
    <tbody>{thr_rows}</tbody>
  </table>
</div>
'''}

<div class="footer">Performance Monitor &bull; perf_monitor.sh / PerfMonitor.ps1 &bull; {gen_time}</div>
</body>
</html>"""

    Path(output_path).write_text(html, encoding='utf-8')
    print(f'Report: {output_path}  ({n_samples} samples, {alert_count} alerts)')


# ─────────────────────────────────────────────────────────────
if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} <data.jsonl> <output.html> [--from ISO日時] [--to ISO日時]', file=sys.stderr)
        sys.exit(1)
    data_path, output_path = sys.argv[1], sys.argv[2]
    from_str = to_str = None
    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == '--from' and i + 1 < len(sys.argv):
            from_str = sys.argv[i + 1]; i += 2
        elif sys.argv[i] == '--to' and i + 1 < len(sys.argv):
            to_str = sys.argv[i + 1]; i += 2
        else:
            i += 1
    render(data_path, output_path, from_str, to_str)
