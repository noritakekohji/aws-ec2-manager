#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $Script:Src = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'
    $content = Get-Content -Raw -LiteralPath $Script:Src
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
    $needed = @('Read-FilelistConf','Get-FilelistEntryMeta','Test-FilelistExclude','Get-FilelistTarget','Get-FilelistInfo')
    foreach ($name in $needed) {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn -or $fn.Count -eq 0) { throw "$name not found in $Script:Src" }
        Invoke-Expression $fn[0].Extent.Text
    }
}

Describe 'Get-FilelistInfo (Windows metadata basics)' {
    BeforeEach {
        $Script:TmpRoot = Join-Path $env:TEMP ("filelist-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $Script:TmpRoot -Force | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $Script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:_OPS_FILELIST_CONF -ErrorAction SilentlyContinue
    }

    It 'returns empty array when no filelist.conf' {
        $env:_OPS_FILELIST_CONF = Join-Path $env:TEMP ('nope-' + [Guid]::NewGuid().ToString('N') + '.conf')
        $result = @(Get-FilelistInfo)
        $result.Count | Should -Be 0
    }

    It 'marks nonexistent path with exists=false and empty entries' {
        $confPath = Join-Path $Script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:missing]
path = $Script:TmpRoot\does-not-exist
os   = both
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $result.Count | Should -Be 1
        $result[0].key    | Should -Be 'missing'
        $result[0].exists | Should -Be $false
        $result[0].entries.Count | Should -Be 0
    }

    It 'marks os mismatch with os_matched=false and skips scan' {
        $confPath = Join-Path $Script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:linuxonly]
path = $Script:TmpRoot
os   = linux
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $result.Count | Should -Be 1
        $result[0].os_matched   | Should -Be $false
        $result[0].entries.Count | Should -Be 0
    }

    It 'records file entry with owner and acl on Windows' {
        $target = Join-Path $Script:TmpRoot 'data'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'a.txt') -Value 'hello' -NoNewline

        $confPath = Join-Path $Script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path = $target
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $result.Count | Should -Be 1
        $result[0].exists     | Should -Be $true
        $result[0].os_matched | Should -Be $true

        $file = $result[0].entries | Where-Object { $_.rel_path -eq 'a.txt' }
        $file            | Should -Not -BeNullOrEmpty
        $file.type       | Should -Be 'file'
        $file.size       | Should -Be 5
        $file.owner      | Should -Not -BeNullOrEmpty
        $file.mode       | Should -BeNullOrEmpty
        $file.uid        | Should -BeNullOrEmpty
        $file.acl        | Should -Not -BeNullOrEmpty
        $file.acl.Count  | Should -BeGreaterThan 0
        $file.sha256     | Should -BeNullOrEmpty
    }

    It 'computes sha256 when hash=true' {
        $target = Join-Path $Script:TmpRoot 'h'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'a.txt') -Value 'hello' -NoNewline

        $confPath = Join-Path $Script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path = $target
hash = true
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $file = $result[0].entries | Where-Object { $_.rel_path -eq 'a.txt' }
        $file.sha256 | Should -Be '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
    }
}
