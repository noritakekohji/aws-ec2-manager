#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'AwsManager' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\AwsManager.psm1')).Path
        Import-Module $script:ModulePath -Force
    }

    AfterAll {
        Remove-Module AwsManager -ErrorAction SilentlyContinue
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
          "Tags": []
        }
      ]
    }
  ]
}
'@
            Mock -ModuleName AwsManager Invoke-AwsCli {
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

            $b = $list[1]
            $b.InstanceId | Should -Be 'i-bbb'
            $b.Name | Should -Be ''
            $b.Platform | Should -Be 'Linux'
            $b.PublicIpAddress | Should -BeNullOrEmpty
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

        It 'returns false when aws cli fails' {
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 255; Output = 'err'; Success = $false }
            }
            Start-Ec2Instance -Profile 'dev' -InstanceId 'i-bad' | Should -BeFalse
        }
    }

    Context 'Get-VpcSecurityGroups' {
        It 'parses describe-security-groups JSON' {
            $fake = @'
{ "SecurityGroups": [
    { "GroupId": "sg-1", "GroupName": "web", "Description": "web tier" },
    { "GroupId": "sg-2", "GroupName": "db",  "Description": "db tier"  }
]}
'@
            Mock -ModuleName AwsManager Invoke-AwsCli {
                [PSCustomObject]@{ ExitCode = 0; Output = $fake; Success = $true }
            }
            $sgs = Get-VpcSecurityGroups -Profile 'dev' -VpcId 'vpc-1'
            $sgs.Count | Should -Be 2
            $sgs[0].GroupId | Should -Be 'sg-1'
            $sgs[1].GroupName | Should -Be 'db'
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

            $r = Invoke-SsmTask -Profile 'dev' -InstanceId 'i-1' -YamlPath $tmp
            $r.Status | Should -Be 'TimedOut'

            Remove-Item -LiteralPath $tmp -Force
        }
    }
}
