<#
.SYNOPSIS
    AWS EC2 / Security Group / SSM operations module.
.DESCRIPTION
    Wraps the aws CLI to expose EC2 lifecycle, security group, and SSM Run Command
    operations as PowerShell functions. All functions take a -Profile parameter
    that maps to `aws --profile <name>`.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Invoke-AwsCli {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$LogCallback = $null
    )

    $combined = & aws @Arguments 2>&1
    $exitCode = [int]$LASTEXITCODE

    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $combined) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $stderrLines.Add($item.ToString())
        } else {
            $stdoutLines.Add([string]$item)
        }
    }

    $joined       = if ($stdoutLines.Count -eq 0) { '' } else { ($stdoutLines.ToArray() -join [Environment]::NewLine) }
    $stderrJoined = if ($stderrLines.Count -eq 0)  { '' } else { ($stderrLines.ToArray()  -join [Environment]::NewLine) }

    if ($null -ne $LogCallback) {
        $argStr = ($Arguments -join ' ')
        & $LogCallback "aws $argStr"
        if (-not [string]::IsNullOrWhiteSpace($stderrJoined)) {
            & $LogCallback "[STDERR] $stderrJoined"
        }
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $joined
        Stderr   = $stderrJoined
        Success  = ($exitCode -eq 0)
    }
}

function Get-TagValue {
    param(
        $Tags,
        [string]$Key
    )
    if ($null -eq $Tags) { return '' }
    foreach ($t in $Tags) {
        if ($t.Key -eq $Key) { return [string]$t.Value }
    }
    return ''
}

function Get-SsmInstanceInformation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns multiple SSM managed instance records by API design.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Profile
    )

    $map = @{}
    $result = Invoke-AwsCli -Arguments @('ssm', 'describe-instance-information', '--profile', $Profile, '--output', 'json')
    if (-not $result.Success) {
        return $map
    }
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return $map
    }

    $parsed = $result.Output | ConvertFrom-Json
    if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'InstanceInformationList')) {
        return $map
    }

    foreach ($info in $parsed.InstanceInformationList) {
        if ($null -eq $info -or -not ($info.PSObject.Properties.Name -contains 'InstanceId')) { continue }
        $id = [string]$info.InstanceId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $map[$id] = [PSCustomObject]@{
            InstanceId       = $id
            PingStatus       = if ($info.PSObject.Properties.Name -contains 'PingStatus') { [string]$info.PingStatus } else { '' }
            AgentVersion     = if ($info.PSObject.Properties.Name -contains 'AgentVersion') { [string]$info.AgentVersion } else { '' }
            PlatformName     = if ($info.PSObject.Properties.Name -contains 'PlatformName') { [string]$info.PlatformName } else { '' }
            PlatformVersion  = if ($info.PSObject.Properties.Name -contains 'PlatformVersion') { [string]$info.PlatformVersion } else { '' }
            LastPingDateTime = if ($info.PSObject.Properties.Name -contains 'LastPingDateTime') { [string]$info.LastPingDateTime } else { '' }
        }
    }

    return $map
}

