#Requires -Version 5.1
<#
.SYNOPSIS
    SMB 共有への往復ファイル転送で疎通・整合性・速度を確認する。
.DESCRIPTION
    リスト形式: <share-unc>, <username>, <expected>, <description>
      username: 空欄=統合認証 / DOMAIN\user=専用ユーザー(実行時にPW入力)
      expected: ok(転送できるはず) / ng(できないはず) / -(評価しない)
#>
[CmdletBinding()]
param(
    [string]$ShareList  = '',
    [int]$SizeMB        = 10,
    [int]$TimeoutSec    = 60,
    [string]$HtmlReport = '',
    [switch]$FailOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-ShareList([string]$Path) {
    $result = [System.Collections.Generic.List[hashtable]]::new()
    Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
        $line = ($_ -replace '#.*$', '').Trim()
        if (-not $line) { return }
        $parts = $line -split ',', 4
        $share = $parts[0].Trim()
        if (-not $share) { return }
        $user = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        $rawExp = if ($parts.Count -ge 3) { $parts[2].Trim().ToLower() } else { '-' }
        $expected = if ($rawExp -in @('ok', 'ng', '-')) { $rawExp } else { '-' }
        $desc = if ($parts.Count -ge 4) { $parts[3].Trim() } else { '' }
        if (-not $desc) { $desc = $share }
        $result.Add(@{
            share       = $share
            username    = $user
            expected    = $expected
            description = $desc
        })
    }
    return , @($result)
}

function Get-TransferEval([string]$Expected, [bool]$Success) {
    switch ($Expected) {
        'ok'    { if ($Success) { return 'OK' } else { return 'NG' } }
        'ng'    { if ($Success) { return 'NG' } else { return 'OK' } }
        default { if ($Success) { return 'OK' } else { return 'WARN' } }
    }
}

function Get-TransferSpeed([long]$Bytes, [double]$Seconds) {
    if ($Seconds -le 0) { return 0.0 }
    return [math]::Round(($Bytes / 1MB) / $Seconds, 2)
}

function Test-HashMatch([string]$A, [string]$B) {
    return ($A.ToUpperInvariant() -eq $B.ToUpperInvariant())
}

$script:CredCache = @{}

function Get-CachedCredential([string]$Username) {
    if (-not $Username) { return $null }
    if ($script:CredCache.ContainsKey($Username)) { return $script:CredCache[$Username] }
    $sec  = Read-Host -Prompt "パスワードを入力してください ($Username)" -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential($Username, $sec)
    $script:CredCache[$Username] = $cred
    return $cred
}

function Invoke-SmbRoundTrip {
    param(
        [string]$Share,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$SizeMB,
        [int]$TimeoutSec
    )
    $res = [ordered]@{
        connected = $false; uploadOk = $false; downloadOk = $false; verifyOk = $false
        upMbps = 0.0; downMbps = 0.0; cleanupWarn = $false; message = ''
    }
    $driveName = $null; $localSrc = $null; $localDst = $null; $remoteFile = $null
    try {
        if ($Credential) {
            $driveName = 'FTC' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
            New-PSDrive -Name $driveName -PSProvider FileSystem -Root $Share -Credential $Credential -ErrorAction Stop | Out-Null
            $root = "$($driveName):\"
        } else {
            if (-not (Test-Path -LiteralPath $Share)) { throw "共有にアクセスできません: $Share" }
            $root = $Share
        }
        $res.connected = $true

        $localSrc = [System.IO.Path]::GetTempFileName()
        $bytes = New-Object byte[] ($SizeMB * 1MB)
        (New-Object Random).NextBytes($bytes)
        [System.IO.File]::WriteAllBytes($localSrc, $bytes)
        $srcHash = (Get-FileHash -LiteralPath $localSrc -Algorithm SHA256).Hash

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $rand  = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $remoteFile = Join-Path $root ("conntest_${stamp}_${rand}.tmp")

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Copy-Item -LiteralPath $localSrc -Destination $remoteFile -Force -ErrorAction Stop
        $sw.Stop()
        $res.uploadOk = $true
        $res.upMbps   = Get-TransferSpeed -Bytes $bytes.LongLength -Seconds $sw.Elapsed.TotalSeconds

        $localDst = [System.IO.Path]::GetTempFileName()
        $sw.Restart()
        Copy-Item -LiteralPath $remoteFile -Destination $localDst -Force -ErrorAction Stop
        $sw.Stop()
        $res.downloadOk = $true
        $res.downMbps   = Get-TransferSpeed -Bytes $bytes.LongLength -Seconds $sw.Elapsed.TotalSeconds

        $dstHash = (Get-FileHash -LiteralPath $localDst -Algorithm SHA256).Hash
        $res.verifyOk = Test-HashMatch $srcHash $dstHash
        if (-not $res.verifyOk) { $res.message = 'ハッシュ不一致' }
    } catch {
        $res.message = $_.Exception.Message
    } finally {
        if ($remoteFile) {
            try {
                if (Test-Path -LiteralPath $remoteFile) { Remove-Item -LiteralPath $remoteFile -Force -ErrorAction Stop }
            } catch { $res.cleanupWarn = $true }
        }
        if ($localSrc -and (Test-Path -LiteralPath $localSrc)) { Remove-Item -LiteralPath $localSrc -Force -ErrorAction SilentlyContinue }
        if ($localDst -and (Test-Path -LiteralPath $localDst)) { Remove-Item -LiteralPath $localDst -Force -ErrorAction SilentlyContinue }
        if ($driveName) { Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue }
    }
    return $res
}