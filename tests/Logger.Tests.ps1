#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Logger' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\Logger.psm1')).Path
        Import-Module $script:ModulePath -Force
        $script:TmpLog = [System.IO.Path]::GetTempFileName()
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TmpLog) { Remove-Item -LiteralPath $script:TmpLog -Force }
        Remove-Module Logger -ErrorAction SilentlyContinue
    }

    Context 'Initialize-AppLogger + Write-AppLog' {
        It 'writes a line to the log file' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'INFO' -Message 'test message'
            $lastLine = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Not -BeNullOrEmpty
            $lastLine | Should -Match '\[INFO\] test message'
        }

        It 'includes a timestamp in the line' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'INFO' -Message 'ts check'
            $lastLine = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }

        It 'writes WARN level correctly' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'WARN' -Message 'warn test'
            $lastLine = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Match '\[WARN\] warn test'
        }

        It 'writes ERROR level correctly' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'ERROR' -Message 'err test'
            $lastLine = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8 | Select-Object -Last 1
            $lastLine | Should -Match '\[ERROR\] err test'
        }

        It 'does nothing when LogPath is null' {
            Initialize-AppLogger -LogPath $null
            { Write-AppLog -Level 'INFO' -Message 'no-op' } | Should -Not -Throw
        }

        It 'does nothing when LogPath is empty string' {
            Initialize-AppLogger -LogPath ''
            { Write-AppLog -Level 'INFO' -Message 'no-op' } | Should -Not -Throw
        }

        It 'appends multiple lines' {
            $appendLog = [System.IO.Path]::GetTempFileName()
            try {
                Initialize-AppLogger -LogPath $appendLog
                Write-AppLog -Level 'INFO' -Message 'line1'
                Write-AppLog -Level 'INFO' -Message 'line2'
                $lines = Get-Content -LiteralPath $appendLog -Encoding UTF8
                ($lines | Measure-Object).Count | Should -BeGreaterOrEqual 2
            } finally {
                Remove-Item -LiteralPath $appendLog -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
