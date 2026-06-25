#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'AwsConfig' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\AwsConfig.psm1')).Path
        Import-Module $script:ModulePath -Force

        $script:TmpConfig = [System.IO.Path]::GetTempFileName()
        $iniLines = @(
            '[default]'
            'region = us-east-1'
            'sso_start_url = https://default.awsapps.com/start'
            'sso_account_id = 111111111111'
            ''
            '[profile dev]'
            'region = ap-northeast-1'
            'sso_start_url = https://example.awsapps.com/start'
            'sso_account_id = 222222222222'
            ''
            '[profile prod]'
            'region = us-west-2'
            'sso_start_url = https://example.awsapps.com/start'
            'sso_account_id = 333333333333'
            ''
            '# a comment'
            '; another comment'
            ''
            '[profile minimal]'
            'region = eu-west-1'
            ''
            '[sso-session my-sso]'
            'sso_start_url = https://session.awsapps.com/start'
            'sso_region = us-east-1'
            ''
            '[profile with-session]'
            'region = us-east-1'
            'sso_session = my-sso'
            'sso_account_id = 444444444444'
        )
        Set-Content -LiteralPath $script:TmpConfig -Value $iniLines -Encoding UTF8

        $script:MissingPath = Join-Path ([System.IO.Path]::GetTempPath()) ('aws-cfg-missing-' + [guid]::NewGuid().ToString() + '.ini')
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TmpConfig) {
            Remove-Item -LiteralPath $script:TmpConfig -Force
        }
        Remove-Module AwsConfig -ErrorAction SilentlyContinue
    }

    Context 'Get-AwsProfiles' {
        It 'returns all profile names including default' {
            $profiles = Get-AwsProfiles -ConfigPath $script:TmpConfig
            $profiles | Should -Contain 'default'
            $profiles | Should -Contain 'dev'
            $profiles | Should -Contain 'prod'
            $profiles | Should -Contain 'minimal'
            $profiles | Should -Contain 'with-session'
            $profiles.Count | Should -Be 5
        }

        It 'returns an empty array when config file is missing' {
            $profiles = Get-AwsProfiles -ConfigPath $script:MissingPath
            ($profiles | Measure-Object).Count | Should -Be 0
        }
    }

    Context 'Get-AwsProfileDetail' {
        It 'returns detail for an existing named profile' {
            $detail = Get-AwsProfileDetail -Name 'dev' -ConfigPath $script:TmpConfig
            $detail | Should -Not -BeNullOrEmpty
            $detail.Name | Should -Be 'dev'
            $detail.Region | Should -Be 'ap-northeast-1'
            $detail.SsoStartUrl | Should -Be 'https://example.awsapps.com/start'
            $detail.SsoAccountId | Should -Be '222222222222'
        }

        It 'returns detail for the default profile' {
            $detail = Get-AwsProfileDetail -Name 'default' -ConfigPath $script:TmpConfig
            $detail | Should -Not -BeNullOrEmpty
            $detail.Region | Should -Be 'us-east-1'
            $detail.SsoAccountId | Should -Be '111111111111'
        }

        It 'returns null for an unknown profile' {
            $detail = Get-AwsProfileDetail -Name 'nope' -ConfigPath $script:TmpConfig
            $detail | Should -BeNullOrEmpty
        }

        It 'leaves missing keys as null' {
            $detail = Get-AwsProfileDetail -Name 'minimal' -ConfigPath $script:TmpConfig
            $detail.Region | Should -Be 'eu-west-1'
            $detail.SsoStartUrl | Should -BeNullOrEmpty
            $detail.SsoAccountId | Should -BeNullOrEmpty
        }

        It 'resolves sso_start_url from [sso-session] block when profile uses sso_session reference' {
            $detail = Get-AwsProfileDetail -Name 'with-session' -ConfigPath $script:TmpConfig
            $detail.SsoStartUrl | Should -Be 'https://session.awsapps.com/start'
            $detail.SsoAccountId | Should -Be '444444444444'
        }
    }

    Context 'Test-SsoToken' {
        It 'returns true when aws cli exits 0' {
            Mock -ModuleName AwsConfig Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 0; Output = '{"Account":"123"}'; Success = $true }
            }
            Test-SsoToken -Name 'dev' | Should -BeTrue
        }

        It 'returns false when aws cli exits non-zero' {
            Mock -ModuleName AwsConfig Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 255; Output = 'error'; Success = $false }
            }
            Test-SsoToken -Name 'dev' | Should -BeFalse
        }
    }
}
