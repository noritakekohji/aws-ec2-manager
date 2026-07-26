#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $Script:Src = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'
    $content = Get-Content -Raw -LiteralPath $Script:Src
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
    $needed = @(
        'Get-ServiceMaskPatterns',
        'Get-ServiceConfigFiles',
        'Get-ServiceRegistryConfig',
        'Get-RegistryValueMap',
        'Get-RemoteAccessServiceState',
        'Get-RemoteAccessInfo',
        'Safe-Exec',
        'Mask-MwSecrets',
        'Read-MwConfigFile'
    )
    foreach ($name in $needed) {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn -or $fn.Count -eq 0) { throw "$name not found in $Script:Src" }
        Invoke-Expression $fn[0].Extent.Text
    }
}

Describe 'service configuration collection helpers' {
    BeforeEach {
        $Script:TmpRoot = Join-Path $env:TEMP ("service-config-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $Script:TmpRoot -Force | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $Script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:_OPS_SERVICE_CONFIG_ROOT -ErrorAction SilentlyContinue
    }

    It 'collects OpenSSH config files with masking' {
        $configPath = Join-Path $Script:TmpRoot 'sshd_config'
        Set-Content -LiteralPath $configPath -Value @'
Port 22
password = should-not-leak
'@
        $env:_OPS_SERVICE_CONFIG_ROOT = $Script:TmpRoot

        $files = Get-ServiceConfigFiles -Name 'sshd'

        $files.Count | Should -Be 1
        $files.Contains($configPath) | Should -Be $true
        $files[$configPath].readable | Should -Be $true
        $files[$configPath].masked   | Should -Be $true
        $files[$configPath].content  | Should -Match 'password = \*\*\*'
    }

    It 'returns empty registry config for unrelated services' {
        $config = Get-ServiceRegistryConfig -Name 'not-a-real-service'
        $config.Count | Should -Be 0
    }

    It 'collects remote access settings shape on Windows' {
        $info = Get-RemoteAccessInfo
        $info.rdp                | Should -Not -BeNullOrEmpty
        $info.remote_assistance  | Should -Not -BeNullOrEmpty
        $info.services           | Should -Not -BeNull
        $info.ssh                | Should -Not -BeNullOrEmpty
        $info.firewall_rules     | Should -Not -BeNull
    }
}
