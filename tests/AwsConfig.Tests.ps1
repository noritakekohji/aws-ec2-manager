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
            $profiles.Count | Should -Be 4
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
    }

    Context 'Test-SsoToken' {
        It 'returns true when aws cli exits 0' {
            Mock -ModuleName AwsConfig Invoke-AwsCli {
                $global:LASTEXITCODE = 0
                return '{"Account":"123"}'
            }
            Test-SsoToken -Name 'dev' | Should -BeTrue
        }

        It 'returns false when aws cli exits non-zero' {
            Mock -ModuleName AwsConfig Invoke-AwsCli {
                $global:LASTEXITCODE = 255
                return 'error'
            }
            Test-SsoToken -Name 'dev' | Should -BeFalse
        }
    }
}
