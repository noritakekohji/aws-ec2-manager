#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$NoGui
)

Set-StrictMode -Version 2.0

$script:KnownMetricInfo = @{
    cpu_pct          = @{ Label = 'CPU 使用率'; Unit = '%' }
    mem_used_pct     = @{ Label = 'メモリ使用率'; Unit = '%' }
    mem_used_gb      = @{ Label = 'メモリ使用量'; Unit = 'GB' }
    mem_free_gb      = @{ Label = 'メモリ空き容量'; Unit = 'GB' }
    mem_total_gb     = @{ Label = 'メモリ総容量'; Unit = 'GB' }
    swap_used_pct    = @{ Label = 'Swap 使用率'; Unit = '%' }
    swap_used_gb     = @{ Label = 'Swap 使用量'; Unit = 'GB' }
    disk_read_mbps   = @{ Label = 'ディスク Read'; Unit = 'MB/s' }
    disk_write_mbps  = @{ Label = 'ディスク Write'; Unit = 'MB/s' }
    net_rx_mbps      = @{ Label = 'ネットワーク受信'; Unit = 'Mbps' }
    net_tx_mbps      = @{ Label = 'ネットワーク送信'; Unit = 'Mbps' }
    load_avg_1       = @{ Label = 'Load Average 1分'; Unit = '' }
    load_avg_5       = @{ Label = 'Load Average 5分'; Unit = '' }
    load_avg_15      = @{ Label = 'Load Average 15分'; Unit = '' }
    proc_count       = @{ Label = 'プロセス数'; Unit = 'count' }
}

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-PerfMetricInfo {
    param([Parameter(Mandatory=$true)][string]$MetricKey)

    if ($MetricKey -match '^disk_usage_pct\[(.+)\]$') {
        return [PSCustomObject]@{
            Key   = $MetricKey
            Label = "ディスク使用率 ($($Matches[1]))"
            Unit  = '%'
        }
    }

    if ($script:KnownMetricInfo.ContainsKey($MetricKey)) {
        $info = $script:KnownMetricInfo[$MetricKey]
        return [PSCustomObject]@{
            Key   = $MetricKey
            Label = [string]$info.Label
            Unit  = [string]$info.Unit
        }
    }

    return [PSCustomObject]@{
        Key   = $MetricKey
        Label = $MetricKey
        Unit  = ''
    }
}

function Test-IsNumericValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [int64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return $true
    }

    $tmp = 0.0
    return [double]::TryParse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$tmp
    )
}

function ConvertTo-InvariantDouble {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    return [double]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-PerfTimestamp {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dt)) {
        return $dt
    }
    if ([datetime]::TryParse($text, [ref]$dt)) {
        return $dt
    }
    return $null
}

function Get-PerfServerName {
    param(
        [AllowNull()][object]$Record,
        [Parameter(Mandatory=$true)][string]$Path
    )

    if ($null -ne $Record) {
        foreach ($name in @('hostname', 'host', 'server', 'instance_name', 'instance_id')) {
            $prop = $Record.PSObject.Properties[$name]
            if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                return [string]$prop.Value
            }
        }
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        return Split-Path -Path $parent -Leaf
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Add-NormalizedMetricRow {
    param(
        [Parameter(Mandatory=$true)][System.Collections.IList]$Rows,
        [Parameter(Mandatory=$true)][hashtable]$MetricMap,
        [Parameter(Mandatory=$true)][datetime]$Timestamp,
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)][string]$MetricKey,
        [AllowNull()][object]$Value,
        [Parameter(Mandatory=$true)][string]$SourceFile
    )

    if (-not (Test-IsNumericValue $Value)) { return }

    $info = Get-PerfMetricInfo -MetricKey $MetricKey
    $MetricMap[$MetricKey] = $info
    $Rows.Add([PSCustomObject]@{
        timestamp   = $Timestamp.ToString('o')
        server      = $Server
        metric      = $MetricKey
        metricLabel = $info.Label
        value       = (ConvertTo-InvariantDouble $Value)
        unit        = $info.Unit
        source_file = $SourceFile
    }) | Out-Null
}

