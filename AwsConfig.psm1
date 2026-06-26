<#
.SYNOPSIS
    AWS profile management module.
.DESCRIPTION
    Reads ~/.aws/config and returns profile list / detail / SSO token status.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Get-DefaultConfigPath {
    # AWS CLI と同様、$env:AWS_CONFIG_FILE があれば優先する
    if (-not [string]::IsNullOrWhiteSpace($env:AWS_CONFIG_FILE)) {
        return $env:AWS_CONFIG_FILE
    }
    return (Join-Path $env:USERPROFILE '.aws/config')
}

function Read-IniSections {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns multiple sections by design.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $currentSection = $null
    $lines = Get-Content -LiteralPath $Path -ErrorAction Stop

    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }

        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $currentSection = $line.Substring(1, $line.Length - 2).Trim()
            if (-not $result.Contains($currentSection)) {
                $result[$currentSection] = [ordered]@{}
            }
            continue
        }

        if ($null -eq $currentSection) { continue }

        $eqIndex = $line.IndexOf('=')
        if ($eqIndex -lt 1) { continue }

        $key = $line.Substring(0, $eqIndex).Trim()
        $value = $line.Substring($eqIndex + 1).Trim()
        $result[$currentSection][$key] = $value
    }

    return $result
}

function Get-AwsProfiles {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns multiple profile names by design.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$ConfigPath = (Get-DefaultConfigPath)
    )

    $names = New-Object System.Collections.Generic.List[string]
    $sections = Read-IniSections -Path $ConfigPath

    foreach ($sectionName in $sections.Keys) {
        if ($sectionName -eq 'default') {
            $names.Add('default')
        }
        elseif ($sectionName -like 'profile *') {
            $name = $sectionName.Substring('profile '.Length).Trim()
            if (-not [string]::IsNullOrEmpty($name)) {
                $names.Add($name)
            }
        }
    }

    return , ($names.ToArray())
}

function Get-AwsProfileDetail {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$ConfigPath = (Get-DefaultConfigPath)
    )

    $sections = Read-IniSections -Path $ConfigPath

    $sectionKey = if ($Name -eq 'default') { 'default' } else { "profile $Name" }
    if (-not $sections.Contains($sectionKey)) {
        return $null
    }

    $sec = $sections[$sectionKey]

    $ssoStartUrl = $null
    $region = $null
    $ssoAccountId = $null

    if ($sec.Contains('sso_start_url')) { $ssoStartUrl = $sec['sso_start_url'] }
    if ($sec.Contains('region')) { $region = $sec['region'] }
    if ($sec.Contains('sso_account_id')) { $ssoAccountId = $sec['sso_account_id'] }

    # AWS CLI v2 形式: profile が sso_session を参照している場合、
    # 実際の sso_start_url は [sso-session <name>] ブロックにある
    if ($null -eq $ssoStartUrl -and $sec.Contains('sso_session')) {
        $sessionKey = 'sso-session ' + $sec['sso_session']
        if ($sections.Contains($sessionKey) -and $sections[$sessionKey].Contains('sso_start_url')) {
            $ssoStartUrl = $sections[$sessionKey]['sso_start_url']
        }
    }

    return [PSCustomObject]@{
        Name         = $Name
        SsoStartUrl  = $ssoStartUrl
        Region       = $region
        SsoAccountId = $ssoAccountId
    }
}

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

function Test-SsoToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (Invoke-AwsCli -Arguments @('sts', 'get-caller-identity', '--profile', $Name, '--output', 'json')).Success
}

Export-ModuleMember -Function Get-AwsProfiles, Get-AwsProfileDetail, Test-SsoToken