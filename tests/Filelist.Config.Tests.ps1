#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $Script:Src = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'
    # Extract just Read-FilelistConf to avoid running full script side-effects.
    # We dot-source into a scriptblock scope. If dot-sourcing runs the param() block
    # and errors, we fall back to reading source and defining Read-FilelistConf via Invoke-Expression.
    # Simplest reliable path: use PowerShell AST to grab the function definition and Invoke-Expression it.
    $content = Get-Content -Raw -LiteralPath $Script:Src
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
    $fn  = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-FilelistConf' }, $true)
    if (-not $fn -or $fn.Count -eq 0) {
        throw "Read-FilelistConf not found in $Script:Src"
    }
    Invoke-Expression $fn[0].Extent.Text
}

Describe 'Read-FilelistConf' {
    AfterEach {
        Remove-Item Env:_OPS_FILELIST_CONF -ErrorAction SilentlyContinue
    }

    It 'returns empty targets when conf is missing' {
        $env:_OPS_FILELIST_CONF = Join-Path $env:TEMP ('no-such-' + [Guid]::NewGuid().ToString('N') + '.conf')
        $conf = Read-FilelistConf
        $conf.targets.Count | Should -Be 0
        $conf.max_entries_per_target | Should -Be 100000
    }

    It 'parses a single target with defaults' {
        $f = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $f -Value @'
[target:etc]
path = /etc/nginx
'@
        $env:_OPS_FILELIST_CONF = $f
        $conf = Read-FilelistConf
        $conf.targets.Count | Should -Be 1
        $conf.targets[0].key      | Should -Be 'etc'
        $conf.targets[0].path     | Should -Be '/etc/nginx'
        $conf.targets[0].os       | Should -Be 'both'
        $conf.targets[0].depth    | Should -Be 'unlimited'
        ,$conf.targets[0].exclude | Should -BeOfType [System.Array]
        $conf.targets[0].exclude.Count | Should -Be 0
        $conf.targets[0].hash     | Should -Be $false
        Remove-Item -LiteralPath $f -Force
    }

    It 'parses depth as integer, unlimited, and falls back on invalid' {
        $f = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $f -Value @'
[target:a]
path  = /a
depth = 2

[target:b]
path  = /b
depth = unlimited

[target:c]
path  = /c
depth = notanumber
'@
        $env:_OPS_FILELIST_CONF = $f
        $conf = Read-FilelistConf
        ($conf.targets | Where-Object { $_.key -eq 'a' }).depth | Should -Be 2
        ($conf.targets | Where-Object { $_.key -eq 'b' }).depth | Should -Be 'unlimited'
        ($conf.targets | Where-Object { $_.key -eq 'c' }).depth | Should -Be 'unlimited'
        Remove-Item -LiteralPath $f -Force
    }

    It 'parses exclude as comma-separated globs (trimmed)' {
        $f = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $f -Value @'
[target:x]
path    = /x
exclude = *.tmp , cache/* ,  *.log
'@
        $env:_OPS_FILELIST_CONF = $f
        $conf = Read-FilelistConf
        $conf.targets[0].exclude | Should -Be @('*.tmp','cache/*','*.log')
        Remove-Item -LiteralPath $f -Force
    }

    It 'parses hash as boolean' {
        $f = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $f -Value @'
[target:y]
path = /y
hash = true

[target:z]
path = /z
hash = TRUE
'@
        $env:_OPS_FILELIST_CONF = $f
        $conf = Read-FilelistConf
        ($conf.targets | Where-Object { $_.key -eq 'y' }).hash | Should -Be $true
        ($conf.targets | Where-Object { $_.key -eq 'z' }).hash | Should -Be $true
        Remove-Item -LiteralPath $f -Force
    }

    It 'ignores inline comments in key values' {
        $f = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $f -Value @'
[target:win]
path    = D:\        # required
os      = windows   # windows | linux | both
depth   = 3         # integer or unlimited
exclude = *.tmp     # comma-separated globs
hash    = true      # compute sha256
'@
        $env:_OPS_FILELIST_CONF = $f
        $conf = Read-FilelistConf
        $conf.targets[0].path     | Should -Be 'D:\'
        $conf.targets[0].os       | Should -Be 'windows'
        $conf.targets[0].depth    | Should -Be 3
        $conf.targets[0].exclude  | Should -Be @('*.tmp')
        $conf.targets[0].hash     | Should -Be $true
        Remove-Item -LiteralPath $f -Force
    }

    It 'parses [limits] max_entries_per_target' {
        $f = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $f -Value @'
[limits]
max_entries_per_target = 500
'@
        $env:_OPS_FILELIST_CONF = $f
        $conf = Read-FilelistConf
        $conf.max_entries_per_target | Should -Be 500
        Remove-Item -LiteralPath $f -Force
    }
}