function Read-PerfMonitorDataFile {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    $resultRows = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $metricMap = @{}
    $firstRecord = $null

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "入力ファイルが見つかりません: $Path"
    }

    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $record = $line | ConvertFrom-Json
        } catch {
            $warnings.Add("$Path の $lineNo 行目は JSON として読めないため除外しました。") | Out-Null
            continue
        }

        if ($null -eq $firstRecord) { $firstRecord = $record }
        $timestamp = ConvertTo-PerfTimestamp $record.ts
        if ($null -eq $timestamp) {
            $warnings.Add("$Path の $lineNo 行目は ts を日時として読めないため除外しました。") | Out-Null
            continue
        }

        $server = Get-PerfServerName -Record $record -Path $Path
        foreach ($prop in $record.PSObject.Properties) {
            if (@('ts', 'hostname', 'host', 'server', 'instance_name', 'instance_id', 'os').Contains($prop.Name)) {
                continue
            }
            if ($prop.Name -eq 'disk_usage_pct') {
                if ($null -ne $prop.Value) {
                    foreach ($drive in $prop.Value.PSObject.Properties) {
                        Add-NormalizedMetricRow -Rows $resultRows -MetricMap $metricMap -Timestamp $timestamp -Server $server -MetricKey "disk_usage_pct[$($drive.Name)]" -Value $drive.Value -SourceFile $Path
                    }
                }
                continue
            }
            Add-NormalizedMetricRow -Rows $resultRows -MetricMap $metricMap -Timestamp $timestamp -Server $server -MetricKey $prop.Name -Value $prop.Value -SourceFile $Path
        }
    }

    $serverName = Get-PerfServerName -Record $firstRecord -Path $Path
    return [PSCustomObject]@{
        Path     = $Path
        Server   = $serverName
        Rows     = @($resultRows)
        Metrics  = @($metricMap.Values | Sort-Object Label, Key)
        Warnings = @($warnings)
    }
}

function Read-PerfMonitorDataFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string[]]$Path)

    $allRows = New-Object System.Collections.ArrayList
    $allWarnings = New-Object System.Collections.ArrayList
    $metricMap = @{}
    $sources = New-Object System.Collections.ArrayList

    foreach ($p in $Path) {
        $parsed = Read-PerfMonitorDataFile -Path $p
        $sources.Add([PSCustomObject]@{ Path = $parsed.Path; Server = $parsed.Server; Count = @($parsed.Rows).Count }) | Out-Null
        foreach ($row in @($parsed.Rows)) {
            $allRows.Add($row) | Out-Null
            if (-not $metricMap.ContainsKey($row.metric)) {
                $metricMap[$row.metric] = Get-PerfMetricInfo -MetricKey $row.metric
            }
        }
        foreach ($warning in @($parsed.Warnings)) {
            $allWarnings.Add($warning) | Out-Null
        }
    }

    return [PSCustomObject]@{
        Rows     = @($allRows)
        Metrics  = @($metricMap.Values | Sort-Object Label, Key)
        Sources  = @($sources)
        Warnings = @($allWarnings)
    }
}

function Export-PerfMonitorSelectionCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [Parameter(Mandatory=$true)][string[]]$MetricKey,
        [Parameter(Mandatory=$true)][string]$OutputPath
    )

    $selected = @($Rows | Where-Object { $MetricKey -contains $_.metric } | Sort-Object timestamp, metric, server)
    $selected |
        Select-Object timestamp, server, metricLabel, metric, value, unit, source_file |
        Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    return $selected
}

