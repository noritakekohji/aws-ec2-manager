#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'file-transfer-check pure logic' {
    BeforeAll {
        $env:FTC_SKIP_MAIN = '1'
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\file-transfer-check\Check-FileTransfer.ps1')).Path
        . $script:ScriptPath
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ftc-test-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\FTC_SKIP_MAIN -ErrorAction SilentlyContinue
    }

    Context 'Read-ShareList' {
        It 'parses a 4-field line' {
            $f = Join-Path $script:TmpDir 'a.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\share, svc_user, ok, 業務共有'
            $r = Read-ShareList $f
            $r.Count | Should -Be 1
            $r[0].share       | Should -Be '\\srv\share'
            $r[0].username    | Should -Be 'svc_user'
            $r[0].expected    | Should -Be 'ok'
            $r[0].description | Should -Be '業務共有'
        }
        It 'treats blank username as integrated auth' {
            $f = Join-Path $script:TmpDir 'b.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\share, , ok, desc'
            (Read-ShareList $f)[0].username | Should -Be ''
        }
        It 'skips comments and blank lines' {
            $f = Join-Path $script:TmpDir 'c.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value @('# comment', '', '\\srv\s, , -, d')
            (Read-ShareList $f).Count | Should -Be 1
        }
        It 'normalizes invalid expected to dash' {
            $f = Join-Path $script:TmpDir 'd.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\s, , bogus, d'
            (Read-ShareList $f)[0].expected | Should -Be '-'
        }
        It 'falls back to share as description when omitted' {
            $f = Join-Path $script:TmpDir 'e.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\s'
            (Read-ShareList $f)[0].description | Should -Be '\\srv\s'
        }
    }

    Context 'Get-TransferEval' {
        It 'expected=ok & success -> OK'   { Get-TransferEval 'ok' $true  | Should -Be 'OK' }
        It 'expected=ok & fail -> NG'      { Get-TransferEval 'ok' $false | Should -Be 'NG' }
        It 'expected=ng & fail -> OK'      { Get-TransferEval 'ng' $false | Should -Be 'OK' }
        It 'expected=ng & success -> NG'   { Get-TransferEval 'ng' $true  | Should -Be 'NG' }
        It 'expected=- & success -> OK'    { Get-TransferEval '-'  $true  | Should -Be 'OK' }
        It 'expected=- & fail -> WARN'     { Get-TransferEval '-'  $false | Should -Be 'WARN' }
    }
    Context 'Get-TransferSpeed' {
        It 'computes MB/s' { Get-TransferSpeed ([long](10 * 1MB)) 2.0 | Should -Be 5.0 }
        It 'returns 0 for non-positive seconds' { Get-TransferSpeed 1048576 0 | Should -Be 0.0 }
    }
    Context 'Test-HashMatch' {
        It 'matches ignoring case' { Test-HashMatch 'ABCD' 'abcd' | Should -BeTrue }
        It 'detects mismatch'      { Test-HashMatch 'ABCD' 'ef01' | Should -BeFalse }
    }

    Context 'New-HtmlReport' {
        It 'renders share and result but never a password' {
            $rows = @(
                @{ share='\\srv\share'; username='svc_user'; eval='OK'; upMbps=8.3; downMbps=11.1;
                   verify='OK'; message=''; description='業務共有' }
            )
            $html = New-HtmlReport $rows @{ generated='2026-07-24 10:00:00'; sizeMB=10 }
            $html | Should -Match '\\\\srv\\share'
            $html | Should -Match 'OK'
            $html | Should -Not -Match 'password'
        }
    }
}