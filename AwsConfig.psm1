<#
.SYNOPSIS
    AWS profile management module.
.DESCRIPTION
    Reads ~/.aws/config and returns profile list / detail / SSO token status.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Get-DefaultConfigPath {
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

function Test-SsoToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (Invoke-AwsCli @('sts', 'get-caller-identity', '--profile', $Name, '--output', 'json')).Success
}

Export-ModuleMember -Function Get-AwsProfiles, Get-AwsProfileDetail, Test-SsoToken