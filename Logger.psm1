<#
.SYNOPSIS
    Activity logging module for aws-ec2-manager.
.DESCRIPTION
    Write-AppLog appends timestamped lines to a log file.
    Call Initialize-AppLogger at startup with the path from AppSettings.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

$script:LogRootPath = $null
$script:LogDirectoryPath = $null
$script:LogFilePath = $null

function Get-DefaultAppLogRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = $env:USERPROFILE
    }
    return (Join-Path $desktop 'aws-ec2-manager-logs')
}

function Get-AppLogDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrWhiteSpace($script:LogDirectoryPath)) {
        $root = $script:LogRootPath
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = Get-DefaultAppLogRoot
        }
        return (Join-Path $root (Get-Date -Format 'yyyy-MM-dd'))
    }
    return $script:LogDirectoryPath
}

function Initialize-AppLogger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets module-scope variable only; no system state change.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath
    )

    $root = $LogPath
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-DefaultAppLogRoot
    }
    $script:LogRootPath = $root
    $script:LogDirectoryPath = Join-Path $script:LogRootPath (Get-Date -Format 'yyyy-MM-dd')
    $script:LogFilePath = Join-Path $script:LogDirectoryPath 'app.log'
}

function Write-AppLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Not using Write-Host; file append only.')]
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($null -eq $script:LogFilePath) { return }

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"

    try {
        $dir = Split-Path -Parent $script:LogFilePath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # ログ書き込み失敗はアプリ動作を止めない
    }
}

Export-ModuleMember -Function Initialize-AppLogger, Write-AppLog, Get-AppLogDirectory