function Get-Ec2Instances {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns multiple instances by design.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Profile
    )

    $ssmInfoById = Get-SsmInstanceInformation -Profile $Profile

    $result = Invoke-AwsCli -Arguments @('ec2', 'describe-instances', '--profile', $Profile, '--output', 'json')
    if (-not $result.Success) {
        $errDetail = if ([string]::IsNullOrWhiteSpace($result.Stderr)) { $result.Output } else { $result.Stderr }
        Write-Error "aws ec2 describe-instances failed: $errDetail"
        return , @()
    }

    $items = New-Object System.Collections.Generic.List[PSCustomObject]
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return , ($items.ToArray())
    }

    $parsed = $result.Output | ConvertFrom-Json
    if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'Reservations')) {
        return , ($items.ToArray())
    }

    foreach ($reservation in $parsed.Reservations) {
        foreach ($inst in $reservation.Instances) {
            $tags = $null
            if ($inst.PSObject.Properties.Name -contains 'Tags') { $tags = $inst.Tags }

            $name = Get-TagValue -Tags $tags -Key 'Name'

            $publicIp = $null
            if (($inst.PSObject.Properties.Name -contains 'PublicIpAddress') -and -not [string]::IsNullOrEmpty([string]$inst.PublicIpAddress)) {
                $publicIp = [string]$inst.PublicIpAddress
            }

            $platform = 'Linux'
            if (($inst.PSObject.Properties.Name -contains 'Platform') -and ("$($inst.Platform)".ToLower() -eq 'windows')) {
                $platform = 'Windows'
            }

            $az = $null
            if ($inst.PSObject.Properties.Name -contains 'Placement' -and $null -ne $inst.Placement) {
                if ($inst.Placement.PSObject.Properties.Name -contains 'AvailabilityZone') {
                    $az = [string]$inst.Placement.AvailabilityZone
                }
            }

            $state = $null
            if ($inst.PSObject.Properties.Name -contains 'State' -and $null -ne $inst.State) {
                if ($inst.State.PSObject.Properties.Name -contains 'Name') {
                    $state = [string]$inst.State.Name
                }
            }

            $sgIds = New-Object System.Collections.Generic.List[string]
            $sgNames = New-Object System.Collections.Generic.List[string]
            if ($inst.PSObject.Properties.Name -contains 'SecurityGroups' -and $null -ne $inst.SecurityGroups) {
                foreach ($sg in $inst.SecurityGroups) {
                    if ($null -ne $sg -and ($sg.PSObject.Properties.Name -contains 'GroupId')) {
                        $sgIds.Add([string]$sg.GroupId)
                    }
                    if ($null -ne $sg -and ($sg.PSObject.Properties.Name -contains 'GroupName')) {
                        $sgNames.Add([string]$sg.GroupName)
                    }
                }
            }

            $instanceId = [string]$inst.InstanceId
            $ssmInfo = $null
            if ($ssmInfoById.ContainsKey($instanceId)) {
                $ssmInfo = $ssmInfoById[$instanceId]
            }
            $ssmPing = ''
            $ssmAgent = ''
            $ssmPlatform = ''
            $ssmPlatformVersion = ''
            $ssmLastPing = ''
            if ($null -ne $ssmInfo) {
                $ssmPing = [string]$ssmInfo.PingStatus
                $ssmAgent = [string]$ssmInfo.AgentVersion
                $ssmPlatform = [string]$ssmInfo.PlatformName
                $ssmPlatformVersion = [string]$ssmInfo.PlatformVersion
                $ssmLastPing = [string]$ssmInfo.LastPingDateTime
            }
            $ssmStatus = if ([string]::IsNullOrWhiteSpace($ssmPing)) { '未登録' } else { $ssmPing }

            $iamArn = ''
            if ($inst.PSObject.Properties.Name -contains 'IamInstanceProfile' -and $null -ne $inst.IamInstanceProfile) {
                if ($inst.IamInstanceProfile.PSObject.Properties.Name -contains 'Arn') {
                    $iamArn = [string]$inst.IamInstanceProfile.Arn
                }
            }
            $iamName = ''
            if (-not [string]::IsNullOrWhiteSpace($iamArn)) {
                $iamName = ($iamArn -split '/')[-1]
            }

            $items.Add([PSCustomObject]@{
                Name              = $name
                InstanceId        = $instanceId
                State             = $state
                InstanceType      = [string]$inst.InstanceType
                AvailabilityZone  = $az
                PrivateIpAddress  = if ($inst.PSObject.Properties.Name -contains 'PrivateIpAddress') { [string]$inst.PrivateIpAddress } else { $null }
                PublicIpAddress   = $publicIp
                Platform          = $platform
                VpcId             = if ($inst.PSObject.Properties.Name -contains 'VpcId') { [string]$inst.VpcId } else { $null }
                SubnetId          = if ($inst.PSObject.Properties.Name -contains 'SubnetId') { [string]$inst.SubnetId } else { $null }
                ImageId           = if ($inst.PSObject.Properties.Name -contains 'ImageId') { [string]$inst.ImageId } else { $null }
                KeyName           = if ($inst.PSObject.Properties.Name -contains 'KeyName') { [string]$inst.KeyName } else { $null }
                LaunchTime        = if ($inst.PSObject.Properties.Name -contains 'LaunchTime') { [string]$inst.LaunchTime } else { $null }
                RootDeviceName    = if ($inst.PSObject.Properties.Name -contains 'RootDeviceName') { [string]$inst.RootDeviceName } else { $null }
                IamInstanceProfile = $iamName
                IamInstanceProfileArn = $iamArn
                SecurityGroupIds  = [string[]]$sgIds.ToArray()
                SecurityGroupNames = [string[]]$sgNames.ToArray()
                SsmStatus         = $ssmStatus
                SsmPingStatus     = $ssmPing
                SsmAgentVersion   = $ssmAgent
                SsmPlatformName   = $ssmPlatform
                SsmPlatformVersion = $ssmPlatformVersion
                SsmLastPingDateTime = $ssmLastPing
            })
        }
    }

    return , ($items.ToArray())
}

