<#
.SYNOPSIS
    aws-ec2-manager application settings persistence.
.DESCRIPTION
    Stores user-overridable settings under %LOCALAPPDATA%\aws-ec2-manager\settings.json.
    Currently tracks AwsConfigPath (override for ~/.aws/config).
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Get-SettingsDirectory {
    return (Join-Path $env:LOCALAPPDATA 'aws-ec2-manager')
}

function Get-SettingsPath {
    return (Join-Path (Get-SettingsDirectory) 'settings.json')
}

function Get-DefaultLogRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = $env:USERPROFILE
    }
    return (Join-Path $desktop 'aws-ec2-manager-logs')
}

function Get-AppSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Settings is a domain-standard plural noun for a config object.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $defaults = [PSCustomObject]@{
        AwsConfigPath      = $null
        LogPath            = Get-DefaultLogRoot
        LockedInstanceIds  = @()
    }

    $path = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to read settings: $($_.Exception.Message). Using defaults."
        return $defaults
    }

    $configPath = $null
    if ($obj.PSObject.Properties.Name -contains 'AwsConfigPath') {
        $val = [string]$obj.AwsConfigPath
        if (-not [string]::IsNullOrWhiteSpace($val)) { $configPath = $val }
    }

    $logPath = Get-DefaultLogRoot
    if ($obj.PSObject.Properties.Name -contains 'LogPath') {
        $val = [string]$obj.LogPath
        if (-not [string]::IsNullOrWhiteSpace($val)) { $logPath = $val }
    }

    $lockedInstanceIds = @()
    if ($obj.PSObject.Properties.Name -contains 'LockedInstanceIds') {
        foreach ($id in @($obj.LockedInstanceIds)) {
            $val = [string]$id
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                $lockedInstanceIds += $val.Trim()
            }
        }
    }

    return [PSCustomObject]@{
        AwsConfigPath      = $configPath
        LogPath            = $logPath
        LockedInstanceIds  = @($lockedInstanceIds | Select-Object -Unique)
    }
}

function Save-AppSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simple file write; user-driven setting persistence.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Settings is a domain-standard plural noun for a config object.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AwsConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath,

        [AllowNull()]
        [string[]]$LockedInstanceIds
    )

    $dir = Get-SettingsDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $normalizedConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($AwsConfigPath)) { $normalizedConfig = $AwsConfigPath.Trim() }

    $normalizedLog = $null
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $normalizedLog = $LogPath.Trim() }

    $normalizedLocked = @()
    if ($PSBoundParameters.ContainsKey('LockedInstanceIds')) {
        foreach ($id in @($LockedInstanceIds)) {
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $normalizedLocked += $id.Trim()
            }
        }
    }
    else {
        $current = Get-AppSettings
        if ($null -ne $current.LockedInstanceIds) {
            $normalizedLocked = @($current.LockedInstanceIds)
        }
    }

    $obj = [PSCustomObject]@{
        AwsConfigPath      = $normalizedConfig
        LogPath            = $normalizedLog
        LockedInstanceIds  = @($normalizedLocked | Select-Object -Unique)
    }
    $json = $obj | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath (Get-SettingsPath) -Value $json -Encoding UTF8 -ErrorAction Stop
}

function Get-EffectiveAwsConfigPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Priority: settings.json AwsConfigPath > $env:AWS_CONFIG_FILE > default ~/.aws/config
    $settings = Get-AppSettings
    if (-not [string]::IsNullOrWhiteSpace($settings.AwsConfigPath)) {
        return $settings.AwsConfigPath
    }
    if (-not [string]::IsNullOrWhiteSpace($env:AWS_CONFIG_FILE)) {
        return $env:AWS_CONFIG_FILE
    }
    return (Join-Path $env:USERPROFILE '.aws/config')
}

Export-ModuleMember -Function Get-AppSettings, Save-AppSettings, Get-EffectiveAwsConfigPath, Get-SettingsPath, Get-DefaultLogRoot
