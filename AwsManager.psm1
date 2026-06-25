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
        [string[]]$Arguments
    )

    $output = & aws @Arguments
    $exitCode = [int]$LASTEXITCODE
    $joined = if ($null -eq $output) { '' } else { ($output -join [Environment]::NewLine) }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $joined
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

function Get-Ec2Instances {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns multiple instances by design.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Profile
    )

    $result = Invoke-AwsCli -Arguments @('ec2', 'describe-instances', '--profile', $Profile, '--output', 'json')
    if (-not $result.Success) {
        Write-Error "aws ec2 describe-instances failed: $($result.Output)"
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
            if ($inst.PSObject.Properties.Name -contains 'SecurityGroups' -and $null -ne $inst.SecurityGroups) {
                foreach ($sg in $inst.SecurityGroups) {
                    if ($null -ne $sg -and ($sg.PSObject.Properties.Name -contains 'GroupId')) {
                        $sgIds.Add([string]$sg.GroupId)
                    }
                }
            }

            $items.Add([PSCustomObject]@{
                Name              = $name
                InstanceId        = [string]$inst.InstanceId
                State             = $state
                InstanceType      = [string]$inst.InstanceType
                AvailabilityZone  = $az
                PrivateIpAddress  = if ($inst.PSObject.Properties.Name -contains 'PrivateIpAddress') { [string]$inst.PrivateIpAddress } else { $null }
                PublicIpAddress   = $publicIp
                Platform          = $platform
                VpcId             = if ($inst.PSObject.Properties.Name -contains 'VpcId') { [string]$inst.VpcId } else { $null }
                SecurityGroupIds  = [string[]]$sgIds.ToArray()
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
        Write-Error "aws ec2 describe-security-groups failed: $($r.Output)"
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
            GroupId     = [string]$sg.GroupId
            GroupName   = [string]$sg.GroupName
            Description = [string]$sg.Description
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
        [string]$Platform
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw "YAML file not found: $YamlPath"
    }

    $yamlText = Get-Content -LiteralPath $YamlPath -Raw -ErrorAction Stop
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

    $sendArgs = @(
        'ssm', 'send-command',
        '--profile', $Profile,
        '--instance-ids', $InstanceId,
        '--document-name', $document,
        '--parameters', $paramJson,
        '--output', 'json'
    )
    $sendResult = Invoke-AwsCli @sendArgs
    if (-not $sendResult.Success) {
        throw "aws ssm send-command failed: $($sendResult.Output)"
    }

    $sendObj = $sendResult.Output | ConvertFrom-Json
    $commandId = [string]$sendObj.Command.CommandId

    $startTime = Get-Date
    $finalStatus = $null
    $stdout = ''
    $stderr = ''

    while ($true) {
        $invResult = Invoke-AwsCli -Arguments @(
            'ssm', 'get-command-invocation',
            '--profile', $Profile,
            '--command-id', $commandId,
            '--instance-id', $InstanceId,
            '--output', 'json'
        )

        if ($invResult.Success -and -not [string]::IsNullOrWhiteSpace($invResult.Output)) {
            $inv = $invResult.Output | ConvertFrom-Json
            $status = [string]$inv.Status
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

        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -ge $timeoutSec) {
            $finalStatus = 'TimedOut'
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
    }
}

Export-ModuleMember -Function Get-Ec2Instances, Start-Ec2Instance, Stop-Ec2Instance, Restart-Ec2Instance, Get-VpcSecurityGroups, Set-InstanceSecurityGroups, Invoke-SsmTask
