#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'AwsManager' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\AwsManager.psm1')).Path
        Import-Module $script:ModulePath -Force
    }

    AfterAll {
        Remove-Module AwsManager -ErrorAction SilentlyContinue
    }

    Context 'Get-SgRuleDiff' {
        It 'reports rules present only in the after set as Added' {
            $before = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '22'; Target = '10.0.0.0/8'; Description = 'ssh'; SecurityGroup = 'base (sg-1)' }
            )
            $after = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '22'; Target = '10.0.0.0/8'; Description = 'ssh'; SecurityGroup = 'base (sg-1)' },
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = 'https'; SecurityGroup = 'web (sg-2)' }
            )
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 1
            $diff.Added[0].Port | Should -Be '443'
            @($diff.Removed).Count | Should -Be 0
        }

        It 'reports rules present only in the before set as Removed' {
            $before = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '3389'; Target = '10.0.0.0/8'; Description = 'rdp'; SecurityGroup = 'old (sg-1)' }
            )
            $after = @()
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Removed).Count | Should -Be 1
            $diff.Removed[0].Port | Should -Be '3389'
            @($diff.Added).Count | Should -Be 0
        }

        It 'treats identical rule content from different SGs (and different memo) as unchanged' {
            $before = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = 'old memo'; SecurityGroup = 'old-sg (sg-1)' })
            $after = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = 'new memo'; SecurityGroup = 'new-sg (sg-2)' })
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 0
            @($diff.Removed).Count | Should -Be 0
        }

        It 'aggregates source SGs for a duplicated added rule' {
            $before = @()
            $after = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'web-a (sg-1)' },
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'web-b (sg-2)' }
            )
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 1
            @($diff.Added[0].SourceSgs).Count | Should -Be 2
            $diff.Added[0].SourceSgs | Should -Contain 'web-a (sg-1)'
            $diff.Added[0].SourceSgs | Should -Contain 'web-b (sg-2)'
        }

        It 'reports a changed rule as both Removed (old) and Added (new)' {
            $before = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'w (sg-1)' })
            $after = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '8443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'w (sg-1)' })
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 1
            $diff.Added[0].Port | Should -Be '8443'
            @($diff.Removed).Count | Should -Be 1
            $diff.Removed[0].Port | Should -Be '443'
        }

        It 'matches rule content case-insensitively' {
            $before = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'TCP'; Port = '443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'w (sg-1)' })
            $after = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'w (sg-1)' })
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 0
            @($diff.Removed).Count | Should -Be 0
        }
    }

    Context 'AWS CLI stderr parsing' {
        It 'uses the message from RemoteException records' {
            InModuleScope AwsManager {
                $ex = New-Object System.Management.Automation.RemoteException 'An error occurred (AccessDeniedException) when calling the SendCommand operation'
                $record = New-Object System.Management.Automation.ErrorRecord $ex, 'NativeCommandError', ([System.Management.Automation.ErrorCategory]::NotSpecified), $null

                Get-ErrorRecordText -ErrorRecord $record | Should -Be 'An error occurred (AccessDeniedException) when calling the SendCommand operation'
            }
        }

        It 'quotes native arguments containing spaces and JSON quotes' {
            InModuleScope AwsManager {
                ConvertTo-NativeArgument -Argument 'plain' | Should -Be 'plain'
                ConvertTo-NativeArgument -Argument 'hello world' | Should -Be '"hello world"'
                ConvertTo-NativeArgument -Argument '{"commands":["echo hi"]}' | Should -Be '"{\"commands\":[\"echo hi\"]}"'
            }
        }
    }

    Context 'Get-Ec2Instances' {
        It 'parses describe-instances JSON into flat objects' {
            $fakeJson = @'
{
  "Reservations": [
    {
      "Instances": [
        {
          "InstanceId": "i-aaa",
          "InstanceType": "t3.micro",
          "PrivateIpAddress": "10.0.0.5",
          "PublicIpAddress": "1.2.3.4",
          "VpcId": "vpc-1",
          "Platform": "windows",
          "State": { "Name": "running" },
          "Placement": { "AvailabilityZone": "ap-northeast-1a" },
          "SecurityGroups": [
            { "GroupId": "sg-1", "GroupName": "web" },
            { "GroupId": "sg-2", "GroupName": "db"  }
          ],
          "Tags": [
            { "Key": "Name", "Value": "win-host" },
            { "Key": "Env",  "Value": "dev" }
          ]
        },
        {
          "InstanceId": "i-bbb",
          "InstanceType": "t3.small",
          "PrivateIpAddress": "10.0.0.6",
          "VpcId": "vpc-1",
          "State": { "Name": "stopped" },
          "Placement": { "AvailabilityZone": "ap-northeast-1c" },
          "SecurityGroups": [],
          "Tags": []
        }
      ]
    }
  ]
}
'@
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instance-information'
            } -MockWith {
                [PSCustomObject]@{
                    ExitCode = 0
                    Output = '{ "InstanceInformationList": [ { "InstanceId": "i-aaa", "PingStatus": "Online", "AgentVersion": "3.3.1", "PlatformName": "Microsoft Windows Server", "PlatformVersion": "2022", "LastPingDateTime": "2026-06-28T00:00:00+09:00" } ] }'
                    Success = $true
                }
            }
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instances'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = $fakeJson; Success = $true }
            }

            $list = Get-Ec2Instances -Profile 'dev'
            $list.Count | Should -Be 2

            $a = $list[0]
            $a.InstanceId | Should -Be 'i-aaa'
            $a.Name | Should -Be 'win-host'
            $a.State | Should -Be 'running'
            $a.Platform | Should -Be 'Windows'
            $a.PublicIpAddress | Should -Be '1.2.3.4'
            $a.AvailabilityZone | Should -Be 'ap-northeast-1a'
            $a.SecurityGroupIds.Count | Should -Be 2
            $a.SecurityGroupIds[0] | Should -Be 'sg-1'
            $a.SecurityGroupIds[1] | Should -Be 'sg-2'
            $a.SecurityGroupNames[0] | Should -Be 'web'
            $a.SsmStatus | Should -Be 'Online'
            $a.SsmAgentVersion | Should -Be '3.3.1'
            $a.SsmPlatformName | Should -Be 'Microsoft Windows Server'

            $b = $list[1]
            $b.InstanceId | Should -Be 'i-bbb'
            $b.Name | Should -Be ''
            $b.Platform | Should -Be 'Linux'
            $b.PublicIpAddress | Should -BeNullOrEmpty
            $b.SecurityGroupIds.Count | Should -Be 0
            $b.SsmStatus | Should -Be '未登録'
        }

        It 'keeps EC2 listing available and marks SsmStatus distinctly when SSM status lookup fails' {
            $fakeJson = '{ "Reservations": [ { "Instances": [ { "InstanceId": "i-1", "InstanceType": "t3.micro", "State": { "Name": "running" }, "Placement": { "AvailabilityZone": "ap-northeast-1a" }, "SecurityGroups": [] } ] } ] }'
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instance-information'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 255; Output = ''; Stderr = 'denied'; Success = $false }
            }
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instances'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = $fakeJson; Success = $true }
            }

            $list = Get-Ec2Instances -Profile 'dev' -ErrorAction SilentlyContinue
            $list.Count | Should -Be 1
            # 取得失敗（権限不足等）は「未登録」ではなく専用ステータスで区別する
            $list[0].SsmStatus | Should -Be 'SSM情報取得失敗'
        }

        It 'keeps EC2 listing available when the caller has $ErrorActionPreference = Stop (App.ps1 sets this globally)' {
            # App.ps1 は先頭で $ErrorActionPreference = 'Stop' を設定するため、
            # -ErrorAction を明示せず呼び出した場合にこの前提が壊れていないか検証する。
            # （-ErrorAction SilentlyContinue を呼び出し側に付けるテストだけだと、
            #   その指定自体が関数内 $ErrorActionPreference を上書きしてしまい、
            #   実アプリと同じ条件を再現できない）
            $fakeJson = '{ "Reservations": [ { "Instances": [ { "InstanceId": "i-1", "InstanceType": "t3.micro", "State": { "Name": "running" }, "Placement": { "AvailabilityZone": "ap-northeast-1a" }, "SecurityGroups": [] } ] } ] }'
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instance-information'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 255; Output = ''; Stderr = 'denied'; Success = $false }
            }
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instances'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = $fakeJson; Success = $true }
            }

            $prevPref = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                $list = Get-Ec2Instances -Profile 'dev'
            }
            finally {
                $ErrorActionPreference = $prevPref
            }
            $list.Count | Should -Be 1
            $list[0].SsmStatus | Should -Be 'SSM情報取得失敗'
        }

        It 'passes --instance-ids to describe-instances when -InstanceIds is given' {
            $fakeJson = '{ "Reservations": [ { "Instances": [ { "InstanceId": "i-1", "InstanceType": "t3.micro", "State": { "Name": "running" }, "Placement": { "AvailabilityZone": "ap-northeast-1a" }, "SecurityGroups": [] } ] } ] }'
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instance-information'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = '{ "InstanceInformationList": [] }'; Success = $true }
            }
            $script:capturedDescribeArgs = $null
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'describe-instances'
            } -MockWith {
                $script:capturedDescribeArgs = $Arguments
                [PSCustomObject]@{ ExitCode = 0; Output = $fakeJson; Success = $true }
            }

            $list = Get-Ec2Instances -Profile 'dev' -InstanceIds @('i-1')
            $list.Count | Should -Be 1
            $idx = [Array]::IndexOf($script:capturedDescribeArgs, '--instance-ids')
            $idx | Should -BeGreaterThan -1
            $script:capturedDescribeArgs[$idx + 1] | Should -Be 'i-1'
        }
    }

    Context 'Get-SsmInstanceInformation' {
        It 'parses describe-instance-information by instance id' {
            $fake = @'
{
  "InstanceInformationList": [
    {
      "InstanceId": "i-aaa",
      "PingStatus": "Online",
      "AgentVersion": "3.3.1",
      "PlatformName": "Ubuntu",
      "PlatformVersion": "22.04",
      "LastPingDateTime": "2026-06-28T00:00:00+09:00"
    }
  ]
}
'@
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 0; Output = $fake; Success = $true }
            }

            $map = Get-SsmInstanceInformation -Profile 'dev'
            $map.ContainsKey('i-aaa') | Should -BeTrue
            $map['i-aaa'].PingStatus | Should -Be 'Online'
            $map['i-aaa'].PlatformName | Should -Be 'Ubuntu'
        }

        It 'throws when aws cli fails, instead of returning an empty map silently' {
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 255; Output = ''; Stderr = 'An error occurred (AccessDeniedException)'; Success = $false }
            }
            { Get-SsmInstanceInformation -Profile 'dev' } | Should -Throw '*AccessDeniedException*'
        }
    }

    Context 'Start/Stop/Restart-Ec2Instance' {
        It 'Start-Ec2Instance passes start-instances args and returns true' {
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                ($Arguments -contains 'start-instances') -and
                ($Arguments -contains 'i-123') -and
                ($Arguments -contains '--profile') -and
                ($Arguments -contains 'dev')
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = '{}'; Success = $true }
            }

            Start-Ec2Instance -Profile 'dev' -InstanceId 'i-123' | Should -BeTrue
            Assert-MockCalled -ModuleName AwsManager -CommandName Invoke-AwsCli -Times 1 -Exactly
        }

        It 'Stop-Ec2Instance uses stop-instances' {
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'stop-instances'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = '{}'; Success = $true }
            }
            Stop-Ec2Instance -Profile 'dev' -InstanceId 'i-123' | Should -BeTrue
        }

        It 'Restart-Ec2Instance uses reboot-instances' {
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'reboot-instances'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = ''; Success = $true }
            }
            Restart-Ec2Instance -Profile 'dev' -InstanceId 'i-123' | Should -BeTrue
        }

        It 'throws with AWS CLI detail when aws cli fails' {
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 255; Output = 'err'; Stderr = 'An error occurred (UnauthorizedOperation)'; Success = $false }
            }
            { Start-Ec2Instance -Profile 'dev' -InstanceId 'i-bad' } | Should -Throw '*UnauthorizedOperation*'
        }
    }

    Context 'Get-VpcSecurityGroups' {
        It 'parses describe-security-groups JSON' {
            $fake = @'
{ "SecurityGroups": [
    {
      "GroupId": "sg-1",
      "GroupName": "web",
      "Description": "web tier",
      "VpcId": "vpc-1",
      "IpPermissions": [
        { "IpProtocol": "tcp", "FromPort": 80, "ToPort": 80, "IpRanges": [ { "CidrIp": "0.0.0.0/0", "Description": "http" } ] }
      ],
      "IpPermissionsEgress": [
        { "IpProtocol": "-1", "IpRanges": [ { "CidrIp": "0.0.0.0/0" } ] }
      ]
    },
    { "GroupId": "sg-2", "GroupName": "db",  "Description": "db tier", "VpcId": "vpc-1", "IpPermissions": [], "IpPermissionsEgress": [] }
]}
'@
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 0; Output = $fake; Success = $true }
            }
            $sgs = Get-VpcSecurityGroups -Profile 'dev' -VpcId 'vpc-1'
            $sgs.Count | Should -Be 2
            $sgs[0].GroupId | Should -Be 'sg-1'
            $sgs[1].GroupName | Should -Be 'db'
            $sgs[0].VpcId | Should -Be 'vpc-1'
            $sgs[0].IpPermissions.Count | Should -Be 1
            $sgs[0].IpPermissionsEgress.Count | Should -Be 1
        }
    }

    Context 'Set-InstanceSecurityGroups' {
        It 'passes group ids in order after --groups' {
            $script:capturedArgs = $null
            Mock -ModuleName AwsManager Invoke-AwsCli {
                $script:capturedArgs = $Arguments
                [PSCustomObject]@{ ExitCode = 0; Output = ''; Success = $true }
            }

            Set-InstanceSecurityGroups -Profile 'dev' -InstanceId 'i-1' -GroupIds @('sg-a','sg-b','sg-c') | Should -BeTrue

            $idx = [Array]::IndexOf($script:capturedArgs, '--groups')
            $idx | Should -BeGreaterThan -1
            $script:capturedArgs[$idx + 1] | Should -Be 'sg-a'
            $script:capturedArgs[$idx + 2] | Should -Be 'sg-b'
            $script:capturedArgs[$idx + 3] | Should -Be 'sg-c'

            $instIdx = [Array]::IndexOf($script:capturedArgs, '--instance-id')
            $script:capturedArgs[$instIdx + 1] | Should -Be 'i-1'
        }

        It 'throws with AWS CLI detail when aws cli fails' {
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 254; Output = ''; Stderr = 'An error occurred (InvalidGroupId.Malformed)'; Success = $false }
            }
            { Set-InstanceSecurityGroups -Profile 'dev' -InstanceId 'i-1' -GroupIds @('sg-a') } | Should -Throw '*InvalidGroupId.Malformed*'
        }
    }

    Context 'IAM instance profiles' {
        It 'parses list-instance-profiles output' {
            $fake = @'
{
  "InstanceProfiles": [
    {
      "Path": "/",
      "InstanceProfileName": "app-profile",
      "Arn": "arn:aws:iam::123456789012:instance-profile/app-profile",
      "Roles": [
        { "RoleName": "app-role" }
      ]
    }
  ]
}
'@
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 0; Output = $fake; Success = $true }
            }

            $profiles = Get-IamInstanceProfiles -Profile 'dev'
            $profiles.Count | Should -Be 1
            $profiles[0].InstanceProfileName | Should -Be 'app-profile'
            $profiles[0].RoleNames[0] | Should -Be 'app-role'
        }

        It 'parses current EC2 instance profile association' {
            $fake = @'
{
  "IamInstanceProfileAssociations": [
    {
      "AssociationId": "iip-assoc-123",
      "InstanceId": "i-1",
      "State": "associated",
      "IamInstanceProfile": {
        "Arn": "arn:aws:iam::123456789012:instance-profile/app-profile",
        "Id": "AIP123"
      }
    }
  ]
}
'@
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 0; Output = $fake; Success = $true }
            }

            $assoc = Get-InstanceProfileAssociation -Profile 'dev' -InstanceId 'i-1'
            $assoc.AssociationId | Should -Be 'iip-assoc-123'
            $assoc.InstanceProfileName | Should -Be 'app-profile'
            $assoc.State | Should -Be 'associated'
        }

        It 'uses associate-iam-instance-profile for Attach' {
            $script:capturedArgs = $null
            Mock -ModuleName AwsManager Invoke-AwsCli {
                $script:capturedArgs = $Arguments
                [PSCustomObject]@{ ExitCode = 0; Output = '{}'; Success = $true }
            }

            Set-InstanceProfileAssociation -Profile 'dev' -InstanceId 'i-1' -Action Attach -InstanceProfileName 'app-profile' | Should -BeTrue
            $script:capturedArgs | Should -Contain 'associate-iam-instance-profile'
            $script:capturedArgs | Should -Contain 'Name=app-profile'
        }

        It 'uses disassociate-iam-instance-profile for Detach' {
            $script:capturedArgs = $null
            Mock -ModuleName AwsManager Invoke-AwsCli {
                $script:capturedArgs = $Arguments
                [PSCustomObject]@{ ExitCode = 0; Output = '{}'; Success = $true }
            }

            Set-InstanceProfileAssociation -Profile 'dev' -InstanceId 'i-1' -Action Detach -AssociationId 'iip-assoc-123' | Should -BeTrue
            $script:capturedArgs | Should -Contain 'disassociate-iam-instance-profile'
            $script:capturedArgs | Should -Contain 'iip-assoc-123'
        }

        It 'uses replace-iam-instance-profile-association for Replace' {
            $script:capturedArgs = $null
            Mock -ModuleName AwsManager Invoke-AwsCli {
                $script:capturedArgs = $Arguments
                [PSCustomObject]@{ ExitCode = 0; Output = '{}'; Success = $true }
            }

            Set-InstanceProfileAssociation -Profile 'dev' -InstanceId 'i-1' -Action Replace -AssociationId 'iip-assoc-123' -InstanceProfileName 'next-profile' | Should -BeTrue
            $script:capturedArgs | Should -Contain 'replace-iam-instance-profile-association'
            $script:capturedArgs | Should -Contain 'Name=next-profile'
        }
    }

    Context 'ConvertFrom-MinimalYaml' {
        It 'parses basic key/value and script: | block' {
            $yaml = "name: foo`noutput: text`nscript: |`n  echo hello"
            $r = ConvertFrom-MinimalYaml -Text $yaml
            $r['name'] | Should -Be 'foo'
            $r['output'] | Should -Be 'text'
            ($r['script'].TrimEnd("`n")) | Should -Be 'echo hello'
        }

        It 'coerces timeout to int and parses description' {
            $yaml = "name: bar`ndescription: a task`ntimeout: 120`nscript: |`n  ls"
            $r = ConvertFrom-MinimalYaml -Text $yaml
            $r['description'] | Should -Be 'a task'
            $r['timeout'] | Should -Be 120
            ($r['timeout']) -is [int] | Should -BeTrue
        }

        It 'throws on an unrecognized top-level line instead of silently dropping it' {
            # インデント崩れ等でキーが欠落したまま「script」だけは非空、という
            # サイレントな部分実行を防ぐため、認識できない行はエラーにする。
            $yaml = "name: foo`n- bad line`noutput: text`nscript: |`n  echo hi"
            { ConvertFrom-MinimalYaml -Text $yaml } | Should -Throw '*bad line*'
        }
    }

    Context 'Invoke-SsmTask - YAML parsing' {
        It 'parses top-level keys and script block (text output)' {
            $yaml = @'
name: hello
description: A test task
output: text
platform: Linux
timeout: 60
script: |
  echo hi
  uname -a
'@
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $yaml -Encoding UTF8

            $sendResp = '{ "Command": { "CommandId": "cmd-abc" } }'
            $invResp = '{ "Status": "Success", "StandardOutputContent": "hi", "StandardErrorContent": "" }'

            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'send-command'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = $sendResp; Success = $true }
            }
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'get-command-invocation'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = $invResp; Success = $true }
            }

            $r = Invoke-SsmTask -Profile 'dev' -InstanceId 'i-1' -YamlPath $tmp
            $r.Status | Should -Be 'Success'
            $r.Output | Should -Be 'hi'
            $r.OutputType | Should -Be 'text'

            Remove-Item -LiteralPath $tmp -Force
        }

        It 'detects html output type' {
            $yaml = @'
name: html-task
output: html
platform: Windows
script: |
  Write-Output '<b>x</b>'
'@
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $yaml -Encoding UTF8

            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'send-command'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = '{ "Command": { "CommandId": "c1" } }'; Success = $true }
            }
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'get-command-invocation'
            } -MockWith {
                [PSCustomObject]@{
                    ExitCode = 0
                    Output = '{ "Status": "Success", "StandardOutputContent": "<b>x</b>", "StandardErrorContent": "" }'
                    Success = $true
                }
            }

            $r = Invoke-SsmTask -Profile 'dev' -InstanceId 'i-1' -YamlPath $tmp
            $r.OutputType | Should -Be 'html'

            Remove-Item -LiteralPath $tmp -Force
        }

        It 'includes stderr when send-command fails' {
            $yaml = @'
name: fail-send
platform: Linux
script: |
  echo hi
'@
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $yaml -Encoding UTF8

            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'send-command'
            } -MockWith {
                [PSCustomObject]@{
                    ExitCode = 254
                    Output = ''
                    Stderr = 'An error occurred (InvalidInstanceId) when calling the SendCommand operation'
                    Success = $false
                }
            }

            { Invoke-SsmTask -Profile 'dev' -InstanceId 'i-1' -YamlPath $tmp } | Should -Throw '*InvalidInstanceId*'

            Remove-Item -LiteralPath $tmp -Force
        }

        It 'picks AWS-RunPowerShellScript for Windows platform' {
            $yaml = @'
name: win
platform: Windows
script: |
  Get-Date
'@
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $yaml -Encoding UTF8

            $script:doc = $null
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'send-command'
            } -MockWith {
                $i = [Array]::IndexOf($Arguments, '--document-name')
                $script:doc = $Arguments[$i + 1]
                [PSCustomObject]@{ ExitCode = 0; Output = '{ "Command": { "CommandId": "c1" } }'; Success = $true }
            }
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'get-command-invocation'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = '{ "Status": "Success", "StandardOutputContent": "", "StandardErrorContent": "" }'; Success = $true }
            }

            Invoke-SsmTask -Profile 'dev' -InstanceId 'i-1' -YamlPath $tmp | Out-Null
            $script:doc | Should -Be 'AWS-RunPowerShellScript'

            Remove-Item -LiteralPath $tmp -Force
        }
    }

    Context 'Invoke-SsmTask - polling' {
        It 'polls until status transitions from InProgress to Success' {
            $yaml = @'
name: poll-test
platform: Linux
script: |
  echo done
'@
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $yaml -Encoding UTF8

            Mock -ModuleName AwsManager Start-Sleep { }

            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'send-command'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = '{ "Command": { "CommandId": "c2" } }'; Success = $true }
            }

            $script:pollCount = 0
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'get-command-invocation'
            } -MockWith {
                $script:pollCount++
                if ($script:pollCount -lt 2) {
                    [PSCustomObject]@{ ExitCode = 0; Output = '{ "Status": "InProgress" }'; Success = $true }
                }
                else {
                    [PSCustomObject]@{
                        ExitCode = 0
                        Output = '{ "Status": "Success", "StandardOutputContent": "done", "StandardErrorContent": "" }'
                        Success = $true
                    }
                }
            }

            $r = Invoke-SsmTask -Profile 'dev' -InstanceId 'i-1' -YamlPath $tmp
            $r.Status | Should -Be 'Success'
            $r.Output | Should -Be 'done'
            $script:pollCount | Should -BeGreaterOrEqual 2

            Remove-Item -LiteralPath $tmp -Force
        }

        It 'returns TimedOut when polling exceeds timeout' {
            $yaml = @'
name: slow
platform: Linux
timeout: 1
script: |
  sleep 100
'@
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $yaml -Encoding UTF8

            Mock -ModuleName AwsManager Start-Sleep { }

            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'send-command'
            } -MockWith {
                [PSCustomObject]@{ ExitCode = 0; Output = '{ "Command": { "CommandId": "c3" } }'; Success = $true }
            }
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'get-command-invocation'
            } -MockWith {
                # Simulate elapsed time by sleeping in the real clock briefly
                Start-Sleep -Milliseconds 1100
                [PSCustomObject]@{ ExitCode = 0; Output = '{ "Status": "InProgress" }'; Success = $true }
            }
            $script:cancelArgs = $null
            Mock -ModuleName AwsManager Invoke-AwsCli -ParameterFilter {
                $Arguments -contains 'cancel-command'
            } -MockWith {
                $script:cancelArgs = $Arguments
                [PSCustomObject]@{ ExitCode = 0; Output = '{}'; Success = $true }
            }

            $r = Invoke-SsmTask -Profile 'dev' -InstanceId 'i-1' -YamlPath $tmp
            $r.Status | Should -Be 'TimedOut'
            $r.Error | Should -Match 'キャンセルを要求しました'

            # タイムアウト時にリモート側のコマンドもキャンセルを試みること
            $script:cancelArgs | Should -Not -BeNullOrEmpty
            $script:cancelArgs | Should -Contain 'c3'
            $script:cancelArgs | Should -Contain 'i-1'

            Remove-Item -LiteralPath $tmp -Force
        }
    }
}
