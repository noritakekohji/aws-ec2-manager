#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $Script:Src = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'
    $content = Get-Content -Raw -LiteralPath $Script:Src
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
    # Load class + support functions needed by Compare-Filelist
    $classes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)
    foreach ($c in $classes) { Invoke-Expression $c.Extent.Text }
    $needed = @('Format-Val','Compare-Dict','Compare-List','Get-Prop','As-Array','Obj-To-Dict','Compare-Filelist')
    foreach ($name in $needed) {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn -or $fn.Count -eq 0) { throw "$name not found in $Script:Src" }
        Invoke-Expression $fn[0].Extent.Text
    }
}

Describe 'Compare-Filelist' {
    It 'detects ADDED target' {
        $b = @()
        $a = @(@{ key='new'; path='/tmp/new'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='x.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/new' }).AddedCount | Should -BeGreaterThan 0
    }

    It 'detects REMOVED target' {
        $b = @(@{ key='gone'; path='/tmp/gone'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='x.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $a = @()
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/gone' }).RemovedCount | Should -BeGreaterThan 0
    }

    It 'detects REMOVED entry within a target' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(); truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).RemovedCount | Should -Be 1
    }

    It 'detects CHANGED when owner differs' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='admin' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 1
    }

    It 'compares sha256 only when hash_enabled=true on both sides' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='aaa' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='bbb' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 1
    }

    It 'ignores sha256 when hash_enabled=false on either side' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='aaa' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='bbb' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 0
    }
}