function Start-Ec2Instance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )
    if (-not $PSCmdlet.ShouldProcess($InstanceId, 'Start EC2 instance')) { return $false }
    $r = Invoke-AwsCli -Arguments @('ec2', 'start-instances', '--profile', $Profile, '--instance-ids', $InstanceId, '--output', 'json')
    return $r.Success
}

function Stop-Ec2Instance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )
    if (-not $PSCmdlet.ShouldProcess($InstanceId, 'Stop EC2 instance')) { return $false }
    $r = Invoke-AwsCli -Arguments @('ec2', 'stop-instances', '--profile', $Profile, '--instance-ids', $InstanceId, '--output', 'json')
    return $r.Success
}

function Restart-Ec2Instance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )
    if (-not $PSCmdlet.ShouldProcess($InstanceId, 'Reboot EC2 instance')) { return $false }
    $r = Invoke-AwsCli -Arguments @('ec2', 'reboot-instances', '--profile', $Profile, '--instance-ids', $InstanceId, '--output', 'json')
    return $r.Success
}

function Get-VpcSecurityGroups {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns multiple security groups by design.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$VpcId
    )

    $r = Invoke-AwsCli -Arguments @(
        'ec2', 'describe-security-groups',
        '--profile', $Profile,
        '--filters', "Name=vpc-id,Values=$VpcId",
        '--output', 'json'
    )

    if (-not $r.Success) {
        $errDetail = if ([string]::IsNullOrWhiteSpace($r.Stderr)) { $r.Output } else { $r.Stderr }
        Write-Error "aws ec2 describe-security-groups failed: $errDetail"
        return , @()
    }

    $list = New-Object System.Collections.Generic.List[PSCustomObject]
    if ([string]::IsNullOrWhiteSpace($r.Output)) { return , ($list.ToArray()) }

    $parsed = $r.Output | ConvertFrom-Json
    if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'SecurityGroups')) {
        return , ($list.ToArray())
    }

    foreach ($sg in $parsed.SecurityGroups) {
        $list.Add([PSCustomObject]@{
            GroupId              = [string]$sg.GroupId
            GroupName            = [string]$sg.GroupName
            Description          = [string]$sg.Description
            VpcId                = [string]$sg.VpcId
            IpPermissions        = @($sg.IpPermissions)
            IpPermissionsEgress  = @($sg.IpPermissionsEgress)
        })
    }
    return , ($list.ToArray())
}

function Set-InstanceSecurityGroups {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Operates on multiple security groups (plural) by API design.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string[]]$GroupIds
    )

    if (-not $PSCmdlet.ShouldProcess($InstanceId, "Set security groups: $($GroupIds -join ',')")) { return $false }

    $cliArgs = New-Object System.Collections.Generic.List[string]
    $cliArgs.Add('ec2'); $cliArgs.Add('modify-instance-attribute')
    $cliArgs.Add('--profile'); $cliArgs.Add($Profile)
    $cliArgs.Add('--instance-id'); $cliArgs.Add($InstanceId)
    $cliArgs.Add('--groups')
    foreach ($g in $GroupIds) { $cliArgs.Add($g) }

    $r = Invoke-AwsCli -Arguments $cliArgs.ToArray()
    return $r.Success
}

