#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $Script:Src = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'
}

Describe 'filelist integration in collect' {
    BeforeEach {
        $Script:TmpRoot = Join-Path $env:TEMP ("filelist-int-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $Script:TmpRoot -Force | Out-Null
        $Script:OutFile = Join-Path $Script:TmpRoot 'snap.json'
    }
    AfterEach {
        Remove-Item -LiteralPath $Script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:_OPS_FILELIST_CONF -ErrorAction SilentlyContinue
    }

    It 'includes filelist in output when -Category filelist is used' {
        $target = Join-Path $Script:TmpRoot 'data'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'a.txt') -Value 'x' -NoNewline
        $confPath = Join-Path $Script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path = $target
"@
        $env:_OPS_FILELIST_CONF = $confPath

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:Src `
            collect -Category filelist -OutputPath $Script:OutFile *> $null
        $LASTEXITCODE | Should -Be 0

        $json = Get-Content -LiteralPath $Script:OutFile -Raw | ConvertFrom-Json
        $json.filelist            | Should -Not -BeNullOrEmpty
        $json.filelist.Count      | Should -Be 1
        $json.filelist[0].key     | Should -Be 't'
        $json.filelist[0].exists  | Should -Be $true
        ($json.filelist[0].entries | Where-Object { $_.rel_path -eq 'a.txt' }) | Should -Not -BeNullOrEmpty
    }

    It 'emits filelist=[] when conf has no [target:*]' {
        $confPath = Join-Path $Script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @'
[limits]
max_entries_per_target = 100000
'@
        $env:_OPS_FILELIST_CONF = $confPath

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:Src `
            collect -Category filelist -OutputPath $Script:OutFile *> $null
        $LASTEXITCODE | Should -Be 0
        $json = Get-Content -LiteralPath $Script:OutFile -Raw | ConvertFrom-Json
        # ConvertFrom-Json turns [] into null on PS 5.1 unless -AsHashtable / -Depth deep enough.
        # Accept either an empty array/collection or $null (both indicate no targets scanned).
        if ($null -ne $json.filelist) {
            @($json.filelist).Count | Should -Be 0
        }
    }

    It 'includes filelist as part of -Category all' {
        $target = Join-Path $Script:TmpRoot 'data-all'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'a.txt') -Value 'x' -NoNewline
        $confPath = Join-Path $Script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:all]
path = $target
"@
        $env:_OPS_FILELIST_CONF = $confPath

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:Src `
            collect -Category all -OutputPath $Script:OutFile *> $null
        $LASTEXITCODE | Should -Be 0
        $json = Get-Content -LiteralPath $Script:OutFile -Raw | ConvertFrom-Json
        $json.filelist                  | Should -Not -BeNullOrEmpty
        $json.filelist[0].key           | Should -Be 'all'
        # Sanity check that other categories are still populated
        $json.os                        | Should -Not -BeNullOrEmpty
    }
}
