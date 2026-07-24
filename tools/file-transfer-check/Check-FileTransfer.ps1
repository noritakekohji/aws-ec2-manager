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

function Format-ShareResult($item, $rt, [string]$eval) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("[SHARE] $($item.share)  ($($item.description))")
    $auth = if ($item.username) { $item.username } else { 'integrated (current user)' }
    $lines.Add("  Auth    : $auth")
    if ($rt.uploadOk) {
        $lines.Add(("  Upload  : OK   {0} MB, {1} MB/s" -f $rt.upMbps, $rt.upMbps))
    } else {
        $lines.Add("  Upload  : NG   $($rt.message)")
    }
    if ($rt.downloadOk) {
        $lines.Add(("  Download: OK   {0} MB/s" -f $rt.downMbps))
    } elseif ($rt.uploadOk) {
        $lines.Add("  Download: NG   $($rt.message)")
    }
    if ($rt.uploadOk -and $rt.downloadOk) {
        $v = if ($rt.verifyOk) { 'OK   (SHA-256 一致)' } else { 'NG   (SHA-256 不一致)' }
        $lines.Add("  Verify  : $v")
    }
    if ($rt.cleanupWarn) { $lines.Add("  Cleanup : WARN リモート一時ファイルの削除に失敗") }
    $lines.Add("  Result  : $eval   expected=$($item.expected)")
    $lines.Add('')
    return $lines.ToArray()
}

function New-HtmlReport($rows, $meta) {
    function HE([string]$s) {
        if ($null -eq $s) { return '' }
        return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
    }
    $body = foreach ($r in $rows) {
        $cls = switch ($r.eval) { 'OK' { 'ok' } 'NG' { 'ng' } default { 'warn' } }
        "<tr class='$cls'><td>$(HE $r.share)</td><td>$(HE $r.description)</td>" +
        "<td>$(HE $r.username)</td><td>$($r.upMbps)</td><td>$($r.downMbps)</td>" +
        "<td>$(HE $r.verify)</td><td>$(HE $r.eval)</td><td>$(HE $r.message)</td></tr>"
    }
    return @"
<!DOCTYPE html><html lang='ja'><head><meta charset='utf-8'>
<title>File Transfer Check</title>
<style>
body{font-family:Segoe UI,Meiryo,sans-serif;margin:20px}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ccc;padding:6px 10px;text-align:left}
th{background:#f0f0f0}
tr.ok td:last-child,tr.ok td:nth-child(7){color:#0a0}
tr.ng{background:#fdecec}
tr.warn{background:#fff7e0}
</style></head><body>
<h1>File Transfer Check</h1>
<p>生成: $(HE $meta.generated) / テストサイズ: $($meta.sizeMB) MB</p>
<table><thead><tr><th>共有</th><th>説明</th><th>ユーザー</th>
<th>上り MB/s</th><th>下り MB/s</th><th>整合性</th><th>判定</th><th>備考</th></tr></thead>
<tbody>
$($body -join "`n")
</tbody></table></body></html>
"@
}

function Invoke-Main {
    param(
        [string]$ShareList, [int]$SizeMB, [int]$TimeoutSec,
        [string]$HtmlReport, [switch]$FailOnly
    )
    if ($env:OPS_LOG_FILE) {
        Start-Transcript -Path $env:OPS_LOG_FILE -Force -Append -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not $ShareList -or -not (Test-Path -LiteralPath $ShareList)) {
        Write-Host "[ERROR] 共有リストが見つかりません: $ShareList" -ForegroundColor Red
        return 2
    }
    $items = Read-ShareList $ShareList
    $rows  = [System.Collections.Generic.List[hashtable]]::new()
    $okCount = 0; $ngCount = 0; $warnCount = 0

    foreach ($item in $items) {
        $cred = Get-CachedCredential $item.username
        $rt   = Invoke-SmbRoundTrip -Share $item.share -Credential $cred -SizeMB $SizeMB -TimeoutSec $TimeoutSec
        $success = ($rt.uploadOk -and $rt.downloadOk -and $rt.verifyOk)
        $eval    = Get-TransferEval $item.expected $success
        if ($rt.cleanupWarn -and $eval -eq 'OK') { $eval = 'WARN' }

        switch ($eval) { 'OK' { $okCount++ } 'NG' { $ngCount++ } 'WARN' { $warnCount++ } }

        if (-not ($FailOnly -and $eval -eq 'OK')) {
            Format-ShareResult $item $rt $eval | ForEach-Object { Write-Host $_ }
        }
        $verify = if ($rt.uploadOk -and $rt.downloadOk) { if ($rt.verifyOk) { 'OK' } else { 'NG' } } else { '-' }
        $rows.Add(@{
            share = $item.share; description = $item.description; username = $item.username
            upMbps = $rt.upMbps; downMbps = $rt.downMbps; verify = $verify
            eval = $eval; message = $rt.message
        })
    }

    Write-Host ('-' * 50)
    Write-Host ("  Shares: {0}   OK: {1}   NG: {2}   Warning: {3}" -f $items.Count, $okCount, $ngCount, $warnCount)

    if ($HtmlReport) {
        $meta = @{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); sizeMB = $SizeMB }
        $htmlDir = Split-Path -Parent $HtmlReport
        if ($htmlDir -and -not (Test-Path -LiteralPath $htmlDir)) { New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null }
        New-HtmlReport $rows.ToArray() $meta | Set-Content -LiteralPath $HtmlReport -Encoding UTF8
        Write-Host "  HTML: $HtmlReport"
    }

    if ($env:OPS_LOG_FILE) { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
    if (($ngCount + $warnCount) -gt 0) { return 1 } else { return 0 }
}

if (-not $env:FTC_SKIP_MAIN) {
    exit (Invoke-Main -ShareList $ShareList -SizeMB $SizeMB -TimeoutSec $TimeoutSec -HtmlReport $HtmlReport -FailOnly:$FailOnly)
}