function ConvertFrom-MinimalYaml {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$Text
    )

    $result = @{}
    $lines = $Text -split "`r?`n"
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        # skip blank/comment
        if ($line -match '^\s*$' -or $line -match '^\s*#') {
            $i++; continue
        }

        # top-level key: value or key: |
        $m = [regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$')
        if (-not $m.Success) {
            $i++; continue
        }
        $key = $m.Groups[1].Value
        $val = $m.Groups[2].Value

        if ($val -eq '|' -or $val -eq '|-' -or $val -eq '|+') {
            # collect indented block
            $i++
            $blockLines = New-Object System.Collections.Generic.List[string]
            $indent = -1
            while ($i -lt $lines.Count) {
                $bl = $lines[$i]
                if ($bl -match '^\s*$') {
                    $blockLines.Add('')
                    $i++; continue
                }
                $leading = ($bl -replace '^(\s*).*$', '$1').Length
                if ($leading -eq 0) { break }
                if ($indent -lt 0) { $indent = $leading }
                if ($leading -lt $indent) { break }
                $blockLines.Add($bl.Substring([Math]::Min($indent, $bl.Length)))
                $i++
            }
            # trim trailing empties
            while ($blockLines.Count -gt 0 -and $blockLines[$blockLines.Count - 1] -eq '') {
                $blockLines.RemoveAt($blockLines.Count - 1)
            }
            $result[$key] = ($blockLines -join "`n")
            continue
        }
        else {
            # strip quotes
            $sval = $val.Trim()
            if ($sval.Length -ge 2) {
                $first = $sval[0]; $last = $sval[$sval.Length - 1]
                if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                    $sval = $sval.Substring(1, $sval.Length - 2)
                }
            }
            # numeric coerce for timeout
            if ($key -eq 'timeout' -and $sval -match '^\d+$') {
                $result[$key] = [int]$sval
            }
            else {
                $result[$key] = $sval
            }
            $i++
        }
    }
    return $result
}

