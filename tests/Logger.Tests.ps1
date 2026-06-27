#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Logger' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\Logger.psm1')).Path
        Import-Module $script:ModulePath -Force
        $script:TmpLogRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aws-ec2-manager-log-test-' + [guid]::NewGuid().ToString())
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TmpLogRoot) { Remove-Item -LiteralPath $script:TmpLogRoot -Recurse -Force }
        Remove-Module Logger -ErrorAction SilentlyContinue
    }

    Context 'Initialize-AppLogger + Write-AppLog' {
        It 'writes a line to the log file' {
            Initialize-AppLogger -LogPath $script:TmpLogRoot
            Write-AppLog -Level 'INFO' -Message 'test message'
            $logFile = Join-Path (Join-Path $script:TmpLogRoot (Get-Date -Format 'yyyy-MM-dd')) 'app.log'
            $lastLine = Get-Content -LiteralPath $logFile -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Not -BeNullOrEmpty
            $lastLine | Should -Match '\[INFO\] test message'
        }

        It 'includes a timestamp in the line' {
            Initialize-AppLogger -LogPath $script:TmpLogRoot
            Write-AppLog -Level 'INFO' -Message 'ts check'
            $logFile = Join-Path (Join-Path $script:TmpLogRoot (Get-Date -Format 'yyyy-MM-dd')) 'app.log'
            $lastLine = Get-Content -LiteralPath $logFile -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }

        It 'writes WARN level correctly' {
            Initialize-AppLogger -LogPath $script:TmpLogRoot
            Write-AppLog -Level 'WARN' -Message 'warn test'
            $logFile = Join-Path (Join-Path $script:TmpLogRoot (Get-Date -Format 'yyyy-MM-dd')) 'app.log'
            $lastLine = Get-Content -LiteralPath $logFile -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Match '\[WARN\] warn test'
        }

        It 'writes ERROR level correctly' {
            Initialize-AppLogger -LogPath $script:TmpLogRoot
            Write-AppLog -Level 'ERROR' -Message 'err test'
            $logFile = Join-Path (Join-Path $script:TmpLogRoot (Get-Date -Format 'yyyy-MM-dd')) 'app.log'
            $lastLine = Get-Content -LiteralPath $logFile -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Match '\[ERROR\] err test'
        }

        It 'uses the default log root when LogPath is null' {
            Initialize-AppLogger -LogPath $null
            { Write-AppLog -Level 'INFO' -Message 'no-op' } | Should -Not -Throw
            Get-AppLogDirectory | Should -Match '\\\d{4}-\d{2}-\d{2}$'
        }

        It 'uses the default log root when LogPath is empty string' {
            Initialize-AppLogger -LogPath ''
            { Write-AppLog -Level 'INFO' -Message 'no-op' } | Should -Not -Throw
            Get-AppLogDirectory | Should -Match '\\\d{4}-\d{2}-\d{2}$'
        }

        It 'appends multiple lines' {
            $appendRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aws-ec2-manager-log-append-' + [guid]::NewGuid().ToString())
            try {
                Initialize-AppLogger -LogPath $appendRoot
                Write-AppLog -Level 'INFO' -Message 'line1'
                Write-AppLog -Level 'INFO' -Message 'line2'
                $appendLog = Join-Path (Join-Path $appendRoot (Get-Date -Format 'yyyy-MM-dd')) 'app.log'
                $lines = Get-Content -LiteralPath $appendLog -Encoding UTF8
                ($lines | Measure-Object).Count | Should -BeGreaterOrEqual 2
            } finally {
                Remove-Item -LiteralPath $appendRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