function New-PerfComparisonHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [Parameter(Mandatory=$true)][string[]]$MetricKey,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [string[]]$Warnings = @()
    )

    $payloadMetrics = New-Object System.Collections.ArrayList
    foreach ($metric in $MetricKey) {
        $info = Get-PerfMetricInfo -MetricKey $metric
        $series = New-Object System.Collections.ArrayList
        $metricRows = @($Rows | Where-Object { $_.metric -eq $metric } | Sort-Object timestamp, server)
        foreach ($serverName in @($metricRows | Select-Object -ExpandProperty server -Unique | Sort-Object)) {
            $points = New-Object System.Collections.ArrayList
            foreach ($row in @($metricRows | Where-Object { $_.server -eq $serverName } | Sort-Object timestamp)) {
                $points.Add(@($row.timestamp, [double]$row.value)) | Out-Null
            }
            $series.Add([PSCustomObject]@{ name = $serverName; points = @($points) }) | Out-Null
        }
        $payloadMetrics.Add([PSCustomObject]@{
            key    = $metric
            label  = $info.Label
            unit   = $info.Unit
            series = @($series)
        }) | Out-Null
    }

    $payload = [PSCustomObject]@{
        generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        metrics     = @($payloadMetrics)
        warnings    = @($Warnings)
    }
    $json = $payload | ConvertTo-Json -Depth 12
    $json = $json -replace '</', '<\/'

    $title = 'Performance Monitor Comparison'
    $htmlTemplate = @'
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root { --bg:#ffffff; --surface:#f6f8fa; --border:#d0d7de; --text:#1f2328; --muted:#57606a; --accent:#0969da; --danger:#cf222e; }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 "Segoe UI","Yu Gothic UI",sans-serif; }
header { padding:20px 24px 12px; border-bottom:1px solid var(--border); background:var(--surface); }
h1 { margin:0; font-size:20px; font-weight:600; }
.meta { margin-top:6px; color:var(--muted); font-size:12px; }
main { padding:16px 24px 32px; }
.warning { border:1px solid #f0c36d; background:#fff8c5; color:#5f4400; padding:8px 10px; margin:0 0 12px; border-radius:6px; }
.chart { border:1px solid var(--border); border-radius:6px; margin:0 0 16px; overflow:hidden; background:#fff; }
.chart-head { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:10px 12px; background:var(--surface); border-bottom:1px solid var(--border); }
.chart-title { font-weight:600; }
.chart-tools { display:flex; gap:8px; align-items:center; flex-wrap:wrap; color:var(--muted); font-size:12px; }
button { border:1px solid var(--border); background:#fff; color:var(--text); border-radius:6px; padding:4px 8px; cursor:pointer; }
button:hover { border-color:var(--accent); color:var(--accent); }
.legend { display:flex; flex-wrap:wrap; gap:10px 16px; padding:8px 12px; border-bottom:1px solid var(--border); }
.legend label { display:flex; align-items:center; gap:6px; white-space:nowrap; }
.swatch { width:12px; height:3px; display:inline-block; border-radius:2px; }
canvas { display:block; width:100%; height:360px; }
.empty { padding:32px; color:var(--muted); text-align:center; border:1px dashed var(--border); border-radius:6px; }
</style>
</head>
<body>
<header>
  <h1>Performance Monitor Comparison</h1>
  <div class="meta">生成日時: <span id="generatedAt"></span> / マウスホイールで横軸ズーム、ドラッグで横移動、Resetで全体表示</div>
</header>
<main>
  <div id="warnings"></div>
  <div id="charts"></div>
</main>
<script>
const payload = __PAYLOAD_JSON__;
const palette = ['#0969da','#1a7f37','#cf222e','#9a6700','#8250df','#bf3989','#0a7ea4','#6e7781','#d1242f','#2da44e'];
document.getElementById('generatedAt').textContent = payload.generatedAt || '';
const warnRoot = document.getElementById('warnings');
(payload.warnings || []).forEach(w => {
  const div = document.createElement('div');
  div.className = 'warning';
  div.textContent = w;
  warnRoot.appendChild(div);
});
const root = document.getElementById('charts');
if (!payload.metrics || payload.metrics.length === 0) {
  const div = document.createElement('div');
  div.className = 'empty';
  div.textContent = '表示対象のデータがありません。';
  root.appendChild(div);
}
function parsePoint(p) { return { t: new Date(p[0]).getTime(), v: Number(p[1]) }; }
function fmtTime(t) {
  const d = new Date(t);
  const pad = n => String(n).padStart(2, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
function drawChart(state) {
  const canvas = state.canvas;
  const ctx = canvas.getContext('2d');
  const rect = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.max(320, Math.floor(rect.width * dpr));
  canvas.height = Math.floor(360 * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const w = canvas.width / dpr, h = canvas.height / dpr;
  ctx.clearRect(0, 0, w, h);
  const left = 56, right = 16, top = 18, bottom = 34;
  const plotW = w - left - right, plotH = h - top - bottom;
  const visible = state.series.filter(s => s.visible);
  const allPoints = visible.flatMap(s => s.points.filter(p => p.t >= state.minT && p.t <= state.maxT));
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, w, h);
  ctx.strokeStyle = '#d0d7de';
  ctx.strokeRect(left, top, plotW, plotH);
  if (allPoints.length === 0) {
    ctx.fillStyle = '#57606a';
    ctx.fillText('表示できる点がありません', left + 12, top + 24);
    return;
  }
  let minV = Math.min(...allPoints.map(p => p.v));
  let maxV = Math.max(...allPoints.map(p => p.v));
  if (minV === maxV) { minV -= 1; maxV += 1; }
  if (state.unit === '%' && minV >= 0 && maxV <= 100) { minV = 0; maxV = 100; }
  const x = t => left + ((t - state.minT) / (state.maxT - state.minT || 1)) * plotW;
  const y = v => top + plotH - ((v - minV) / (maxV - minV || 1)) * plotH;
  ctx.font = '11px "Segoe UI", sans-serif';
  ctx.fillStyle = '#57606a';
  ctx.strokeStyle = '#eaeef2';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const gy = top + (plotH / 4) * i;
    const gv = maxV - ((maxV - minV) / 4) * i;
    ctx.beginPath(); ctx.moveTo(left, gy); ctx.lineTo(left + plotW, gy); ctx.stroke();
    ctx.fillText((Math.round(gv * 100) / 100).toString(), 8, gy + 4);
  }
  for (let i = 0; i <= 4; i++) {
    const tx = state.minT + ((state.maxT - state.minT) / 4) * i;
    const gx = left + (plotW / 4) * i;
    ctx.fillText(fmtTime(tx), gx - 22, h - 10);
  }
  visible.forEach(s => {
    ctx.strokeStyle = s.color;
    ctx.lineWidth = 1.8;
    ctx.beginPath();
    let started = false;
    s.points.forEach(p => {
      if (p.t < state.minT || p.t > state.maxT) { return; }
      const px = x(p.t), py = y(p.v);
      if (!started) { ctx.moveTo(px, py); started = true; }
      else { ctx.lineTo(px, py); }
    });
    if (started) { ctx.stroke(); }
  });
}
function makeChart(metric) {
  const section = document.createElement('section');
  section.className = 'chart';
  const head = document.createElement('div');
  head.className = 'chart-head';
  const title = document.createElement('div');
  title.className = 'chart-title';
  title.textContent = `${metric.label}${metric.unit ? ' (' + metric.unit + ')' : ''}`;
  const tools = document.createElement('div');
  tools.className = 'chart-tools';
  const reset = document.createElement('button');
  reset.textContent = 'Reset';
  tools.appendChild(reset);
  head.appendChild(title);
  head.appendChild(tools);
  const legend = document.createElement('div');
  legend.className = 'legend';
  const canvas = document.createElement('canvas');
  const state = {
    canvas,
    unit: metric.unit || '',
    series: (metric.series || []).map((s, i) => ({ name:s.name, color:palette[i % palette.length], visible:true, points:(s.points || []).map(parsePoint).sort((a,b) => a.t - b.t) }))
  };
  const times = state.series.flatMap(s => s.points.map(p => p.t));
  state.fullMinT = Math.min(...times); state.fullMaxT = Math.max(...times);
  state.minT = state.fullMinT; state.maxT = state.fullMaxT;
  state.series.forEach((s, i) => {
    const id = `${metric.key}-${i}`.replace(/[^A-Za-z0-9_-]/g, '_');
    const label = document.createElement('label');
    const cb = document.createElement('input');
    cb.type = 'checkbox'; cb.checked = true; cb.id = id;
    cb.addEventListener('change', () => { s.visible = cb.checked; drawChart(state); });
    const sw = document.createElement('span');
    sw.className = 'swatch'; sw.style.background = s.color;
    const text = document.createElement('span');
    text.textContent = s.name;
    label.appendChild(cb); label.appendChild(sw); label.appendChild(text);
    legend.appendChild(label);
  });
  reset.addEventListener('click', () => { state.minT = state.fullMinT; state.maxT = state.fullMaxT; drawChart(state); });
  let dragStartX = null, dragStartMin = null, dragStartMax = null;
  canvas.addEventListener('wheel', ev => {
    ev.preventDefault();
    const span = state.maxT - state.minT;
    const factor = ev.deltaY < 0 ? 0.82 : 1.22;
    const rect = canvas.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (ev.clientX - rect.left - 56) / Math.max(1, rect.width - 72)));
    const center = state.minT + span * ratio;
    let nextSpan = Math.max(1000, Math.min(state.fullMaxT - state.fullMinT, span * factor));
    state.minT = Math.max(state.fullMinT, center - nextSpan * ratio);
    state.maxT = Math.min(state.fullMaxT, state.minT + nextSpan);
    state.minT = Math.max(state.fullMinT, state.maxT - nextSpan);
    drawChart(state);
  }, { passive:false });
  canvas.addEventListener('mousedown', ev => { dragStartX = ev.clientX; dragStartMin = state.minT; dragStartMax = state.maxT; });
  window.addEventListener('mouseup', () => { dragStartX = null; });
  window.addEventListener('mousemove', ev => {
    if (dragStartX === null) { return; }
    const span = dragStartMax - dragStartMin;
    const dx = ev.clientX - dragStartX;
    const rect = canvas.getBoundingClientRect();
    const shift = -dx / Math.max(1, rect.width - 72) * span;
    state.minT = Math.max(state.fullMinT, Math.min(state.fullMaxT - span, dragStartMin + shift));
    state.maxT = state.minT + span;
    drawChart(state);
  });
  section.appendChild(head);
  section.appendChild(legend);
  section.appendChild(canvas);
  root.appendChild(section);
  drawChart(state);
  window.addEventListener('resize', () => drawChart(state));
}
(payload.metrics || []).forEach(makeChart);
</script>
</body>
</html>
'@

    $html = $htmlTemplate.Replace('__TITLE__', (ConvertTo-HtmlText $title)).Replace('__PAYLOAD_JSON__', $json)

    $utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8Bom)
}

function New-PerfComparisonOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$InputPath,
        [Parameter(Mandatory=$true)][string[]]$MetricKey,
        [Parameter(Mandatory=$true)][string]$OutputDir
    )

    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputDir -Force
    }

    $parsed = Read-PerfMonitorDataFiles -Path $InputPath
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlPath = Join-Path $OutputDir "performance-comparison-$stamp.html"
    $csvPath = Join-Path $OutputDir "performance-comparison-$stamp.csv"
    $csvRows = Export-PerfMonitorSelectionCsv -Rows $parsed.Rows -MetricKey $MetricKey -OutputPath $csvPath
    New-PerfComparisonHtml -Rows $parsed.Rows -MetricKey $MetricKey -OutputPath $htmlPath -Warnings $parsed.Warnings

    return [PSCustomObject]@{
        HtmlPath = $htmlPath
        CsvPath  = $csvPath
        RowCount = @($csvRows).Count
        Warnings = $parsed.Warnings
    }
}

