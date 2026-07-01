Describe 'filelist category is accepted' {
    BeforeAll {
        $Script = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'
    }

    It 'accepts -Category filelist without error' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script `
            collect -Category filelist -OutputPath (Join-Path $env:TEMP 'filelist-smoke.json') 2>&1
        $LASTEXITCODE | Should -Be 0
    }
}