function Invoke-SsmTask {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$YamlPath,
        [ValidateSet('Linux', 'Windows')]
        [string]$Platform,
        [Parameter()]
        [AllowNull()]
        [scriptblock]$StatusCallback = $null
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw "YAML file not found: $YamlPath"
    }

    # YAML は UTF-8 (BOM なし) 想定。PS 5.1 既定の CP932 で読むと日本語が文字化けするので明示
    $yamlText = Get-Content -LiteralPath $YamlPath -Raw -Encoding UTF8 -ErrorAction Stop
    $task = ConvertFrom-MinimalYaml -Text $yamlText

    $script = if ($task.ContainsKey('script')) { [string]$task['script'] } else { '' }
    if ([string]::IsNullOrEmpty($script)) {
        throw "YAML is missing required 'script' field: $YamlPath"
    }

    $outputType = 'text'
    if ($task.ContainsKey('output') -and -not [string]::IsNullOrEmpty([string]$task['output'])) {
        $outputType = [string]$task['output']
    }

    $timeoutSec = 300
    if ($task.ContainsKey('timeout')) {
        $t = $task['timeout']
        if ($t -is [int]) { $timeoutSec = $t }
        elseif ($t -match '^\d+$') { $timeoutSec = [int]$t }
    }

    $effectivePlatform = $Platform
    if ($task.ContainsKey('platform') -and -not [string]::IsNullOrEmpty([string]$task['platform'])) {
        $effectivePlatform = [string]$task['platform']
    }
    if ([string]::IsNullOrEmpty($effectivePlatform)) {
        throw "Platform not specified in YAML or via -Platform parameter."
    }

    $document = if ($effectivePlatform -eq 'Windows') { 'AWS-RunPowerShellScript' } else { 'AWS-RunShellScript' }

    $paramJson = (@{ commands = @($script) } | ConvertTo-Json -Compress -Depth 5)
    $awsTimeoutArgs = @('--cli-connect-timeout', '10', '--cli-read-timeout', '30')

    $sendArgs = @(
        'ssm', 'send-command',
        '--profile', $Profile,
        '--instance-ids', $InstanceId,
        '--document-name', $document,
        '--parameters', $paramJson,
        '--output', 'json'
    )
    $sendArgs += $awsTimeoutArgs
    $sendResult = Invoke-AwsCli -Arguments $sendArgs
    if (-not $sendResult.Success) {
        throw "aws ssm send-command failed: $($sendResult.Output)"
    }

    $sendObj = $sendResult.Output | ConvertFrom-Json
    $commandId = [string]$sendObj.Command.CommandId

    $startTime = Get-Date
    $finalStatus = $null
    $lastStatus = 'Pending'
    $lastError = ''
    $stdout = ''
    $stderr = ''
    $pollCount = 0

    if ($null -ne $StatusCallback) {
        & $StatusCallback "CommandId: $commandId`nStatus: Pending`nElapsed: 0s / Timeout: ${timeoutSec}s"
    }

    while ($true) {
        $pollCount++
        $elapsed = (Get-Date) - $startTime
        if ($null -ne $StatusCallback) {
            & $StatusCallback "CommandId: $commandId`nStatus: $lastStatus`nElapsed: $([int]$elapsed.TotalSeconds)s / Timeout: ${timeoutSec}s`nPolling: #$pollCount"
        }

        $invArgs = @(
            'ssm', 'get-command-invocation',
            '--profile', $Profile,
            '--command-id', $commandId,
            '--instance-id', $InstanceId,
            '--output', 'json'
        )
        $invArgs += $awsTimeoutArgs
        $invResult = Invoke-AwsCli -Arguments $invArgs

        if ($invResult.Success -and -not [string]::IsNullOrWhiteSpace($invResult.Output)) {
            $inv = $invResult.Output | ConvertFrom-Json
            $status = [string]$inv.Status
            $lastStatus = $status
            if ($status -ne 'InProgress' -and $status -ne 'Pending') {
                $finalStatus = $status
                if ($inv.PSObject.Properties.Name -contains 'StandardOutputContent') {
                    $stdout = [string]$inv.StandardOutputContent
                }
                if ($inv.PSObject.Properties.Name -contains 'StandardErrorContent') {
                    $stderr = [string]$inv.StandardErrorContent
                }
                break
            }
        }
        elseif (-not $invResult.Success) {
            if (-not [string]::IsNullOrWhiteSpace($invResult.Stderr)) {
                $lastError = [string]$invResult.Stderr
            }
            else {
                $lastError = [string]$invResult.Output
            }
        }

        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -ge $timeoutSec) {
            $finalStatus = 'TimedOut'
            if ([string]::IsNullOrWhiteSpace($stderr)) {
                $stderr = "Timed out after ${timeoutSec}s while waiting for SSM command $commandId. Last status: $lastStatus"
                if (-not [string]::IsNullOrWhiteSpace($lastError)) {
                    $stderr = "$stderr`nLast AWS CLI error: $lastError"
                }
            }
            break
        }
        Start-Sleep -Seconds 2
    }

    $duration = (Get-Date) - $startTime
    $normalized = switch ($finalStatus) {
        'Success'  { 'Success' }
        'Failed'   { 'Failed' }
        'TimedOut' { 'TimedOut' }
        default    { 'Failed' }
    }

    return [PSCustomObject]@{
        Status     = $normalized
        Output     = $stdout
        Error      = $stderr
        OutputType = $outputType
        Duration   = $duration
        CommandId  = $commandId
    }
}

Export-ModuleMember -Function Get-Ec2Instances, Get-SsmInstanceInformation, Start-Ec2Instance, Stop-Ec2Instance, Restart-Ec2Instance, Get-VpcSecurityGroups, Set-InstanceSecurityGroups, Invoke-SsmTask, ConvertFrom-MinimalYaml