function Show-PerfComparisonWindow {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PerfMonitor 比較グラフ作成" Width="980" Height="680" MinWidth="820" MinHeight="560"
        WindowStartupLocation="CenterScreen" FontFamily="Yu Gothic UI, Segoe UI" Background="#FFFFFF">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="120"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="PerfMonitor 比較グラフ作成" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="2*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="1.4*"/>
      </Grid.ColumnDefinitions>
      <GroupBox Header="入力 data.jsonl" Grid.Column="0" Padding="8">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
            <Button Name="AddFilesButton" Content="追加..." Width="88" Margin="0,0,8,0"/>
            <Button Name="RemoveFilesButton" Content="削除" Width="72" Margin="0,0,8,0"/>
            <Button Name="ReloadButton" Content="指標を再読込" Width="112"/>
          </StackPanel>
          <ListBox Name="InputListBox"/>
        </DockPanel>
      </GroupBox>
      <GroupBox Header="グラフ化する指標" Grid.Column="2" Padding="8">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
            <Button Name="SelectAllButton" Content="全選択" Width="72" Margin="0,0,8,0"/>
            <Button Name="ClearSelectionButton" Content="解除" Width="72"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Name="MetricPanel"/>
          </ScrollViewer>
        </DockPanel>
      </GroupBox>
    </Grid>
    <Grid Grid.Row="2" Margin="0,12,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="出力先" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox Name="OutputDirTextBox" Grid.Column="1" Height="26" VerticalContentAlignment="Center"/>
      <Button Name="BrowseOutputButton" Grid.Column="2" Content="参照..." Width="80" Margin="8,0,8,0"/>
      <Button Name="GenerateButton" Grid.Column="3" Content="HTML/CSV生成" Width="120" Background="#0969DA" Foreground="White"/>
    </Grid>
    <TextBox Name="LogTextBox" Grid.Row="3" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"
             Background="#F6F8FA" BorderBrush="#D0D7DE"/>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $addFilesButton = $window.FindName('AddFilesButton')
    $removeFilesButton = $window.FindName('RemoveFilesButton')
    $reloadButton = $window.FindName('ReloadButton')
    $inputListBox = $window.FindName('InputListBox')
    $metricPanel = $window.FindName('MetricPanel')
    $selectAllButton = $window.FindName('SelectAllButton')
    $clearSelectionButton = $window.FindName('ClearSelectionButton')
    $outputDirTextBox = $window.FindName('OutputDirTextBox')
    $browseOutputButton = $window.FindName('BrowseOutputButton')
    $generateButton = $window.FindName('GenerateButton')
    $logTextBox = $window.FindName('LogTextBox')
    $state = @{ Parsed = $null }

    $outputDirTextBox.Text = Join-Path (Get-Location).Path 'reports'

    function Add-LogMessage {
        param([string]$Message)
        $logTextBox.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $Message`r`n")
        $logTextBox.ScrollToEnd()
    }

    function Get-InputPaths {
        $paths = @()
        foreach ($item in $inputListBox.Items) { $paths += [string]$item }
        return $paths
    }

    function Refresh-Metrics {
        $metricPanel.Children.Clear()
        $paths = @(Get-InputPaths)
        if ($paths.Count -eq 0) {
            Add-LogMessage 'data.jsonl を追加してください。'
            return
        }
        try {
            $parsed = Read-PerfMonitorDataFiles -Path $paths
            $state.Parsed = $parsed
            foreach ($metric in @($parsed.Metrics)) {
                $cb = New-Object System.Windows.Controls.CheckBox
                $label = if ([string]::IsNullOrWhiteSpace($metric.Unit)) { $metric.Label } else { "$($metric.Label) [$($metric.Unit)]" }
                $cb.Content = $label
                $cb.Tag = $metric.Key
                $cb.IsChecked = $true
                $cb.Margin = '0,0,0,6'
                $metricPanel.Children.Add($cb) | Out-Null
            }
            Add-LogMessage "指標を読み込みました: $($parsed.Metrics.Count) 件 / データ行 $($parsed.Rows.Count) 件"
            foreach ($warning in @($parsed.Warnings)) { Add-LogMessage "警告: $warning" }
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, '読み込みエラー', 'OK', 'Error') | Out-Null
            Add-LogMessage "読み込みエラー: $($_.Exception.Message)"
        }
    }

    $addFilesButton.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'PerfMonitor data.jsonl|data.jsonl|JSON Lines (*.jsonl)|*.jsonl|All files (*.*)|*.*'
        $dialog.Multiselect = $true
        if ($dialog.ShowDialog() -eq $true) {
            foreach ($file in $dialog.FileNames) {
                if (-not $inputListBox.Items.Contains($file)) {
                    $inputListBox.Items.Add($file) | Out-Null
                }
            }
            Refresh-Metrics
        }
    })
    $removeFilesButton.Add_Click({
        $selected = @($inputListBox.SelectedItems)
        foreach ($item in $selected) { $inputListBox.Items.Remove($item) }
        Refresh-Metrics
    })
    $reloadButton.Add_Click({ Refresh-Metrics })
    $selectAllButton.Add_Click({ foreach ($child in $metricPanel.Children) { if ($child -is [System.Windows.Controls.CheckBox]) { $child.IsChecked = $true } } })
    $clearSelectionButton.Add_Click({ foreach ($child in $metricPanel.Children) { if ($child -is [System.Windows.Controls.CheckBox]) { $child.IsChecked = $false } } })
    $browseOutputButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = '出力先フォルダーを選択してください'
        if (Test-Path -LiteralPath $outputDirTextBox.Text -PathType Container) {
            $dialog.SelectedPath = $outputDirTextBox.Text
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $outputDirTextBox.Text = $dialog.SelectedPath
        }
    })
    $generateButton.Add_Click({
        $paths = @(Get-InputPaths)
        $metrics = @()
        foreach ($child in $metricPanel.Children) {
            if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) {
                $metrics += [string]$child.Tag
            }
        }
        if ($paths.Count -eq 0) {
            [System.Windows.MessageBox]::Show('data.jsonl を1つ以上追加してください。', '入力不足', 'OK', 'Warning') | Out-Null
            return
        }
        if ($metrics.Count -eq 0) {
            [System.Windows.MessageBox]::Show('グラフ化する指標を1つ以上選択してください。', '入力不足', 'OK', 'Warning') | Out-Null
            return
        }
        try {
            $generateButton.IsEnabled = $false
            Add-LogMessage 'HTML/CSV を生成しています...'
            $result = New-PerfComparisonOutput -InputPath $paths -MetricKey $metrics -OutputDir $outputDirTextBox.Text
            Add-LogMessage "完了: HTML=$($result.HtmlPath)"
            Add-LogMessage "完了: CSV=$($result.CsvPath) / 行数 $($result.RowCount)"
            foreach ($warning in @($result.Warnings)) { Add-LogMessage "警告: $warning" }
            Start-Process -FilePath $result.HtmlPath
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, '生成エラー', 'OK', 'Error') | Out-Null
            Add-LogMessage "生成エラー: $($_.Exception.Message)"
        } finally {
            $generateButton.IsEnabled = $true
        }
    })

    Add-LogMessage 'data.jsonl を追加してください。'
    $window.ShowDialog() | Out-Null
}

if (-not $NoGui) {
    Show-PerfComparisonWindow
}
