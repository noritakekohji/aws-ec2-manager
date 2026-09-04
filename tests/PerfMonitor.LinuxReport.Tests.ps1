$ErrorActionPreference = 'Stop'

Describe 'PerfMonitor Linux data report on Windows' {
    It 'reports Linux data even when one collected JSON line is invalid' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path $repoRoot 'tools\perf-monitor\PerfMonitor.ps1'
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("perf-linux-report-" + [guid]::NewGuid().ToString('N'))
        $sessionDir = Join-Path $tempRoot 'perf_20260904-120000'
        New-Item -ItemType Directory -Path $sessionDir | Out-Null
        try {
            $dataFile = Join-Path $sessionDir 'data.jsonl'
            $lines = @(
                '{"ts":"2026-09-04T12:00:00+09:00","hostname":"rhel-a","os":"linux","cpu_pct":10.0,"mem_used_pct":40.0,"mem_used_gb":1.0,"mem_free_gb":2.0,"mem_total_gb":3.0,"swap_used_pct":0.0,"swap_used_gb":0.0,"disk_read_mbps":1.25,"disk_write_mbps":2.50,"disk_usage_pct":{"/":50},"net_rx_mbps":3.0,"net_tx_mbps":4.0,"load_avg_1":0.1,"load_avg_5":0.2,"load_avg_15":0.3,"proc_count":100}',
                '{"ts":"2026-09-04T12:00:05+09:00","hostname":"rhel-a","os":"linux","cpu_pct":11.0,"mem_used_pct":41.0,"mem_used_gb":1.1,"mem_free_gb":1.9,"mem_total_gb":3.0,"swap_used_pct":0.0,"swap_used_gb":0.0,"disk_read_mbps":1.50,"disk_write_mbps":2.75,"disk_usage_pct":{"/":51},"net_rx_mbps":3.1,"net_tx_mbps":4.1,"load_avg_1":0.2,"load_avg_5":0.3,"load_avg_15":0.4,"proc_count":101}',
                '{"ts":"2026-09-04T12:00:10+09:00","hostname":"rhel-a","os":"linux","disk_usage_pct":{"/":-}}'
            )
            [System.IO.File]::WriteAllText($dataFile, ($lines -join [Environment]::NewLine), [System.Text.Encoding]::UTF8)

            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath report $sessionDir 2>&1
            $LASTEXITCODE | Should -Be 0
            $reportPath = Join-Path $sessionDir 'report.html'
            Test-Path -LiteralPath $reportPath | Should -BeTrue
            $html = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8
            $html | Should -Match 'rhel-a'
            $html | Should -Match 'ディスク I/O'
            $html | Should -Match '1.5MB/s'
            ($output | Out-String) | Should -Match 'Invalid JSON lines skipped'
        } finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
