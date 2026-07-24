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