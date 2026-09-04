$ErrorActionPreference = 'Stop'

Describe 'Compare-PerfMonitor' {
    BeforeAll {
        $testDir = Split-Path -Parent $PSCommandPath
        $repoRoot = Split-Path -Parent $testDir
        $scriptPath = Join-Path $repoRoot 'tools\perf-monitor\Compare-PerfMonitor.ps1'
        $resolvedScriptPath = (Resolve-Path -LiteralPath $scriptPath).Path
        . $resolvedScriptPath -NoGui
    }

    It 'normalizes top-level and disk usage metrics from data.jsonl' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("perfcompare-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        try {
            $dataFile = Join-Path $tempDir 'data.jsonl'
            $line1 = '{"ts":"2026-08-20T10:00:00","hostname":"server-a","os":"windows","cpu_pct":12.5,"mem_used_pct":60.1,"disk_usage_pct":{"C:":70.2},"net_rx_mbps":1.2}'
            $line2 = '{"ts":"2026-08-20T10:00:05","hostname":"server-a","os":"windows","cpu_pct":13.5,"mem_used_pct":61.1,"disk_usage_pct":{"C:":70.3},"net_rx_mbps":1.4}'
            [System.IO.File]::WriteAllText($dataFile, ($line1 + [Environment]::NewLine + $line2 + [Environment]::NewLine), [System.Text.Encoding]::UTF8)

            $result = Read-PerfMonitorDataFile -Path $dataFile

            @($result.Rows | Where-Object { $_.metric -eq 'cpu_pct' }).Count | Should -Be 2
            @($result.Rows | Where-Object { $_.metric -eq 'disk_usage_pct[C:]' }).Count | Should -Be 2
            ($result.Metrics | Where-Object { $_.Key -eq 'disk_usage_pct[C:]' }).Label | Should -Be 'ディスク使用率 (C:)'
            $result.Server | Should -Be 'server-a'
        } finally {
            if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
        }
    }

    It 'exports selected metrics to CSV and HTML' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("perfcompare-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        try {
            $fileA = Join-Path $tempDir 'data-a.jsonl'
            $fileB = Join-Path $tempDir 'data-b.jsonl'
            [System.IO.File]::WriteAllText($fileA, '{"ts":"2026-08-20T10:00:00","hostname":"server-a","cpu_pct":10}' + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($fileB, '{"ts":"2026-08-20T10:00:00","hostname":"server-b","cpu_pct":20}' + [Environment]::NewLine, [System.Text.Encoding]::UTF8)

            $output = New-PerfComparisonOutput -InputPath @($fileA, $fileB) -MetricKey @('cpu_pct') -OutputDir $tempDir

            Test-Path -LiteralPath $output.HtmlPath | Should -BeTrue
            Test-Path -LiteralPath $output.CsvPath | Should -BeTrue
            $csv = Import-Csv -LiteralPath $output.CsvPath
            @($csv).Count | Should -Be 2
            @($csv | Where-Object { $_.server -eq 'server-a' }).Count | Should -Be 1
            (Get-Content -Raw -LiteralPath $output.HtmlPath -Encoding UTF8) | Should -Match 'server-b'
        } finally {
            if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
        }
    }
}
