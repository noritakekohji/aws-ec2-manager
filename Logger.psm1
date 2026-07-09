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

function Remove-OldAppLogFolder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Best-effort startup cleanup; failures are swallowed intentionally so logging still works.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [int]$RetentionDays = 30
    )

    if ($RetentionDays -le 0) { return }
    if (-not (Test-Path -LiteralPath $LogRoot)) { return }

    $cutoff = (Get-Date).Date.AddDays(-$RetentionDays)
    $dateFolders = Get-ChildItem -LiteralPath $LogRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }

    foreach ($folder in @($dateFolders)) {
        $folderDate = [DateTime]::MinValue
        $parsed = [DateTime]::TryParseExact(
            $folder.Name, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$folderDate
        )
        if (-not $parsed -or $folderDate -ge $cutoff) { continue }

        try {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            # 保持期間切れログの削除失敗はアプリ動作を止めない（次回起動時に再試行される）
        }
    }
}

function Initialize-AppLogger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets module-scope variable only; no system state change.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath,

        # ログ出力先フォルダに yyyy-MM-dd フォルダが無期限に溜まり続けるのを防ぐため、
        # 起動のたびに保持日数を超えた過去フォルダを削除する。
        [int]$LogRetentionDays = 30
    )

    $root = $LogPath
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-DefaultAppLogRoot
    }
    $script:LogRootPath = $root
    $script:LogDirectoryPath = Join-Path $script:LogRootPath (Get-Date -Format 'yyyy-MM-dd')
    $script:LogFilePath = Join-Path $script:LogDirectoryPath 'app.log'

    try {
        Remove-OldAppLogFolder -LogRoot $root -RetentionDays $LogRetentionDays
    }
    catch {
        # クリーンアップの失敗はロガー自体の初期化を妨げない
    }
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

Export-ModuleMember -Function Initialize-AppLogger, Write-AppLog, Get-AppLogDirectory, Remove-OldAppLogFolder
