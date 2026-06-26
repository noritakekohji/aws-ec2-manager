<#
.SYNOPSIS
    Activity logging module for aws-ec2-manager.
.DESCRIPTION
    Write-AppLog appends timestamped lines to a log file.
    Call Initialize-AppLogger at startup with the path from AppSettings.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

$script:LogFilePath = $null

function Initialize-AppLogger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets module-scope variable only; no system state change.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $script:LogFilePath = $null
        return
    }
    $script:LogFilePath = $LogPath
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

Export-ModuleMember -Function Initialize-AppLogger, Write-AppLog
