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
}