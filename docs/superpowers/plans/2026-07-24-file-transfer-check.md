# file-transfer-check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** お客様端末からサーバの SMB 共有へテストファイルを往復転送し、転送可否・整合性・スループットを確認するスタンドアロンツールを Windows/Linux 両対応で追加する。

**Architecture:** 既存 `tools/network-check` の自己完結スタイルを踏襲。Windows は純 PowerShell 本体 + 起動用 bat、Linux は smbclient ベースの bash。本体スクリプトは純ロジック関数（リストパーサ・判定・速度計算）を dot-source 可能にし、`main` 実行は環境変数ガードで抑止することで Pester 単体テストを可能にする。実 SMB I/O は手動結合テストで担保する。

**Tech Stack:** PowerShell 5.1、Pester 5.x、Windows バッチ、Bash 4+、smbclient、SHA-256（Get-FileHash / sha256sum）。

## Global Constraints

- PowerShell 5.1 互換必須。`??` / `?:` / `?.` / `utf8NoBOM` は使用禁止。
- `.ps1` は **UTF-8 BOM 付き**、`.bat` は **CRLF**、`.sh` / `.lst` は **UTF-8 BOM なし + LF**。
- 認証パスワードは平文でファイルに書かない・ログに出さない・HTML に出さない。
- 新規ツール配置: `tools/file-transfer-check/`。ツール id / フォルダ名は `file-transfer-check`。
- Windows 本体: `Check-FileTransfer.ps1`（Verb-Noun）、Linux 本体: `check_file_transfer.sh`（snake_case）。
- リスト形式: `<share-unc>, <username>, <expected>, <description>`、`#` はコメント、expected は `ok`/`ng`/`-`。
- 終了コード: 0=全 OK（Warning なし）/ 1=1 件以上 NG または Warning / 2=リスト無し / 10=前提コマンド無し。
- 既定値: SizeMB=10、TimeoutSec=60。
- テスト実行: `Invoke-Pester -Path tests/`。

---

## File Structure

- Create: `tools/file-transfer-check/Check-FileTransfer.ps1` — Windows 本体（パーサ・判定・速度・SMB往復・出力・main）
- Create: `tools/file-transfer-check/Check-FileTransfer.bat` — Windows 起動用バッチ（引数を bat から渡す）
- Create: `tools/file-transfer-check/check_file_transfer.sh` — Linux 本体（smbclient）
- Create: `tools/file-transfer-check/shares.lst` — 対象共有リスト（サンプル）
- Create: `tools/file-transfer-check/README.md` — 使い方・手動結合テスト手順
- Create: `tests/FileTransferCheck.Tests.ps1` — Pester 単体テスト（純ロジック関数）
- Modify: `tools/tool-catalog.yaml` — ツール登録を追記

**本体スクリプトのガード構造（全 PS 関数はこの中に定義）:**

```powershell
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ShareList  = '',
    [int]$SizeMB        = 10,
    [int]$TimeoutSec    = 60,
    [string]$HtmlReport = '',
    [switch]$FailOnly
)
# ... 関数定義 ...
# 末尾:
if (-not $env:FTC_SKIP_MAIN) {
    exit (Invoke-Main -ShareList $ShareList -SizeMB $SizeMB -TimeoutSec $TimeoutSec -HtmlReport $HtmlReport -FailOnly:$FailOnly)
}
```

テストは `$env:FTC_SKIP_MAIN='1'; . <path>` で dot-source し、純関数のみ検証する。

---

## Task 1: リストパーサ `Read-ShareList`

**Files:**
- Create: `tools/file-transfer-check/Check-FileTransfer.ps1`（BOM 付き UTF-8）
- Test: `tests/FileTransferCheck.Tests.ps1`

**Interfaces:**
- Produces: `Read-ShareList([string]$Path)` → `hashtable[]`。各要素は `@{ share=<string>; username=<string>; expected='ok'|'ng'|'-'; description=<string> }`。

- [ ] **Step 1: Write the failing test**

`tests/FileTransferCheck.Tests.ps1` を新規作成:

```powershell
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'file-transfer-check pure logic' {
    BeforeAll {
        $env:FTC_SKIP_MAIN = '1'
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\file-transfer-check\Check-FileTransfer.ps1')).Path
        . $script:ScriptPath
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ftc-test-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\FTC_SKIP_MAIN -ErrorAction SilentlyContinue
    }

    Context 'Read-ShareList' {
        It 'parses a 4-field line' {
            $f = Join-Path $script:TmpDir 'a.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\share, svc_user, ok, 業務共有'
            $r = Read-ShareList $f
            $r.Count | Should -Be 1
            $r[0].share       | Should -Be '\\srv\share'
            $r[0].username    | Should -Be 'svc_user'
            $r[0].expected    | Should -Be 'ok'
            $r[0].description | Should -Be '業務共有'
        }
        It 'treats blank username as integrated auth' {
            $f = Join-Path $script:TmpDir 'b.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\share, , ok, desc'
            (Read-ShareList $f)[0].username | Should -Be ''
        }
        It 'skips comments and blank lines' {
            $f = Join-Path $script:TmpDir 'c.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value @('# comment', '', '\\srv\s, , -, d')
            (Read-ShareList $f).Count | Should -Be 1
        }
        It 'normalizes invalid expected to dash' {
            $f = Join-Path $script:TmpDir 'd.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\s, , bogus, d'
            (Read-ShareList $f)[0].expected | Should -Be '-'
        }
        It 'falls back to share as description when omitted' {
            $f = Join-Path $script:TmpDir 'e.lst'
            Set-Content -LiteralPath $f -Encoding UTF8 -Value '\\srv\s'
            (Read-ShareList $f)[0].description | Should -Be '\\srv\s'
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`
Expected: FAIL（`Check-FileTransfer.ps1` が存在しない / `Read-ShareList` 未定義）

- [ ] **Step 3: Write minimal implementation**

`tools/file-transfer-check/Check-FileTransfer.ps1` を新規作成（**UTF-8 BOM 付きで保存**）:

```powershell
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
    return @($result)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`
Expected: PASS（Read-ShareList の 5 テスト）

- [ ] **Step 5: Commit**

```bash
git add tools/file-transfer-check/Check-FileTransfer.ps1 tests/FileTransferCheck.Tests.ps1
git commit -m "feat(file-transfer-check): shares.lst パーサと単体テストを追加"
```

---

## Task 2: 判定・速度・ハッシュ照合ヘルパ

**Files:**
- Modify: `tools/file-transfer-check/Check-FileTransfer.ps1`（`Read-ShareList` の下に追記）
- Test: `tests/FileTransferCheck.Tests.ps1`（Context 追記）

**Interfaces:**
- Consumes: なし
- Produces:
  - `Get-TransferEval([string]$Expected, [bool]$Success)` → `'OK'|'NG'|'WARN'`。`$Success` は往復＋整合の end-to-end 成否。
  - `Get-TransferSpeed([long]$Bytes, [double]$Seconds)` → `double`（MB/s、小数第 2 位）。
  - `Test-HashMatch([string]$A, [string]$B)` → `bool`（大文字小文字無視）。

- [ ] **Step 1: Write the failing test**

`tests/FileTransferCheck.Tests.ps1` に Context を追記:

```powershell
    Context 'Get-TransferEval' {
        It 'expected=ok & success -> OK'   { Get-TransferEval 'ok' $true  | Should -Be 'OK' }
        It 'expected=ok & fail -> NG'      { Get-TransferEval 'ok' $false | Should -Be 'NG' }
        It 'expected=ng & fail -> OK'      { Get-TransferEval 'ng' $false | Should -Be 'OK' }
        It 'expected=ng & success -> NG'   { Get-TransferEval 'ng' $true  | Should -Be 'NG' }
        It 'expected=- & success -> OK'    { Get-TransferEval '-'  $true  | Should -Be 'OK' }
        It 'expected=- & fail -> WARN'     { Get-TransferEval '-'  $false | Should -Be 'WARN' }
    }
    Context 'Get-TransferSpeed' {
        It 'computes MB/s' { Get-TransferSpeed ([long](10 * 1MB)) 2.0 | Should -Be 5.0 }
        It 'returns 0 for non-positive seconds' { Get-TransferSpeed 1048576 0 | Should -Be 0.0 }
    }
    Context 'Test-HashMatch' {
        It 'matches ignoring case' { Test-HashMatch 'ABCD' 'abcd' | Should -BeTrue }
        It 'detects mismatch'      { Test-HashMatch 'ABCD' 'ef01' | Should -BeFalse }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`
Expected: FAIL（3 関数未定義）

- [ ] **Step 3: Write minimal implementation**

`Check-FileTransfer.ps1` の `Read-ShareList` の下に追記:

```powershell
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`
Expected: PASS（全 Context）

- [ ] **Step 5: Commit**

```bash
git add tools/file-transfer-check/Check-FileTransfer.ps1 tests/FileTransferCheck.Tests.ps1
git commit -m "feat(file-transfer-check): 判定・速度・ハッシュ照合ヘルパを追加"
```

---

## Task 3: 資格情報プロンプトと SMB 往復転送（I/O）

**Files:**
- Modify: `tools/file-transfer-check/Check-FileTransfer.ps1`（ヘルパの下に追記）

**Interfaces:**
- Consumes: `Get-TransferSpeed`, `Test-HashMatch`
- Produces:
  - `Get-CachedCredential([string]$Username)` → `PSCredential` or `$null`（空ユーザー名は `$null`。同一ユーザー名は実行中 1 回だけプロンプト）。
  - `Invoke-SmbRoundTrip([string]$Share, [PSCredential]$Credential, [int]$SizeMB, [int]$TimeoutSec)` → `[ordered]hashtable`。
    キー: `connected(bool)`, `uploadOk(bool)`, `downloadOk(bool)`, `verifyOk(bool)`, `upMbps(double)`, `downMbps(double)`, `cleanupWarn(bool)`, `message(string)`。

**注記（TimeoutSec）:** Windows の `Copy-Item`/`New-PSDrive` は OS 既定の SMB タイムアウトに従うため、`-TimeoutSec` は Windows では実効的に効きにくい。本タスクでは受け取るが強制はせず、README に「Linux でのみ厳密に適用」と明記する（Linux 側は Task 7 で `timeout` により実装）。

**このタスクは実 SMB サーバを要するため Pester 自動テストは行わず、Task 8 の手動結合テストで担保する。** 本タスクの完了判定は「構文が通り、dot-source で関数が定義されること」。

- [ ] **Step 1: Write the implementation**

`Check-FileTransfer.ps1` に追記:

```powershell
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
```

- [ ] **Step 2: Verify the script still parses and functions load**

Run:
```
powershell -NoProfile -Command "$env:FTC_SKIP_MAIN='1'; . './tools/file-transfer-check/Check-FileTransfer.ps1'; if (Get-Command Invoke-SmbRoundTrip -EA SilentlyContinue) { 'OK' } else { 'MISSING' }"
```
Expected: `OK`

- [ ] **Step 3: Run existing unit tests to confirm no regression**

Run: `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`
Expected: PASS（Task 1・2 のテストが引き続き通る）

- [ ] **Step 4: Commit**

```bash
git add tools/file-transfer-check/Check-FileTransfer.ps1
git commit -m "feat(file-transfer-check): 資格情報プロンプトとSMB往復転送を追加"
```

---

## Task 4: コンソール出力・HTML レポート・main オーケストレーション

**Files:**
- Modify: `tools/file-transfer-check/Check-FileTransfer.ps1`
- Test: `tests/FileTransferCheck.Tests.ps1`（`New-HtmlReport` の最小テストを追記）

**Interfaces:**
- Consumes: `Read-ShareList`, `Get-CachedCredential`, `Invoke-SmbRoundTrip`, `Get-TransferEval`
- Produces:
  - `Format-ShareResult($item, $rt, [string]$eval)` → コンソール表示用 `string[]`。
  - `New-HtmlReport($rows, $meta)` → HTML 文字列（`$rows` は各共有の結果ハッシュ配列。パスワードは含めない）。
  - `Invoke-Main` → `int`（終了コード）。

- [ ] **Step 1: Write the failing test（HTML 最小検証）**

`tests/FileTransferCheck.Tests.ps1` に追記:

```powershell
    Context 'New-HtmlReport' {
        It 'renders share and result but never a password' {
            $rows = @(
                @{ share='\\srv\share'; username='svc_user'; eval='OK'; upMbps=8.3; downMbps=11.1;
                   verify='OK'; message=''; description='業務共有' }
            )
            $html = New-HtmlReport $rows @{ generated='2026-07-24 10:00:00'; sizeMB=10 }
            $html | Should -Match '\\\\srv\\share'
            $html | Should -Match 'OK'
            $html | Should -Not -Match 'password'
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`
Expected: FAIL（`New-HtmlReport` 未定義）

- [ ] **Step 3: Write minimal implementation**

`Check-FileTransfer.ps1` に追記:

```powershell
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
```

そして**スクリプト末尾**に main ガードを追加:

```powershell
if (-not $env:FTC_SKIP_MAIN) {
    exit (Invoke-Main -ShareList $ShareList -SizeMB $SizeMB -TimeoutSec $TimeoutSec -HtmlReport $HtmlReport -FailOnly:$FailOnly)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`
Expected: PASS（New-HtmlReport 含む全テスト）

- [ ] **Step 5: Verify missing-list exit code**

Run:
```
powershell -NoProfile -File ./tools/file-transfer-check/Check-FileTransfer.ps1 -ShareList ./no-such.lst; echo "exit=$LASTEXITCODE"
```
Expected: `[ERROR] 共有リストが見つかりません...` と `exit=2`

- [ ] **Step 6: Commit**

```bash
git add tools/file-transfer-check/Check-FileTransfer.ps1 tests/FileTransferCheck.Tests.ps1
git commit -m "feat(file-transfer-check): コンソール出力・HTMLレポート・main を追加"
```

---

## Task 5: サンプル共有リスト `shares.lst`

**Files:**
- Create: `tools/file-transfer-check/shares.lst`（**UTF-8 BOM なし + LF**）

- [ ] **Step 1: Create the sample list**

`tools/file-transfer-check/shares.lst` を作成（BOM なし・LF で保存）:

```
# file-transfer-check 対象共有リスト
# 形式: <share-unc>, <username>, <expected>, <description>
#   share-unc  : \\server\share または \\server\share\subdir
#   username   : 空欄=ログインユーザー(統合認証) / DOMAIN\user=専用ユーザー(実行時にPW入力)
#   expected   : ok(転送できるはず) / ng(できないはず) / -(評価しない)
#   description: 説明(任意)

\\filesv01\upload,            , ok, 業務ファイル受け渡し共有
\\filesv01\readonly, svc_check, ng, 読取専用のはず(書込失敗を期待)
```

- [ ] **Step 2: Verify encoding (no BOM, LF)**

Run:
```bash
file tools/file-transfer-check/shares.lst && python -c "d=open('tools/file-transfer-check/shares.lst','rb').read(); print('BOM' if d[:3]==b'\xef\xbb\xbf' else 'no-BOM'); print('CRLF' if b'\r\n' in d else 'LF')"
```
Expected: `no-BOM` と `LF`

- [ ] **Step 3: Commit**

```bash
git add tools/file-transfer-check/shares.lst
git commit -m "feat(file-transfer-check): サンプル共有リストを追加"
```

---

## Task 6: Windows 起動用バッチ `Check-FileTransfer.bat`

**Files:**
- Create: `tools/file-transfer-check/Check-FileTransfer.bat`（**CRLF**）

**Interfaces:**
- Consumes: `Check-FileTransfer.ps1`（`-ShareList` `-SizeMB` `-TimeoutSec` `-HtmlReport` `-FailOnly`）

- [ ] **Step 1: Create the launcher**

`tools/file-transfer-check/Check-FileTransfer.bat` を作成（**CRLF 改行で保存**）:

```bat
@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo ================================================
echo  File Transfer Check (SMB round-trip)
echo ================================================
echo.

:: ===== 運用者が編集する既定値（ここに引数を設定） =====
set "SHARE_LIST=%~dp0shares.lst"
set "SIZE_MB=10"
set "TIMEOUT_SEC=60"
set "HTML_REPORT="
set "FAIL_ONLY="
:: ======================================================

if not exist "!SHARE_LIST!" (
    echo [ERROR] Share list not found: !SHARE_LIST!
    echo Usage: %~nx0 [extra PowerShell args...]
    pause
    exit /b 2
)

set "PSARGS=-ShareList "!SHARE_LIST!" -SizeMB !SIZE_MB! -TimeoutSec !TIMEOUT_SEC!"
if not "!HTML_REPORT!"=="" set "PSARGS=!PSARGS! -HtmlReport "!HTML_REPORT!""
if /I "!FAIL_ONLY!"=="on"  set "PSARGS=!PSARGS! -FailOnly"

for /f %%t in ('powershell -NoLogo -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TIMESTAMP=%%t"
set "OPS_LOG_FILE=%~dpn0_!TIMESTAMP!.log"

echo Share list : !SHARE_LIST!
echo Test size  : !SIZE_MB! MB
echo.
echo Running...
echo.

:: bat の既定値 + コマンドライン引数(%*)で上書き可能
powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Check-FileTransfer.ps1" !PSARGS! %*

echo.
pause
endlocal
```

- [ ] **Step 2: Verify CRLF line endings**

Run:
```bash
python -c "d=open('tools/file-transfer-check/Check-FileTransfer.bat','rb').read(); print('CRLF' if b'\r\n' in d else 'LF')"
```
Expected: `CRLF`

- [ ] **Step 3: Commit**

```bash
git add tools/file-transfer-check/Check-FileTransfer.bat
git commit -m "feat(file-transfer-check): Windows起動用batを追加(引数はbatから渡す)"
```

---

## Task 7: Linux 本体 `check_file_transfer.sh`

**Files:**
- Create: `tools/file-transfer-check/check_file_transfer.sh`（**UTF-8 BOM なし + LF**）

**Interfaces:**
- CLI: `-l <list>` `-s <sizeMB>` `-t <timeoutSec>` `-o <html>` `-f`（FailOnly）
- 前提: `smbclient`, `sha256sum`, `dd`。未導入なら終了コード 10。

**設計メモ:**
- UNC `\\server\share\sub` を `//server/share`（service）と `sub`（相対パス）に正規化。
- 統合認証（username 空欄）: Kerberos チケットがあれば `smbclient -k`、無ければ **Warning + スキップ**（レポートに「Linux では username 指定が必要」）。
- 専用ユーザー: パスワードは `read -s` で 1 回入力し、`--authentication-file`（chmod 600、処理後 `rm`）で渡す。`ps` から見えないようにする。
- タイムアウトは `timeout <sec> smbclient ...` で厳密適用。
- 速度は `date +%s.%N` の差分から awk で MB/s 算出。

- [ ] **Step 1: Create the script**

`tools/file-transfer-check/check_file_transfer.sh` を作成（BOM なし・LF）:

```bash
#!/usr/bin/env bash
set -u

LIST="$(cd "$(dirname "$0")" && pwd)/shares.lst"
SIZE_MB=10
TIMEOUT_SEC=60
HTML=""
FAIL_ONLY=0

while getopts "l:s:t:o:fh" opt; do
  case "$opt" in
    l) LIST="$OPTARG" ;;
    s) SIZE_MB="$OPTARG" ;;
    t) TIMEOUT_SEC="$OPTARG" ;;
    o) HTML="$OPTARG" ;;
    f) FAIL_ONLY=1 ;;
    h) echo "Usage: $0 [-l list] [-s sizeMB] [-t timeoutSec] [-o html] [-f]"; exit 0 ;;
    *) echo "Unknown option"; exit 2 ;;
  esac
done

command -v smbclient >/dev/null 2>&1 || { echo "[ERROR] smbclient が見つかりません"; exit 10; }
command -v sha256sum >/dev/null 2>&1 || { echo "[ERROR] sha256sum が見つかりません"; exit 10; }
[ -f "$LIST" ] || { echo "[ERROR] 共有リストが見つかりません: $LIST"; exit 2; }

declare -A CRED_CACHE
OK=0; NG=0; WARN=0
ROWS=""

# UNC(\\srv\share\sub or //srv/share/sub) -> service + relpath
normalize_share() {
  local s="${1//\\//}"          # backslash -> slash
  s="${s#//}"                   # strip leading //
  local host="${s%%/*}"; s="${s#*/}"
  local share="${s%%/*}"
  local rel=""
  if [ "$s" != "$share" ]; then rel="${s#*/}"; fi
  echo "//${host}/${share}|${rel}"
}

get_password() {
  local user="$1"
  if [ -n "${CRED_CACHE[$user]:-}" ]; then printf '%s' "${CRED_CACHE[$user]}"; return; fi
  local pw
  read -r -s -p "パスワードを入力してください ($user): " pw </dev/tty; echo >&2
  CRED_CACHE[$user]="$pw"
  printf '%s' "$pw"
}

run_share() {
  local share="$1" user="$2" expected="$3" desc="$4"
  local parsed service rel
  parsed="$(normalize_share "$share")"
  service="${parsed%|*}"; rel="${parsed#*|}"

  local tmp_src tmp_dst authfile
  tmp_src="$(mktemp)"; tmp_dst="$(mktemp)"
  dd if=/dev/urandom of="$tmp_src" bs=1M count="$SIZE_MB" status=none
  local srch; srch="$(sha256sum "$tmp_src" | awk '{print $1}')"
  local remote="conntest_$(date +%Y%m%d-%H%M%S)_$RANDOM.tmp"

  local auth_args=()
  if [ -z "$user" ]; then
    if klist -s 2>/dev/null; then
      auth_args=(-k)
    else
      rm -f "$tmp_src" "$tmp_dst"
      echo "[SHARE] $share  ($desc)"
      echo "  Result  : WARN  Linux では username 指定が必要 (統合認証不可)"
      echo ""
      WARN=$((WARN+1))
      ROWS="${ROWS}<tr class='warn'><td>${share}</td><td>${desc}</td><td></td><td>-</td><td>-</td><td>-</td><td>WARN</td><td>username 必要</td></tr>"
      return
    fi
  else
    local pw; pw="$(get_password "$user")"
    authfile="$(mktemp)"; chmod 600 "$authfile"
    printf 'username=%s\npassword=%s\n' "$user" "$pw" > "$authfile"
    auth_args=(-A "$authfile")
  fi

  local cdcmd=""
  [ -n "$rel" ] && cdcmd="cd \"$rel\"; "

  # Upload
  local up_start up_end up_sec up_ok=0 dn_ok=0 vf_ok=0 msg=""
  up_start="$(date +%s.%N)"
  if timeout "$TIMEOUT_SEC" smbclient "$service" "${auth_args[@]}" \
       -c "${cdcmd}put \"$tmp_src\" \"$remote\"" >/dev/null 2>&1; then
    up_ok=1
  else
    msg="アップロード失敗"
  fi
  up_end="$(date +%s.%N)"
  up_sec="$(awk "BEGIN{print $up_end-$up_start}")"

  # Download
  local dn_start dn_end dn_sec
  dn_start="$(date +%s.%N)"
  if [ "$up_ok" -eq 1 ] && timeout "$TIMEOUT_SEC" smbclient "$service" "${auth_args[@]}" \
       -c "${cdcmd}get \"$remote\" \"$tmp_dst\"" >/dev/null 2>&1; then
    dn_ok=1
  elif [ "$up_ok" -eq 1 ]; then
    msg="ダウンロード失敗"
  fi
  dn_end="$(date +%s.%N)"
  dn_sec="$(awk "BEGIN{print $dn_end-$dn_start}")"

  # Verify
  if [ "$dn_ok" -eq 1 ]; then
    local dsth; dsth="$(sha256sum "$tmp_dst" | awk '{print $1}')"
    if [ "$srch" = "$dsth" ]; then vf_ok=1; else msg="ハッシュ不一致"; fi
  fi

  # Cleanup remote
  local cleanup_warn=0
  timeout "$TIMEOUT_SEC" smbclient "$service" "${auth_args[@]}" \
      -c "${cdcmd}del \"$remote\"" >/dev/null 2>&1 || cleanup_warn=1

  [ -n "${authfile:-}" ] && rm -f "$authfile"
  rm -f "$tmp_src" "$tmp_dst"

  # Evaluate
  local success=0
  [ "$up_ok" -eq 1 ] && [ "$dn_ok" -eq 1 ] && [ "$vf_ok" -eq 1 ] && success=1
  local eval
  case "$expected" in
    ok) [ "$success" -eq 1 ] && eval="OK" || eval="NG" ;;
    ng) [ "$success" -eq 1 ] && eval="NG" || eval="OK" ;;
    *)  [ "$success" -eq 1 ] && eval="OK" || eval="WARN" ;;
  esac
  [ "$cleanup_warn" -eq 1 ] && [ "$eval" = "OK" ] && eval="WARN"

  local up_mbps="0" dn_mbps="0"
  [ "$up_ok" -eq 1 ] && up_mbps="$(awk "BEGIN{if($up_sec>0)printf \"%.2f\", $SIZE_MB/$up_sec; else print 0}")"
  [ "$dn_ok" -eq 1 ] && dn_mbps="$(awk "BEGIN{if($dn_sec>0)printf \"%.2f\", $SIZE_MB/$dn_sec; else print 0}")"

  case "$eval" in OK) OK=$((OK+1));; NG) NG=$((NG+1));; WARN) WARN=$((WARN+1));; esac

  if [ "$FAIL_ONLY" -eq 0 ] || [ "$eval" != "OK" ]; then
    echo "[SHARE] $share  ($desc)"
    echo "  Auth    : ${user:-integrated}"
    [ "$up_ok" -eq 1 ] && echo "  Upload  : OK   ${up_mbps} MB/s" || echo "  Upload  : NG   $msg"
    [ "$dn_ok" -eq 1 ] && echo "  Download: OK   ${dn_mbps} MB/s"
    [ "$up_ok" -eq 1 ] && [ "$dn_ok" -eq 1 ] && { [ "$vf_ok" -eq 1 ] && echo "  Verify  : OK   (SHA-256 一致)" || echo "  Verify  : NG   (SHA-256 不一致)"; }
    [ "$cleanup_warn" -eq 1 ] && echo "  Cleanup : WARN 削除失敗"
    echo "  Result  : $eval   expected=$expected"
    echo ""
  fi

  local cls="warn"; [ "$eval" = "OK" ] && cls="ok"; [ "$eval" = "NG" ] && cls="ng"
  ROWS="${ROWS}<tr class='${cls}'><td>${share}</td><td>${desc}</td><td>${user}</td><td>${up_mbps}</td><td>${dn_mbps}</td><td>$([ "$vf_ok" -eq 1 ] && echo OK || echo '-')</td><td>${eval}</td><td>${msg}</td></tr>"
}

# Parse list and iterate
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  IFS=',' read -r f_share f_user f_exp f_desc <<< "$line"
  f_share="$(echo "$f_share" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  f_user="$(echo "${f_user:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  f_exp="$(echo "${f_exp:--}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
  case "$f_exp" in ok|ng|-) : ;; *) f_exp="-" ;; esac
  f_desc="$(echo "${f_desc:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$f_desc" ] && f_desc="$f_share"
  [ -z "$f_share" ] && continue
  run_share "$f_share" "$f_user" "$f_exp" "$f_desc"
done < "$LIST"

echo "--------------------------------------------------"
TOTAL=$((OK+NG+WARN))
echo "  Shares: $TOTAL   OK: $OK   NG: $NG   Warning: $WARN"

if [ -n "$HTML" ]; then
  {
    echo "<!DOCTYPE html><html lang='ja'><head><meta charset='utf-8'><title>File Transfer Check</title>"
    echo "<style>body{font-family:sans-serif;margin:20px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:6px 10px}th{background:#f0f0f0}tr.ng{background:#fdecec}tr.warn{background:#fff7e0}</style></head><body>"
    echo "<h1>File Transfer Check</h1><p>生成: $(date '+%Y-%m-%d %H:%M:%S') / テストサイズ: ${SIZE_MB} MB</p>"
    echo "<table><thead><tr><th>共有</th><th>説明</th><th>ユーザー</th><th>上り MB/s</th><th>下り MB/s</th><th>整合性</th><th>判定</th><th>備考</th></tr></thead><tbody>"
    echo "$ROWS"
    echo "</tbody></table></body></html>"
  } > "$HTML"
  echo "  HTML: $HTML"
fi

if [ $((NG+WARN)) -gt 0 ]; then exit 1; else exit 0; fi
```

- [ ] **Step 2: Syntax check + encoding check**

Run:
```bash
bash -n tools/file-transfer-check/check_file_transfer.sh && echo "syntax-ok"
python -c "d=open('tools/file-transfer-check/check_file_transfer.sh','rb').read(); print('BOM' if d[:3]==b'\xef\xbb\xbf' else 'no-BOM'); print('CRLF' if b'\r\n' in d else 'LF')"
```
Expected: `syntax-ok`、`no-BOM`、`LF`

- [ ] **Step 3: Missing-prereq / missing-list behavior (best effort)**

Run（smbclient がある環境なら list 欠如で 2 を確認）:
```bash
bash tools/file-transfer-check/check_file_transfer.sh -l /no/such.lst; echo "exit=$?"
```
Expected: `[ERROR] 共有リストが見つかりません...` と `exit=2`（smbclient 未導入環境では先に `exit=10`）

- [ ] **Step 4: Commit**

```bash
git add tools/file-transfer-check/check_file_transfer.sh
git commit -m "feat(file-transfer-check): Linux本体(smbclient)を追加"
```

---

## Task 8: 手動結合テスト手順の確立と README

**Files:**
- Create: `tools/file-transfer-check/README.md`

このタスクは実 SMB 共有に対する往復を人手で確認し、その手順を README に固定する。自動化はしない。

- [ ] **Step 1: Write the README**

`tools/file-transfer-check/README.md` を作成:

````markdown
# File Transfer Check (SMB 往復疎通確認)

お客様端末からサーバの SMB 共有へ**テストファイルを実際に往復転送**し、
転送可否・整合性(SHA-256)・スループット(MB/s)を確認するスタンドアロンツールです。
**このフォルダ一式をコピーするだけで動きます。**

> 注意: 本ツールは他の `tools/` 配下ツールと異なり、**SSM ではなくお客様端末で直接実行**します。

## 構成

```
tools/file-transfer-check/
├── Check-FileTransfer.ps1   # Windows 本体 (PowerShell 5.1)
├── Check-FileTransfer.bat   # Windows 起動用バッチ
├── check_file_transfer.sh   # Linux 本体 (smbclient)
├── shares.lst               # 対象共有リスト (サンプル)
└── README.md
```

## リスト形式 (shares.lst)

```
# <share-unc>, <username>, <expected>, <description>
#   username : 空欄=ログインユーザー(統合認証) / DOMAIN\user=専用ユーザー(実行時にPW入力)
#   expected : ok(転送できるはず) / ng(できないはず) / -(評価しない)
\\filesv01\upload,           , ok, 業務ファイル受け渡し共有
\\filesv01\readonly, svc_check, ng, 読取専用のはず
```

- パスワードはリストに書きません。専用ユーザー行があれば実行時に一度だけ入力を求めます。
- 注意: `description` に `#` を含めるとコメントとして切り詰められます。

## 使い方

### Windows
```
:: bat 冒頭の SET ブロックで既定値を設定してダブルクリック、
:: または追加引数を渡して上書き
Check-FileTransfer.bat -SizeMB 50 -HtmlReport report.html
```
ログは `Check-FileTransfer_<日時>.log` に記録されます。

### Linux
```bash
chmod +x check_file_transfer.sh   # 初回のみ
./check_file_transfer.sh -l shares.lst -s 10 -o report.html
```
前提: `smbclient` / `sha256sum` / `dd`。未導入なら終了コード 10。

## オプション

| Windows | Linux | 意味 | 既定 |
|---|---|---|---|
| `-ShareList` | `-l` | 対象リスト | 隣の shares.lst |
| `-SizeMB` | `-s` | テストサイズ MB | 10 |
| `-TimeoutSec` | `-t` | タイムアウト秒 | 60 |
| `-HtmlReport` | `-o` | HTML 出力 | なし |
| `-FailOnly` | `-f` | 失敗のみ表示 | off |

> `-TimeoutSec` は Linux (smbclient) では厳密に適用されます。Windows では OS の
> SMB タイムアウトに従うため実効的に効きにくい点に注意してください。

> Linux で統合認証(username 空欄)を使うには Kerberos チケット(`kinit`)が必要です。
> チケットが無い場合その行はスキップされます。非ドメイン端末では username を指定してください。

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 全て OK |
| 1 | NG または Warning あり |
| 2 | リストファイルが無い |
| 10 | 前提コマンドが無い |

## 手動結合テスト手順

実 SMB 共有が必要なため自動テストはありません。検証環境で以下を確認します。

1. 書込可能な共有を `expected=ok` で登録し、`OK` + 上下 MB/s が出ること。
2. 読取専用の共有を `expected=ng` で登録し、書込拒否→`OK`(期待どおり)になること。
3. 実行後、リモートに `conntest_*.tmp` が残っていないこと(後始末)。
4. 専用ユーザー行で PW プロンプトが一度だけ出ること。同一ユーザーの複数行で再入力されないこと。
5. HTML レポートにパスワードが一切含まれないこと。
6. 単体テスト: リポジトリルートで `Invoke-Pester -Path tests/FileTransferCheck.Tests.ps1`(純ロジック)。
````

- [ ] **Step 2: Perform the manual integration test**

検証環境の SMB 共有に対し、README「手動結合テスト手順」1〜5 を実行し、結果をコミットメッセージに記録する。
（実共有が用意できない場合はその旨を完了報告に明記し、単体テストのみで代替する。）

- [ ] **Step 3: Commit**

```bash
git add tools/file-transfer-check/README.md
git commit -m "docs(file-transfer-check): READMEと手動結合テスト手順を追加"
```

---

## Task 9: カタログ登録

**Files:**
- Modify: `tools/tool-catalog.yaml`（末尾に追記、`network-check` エントリのインデントに合わせる）

- [ ] **Step 1: Add the catalog entry**

`tools/tool-catalog.yaml` の `tools:` 配列末尾（`server-snapshot` エントリの後）に追記:

```yaml
  - id: file-transfer-check
    name: File Transfer Check
    description: SMB 共有への往復転送で疎通・整合性・速度を確認
    menu: true
    windowsPath: file-transfer-check/Check-FileTransfer.ps1
    linuxPath: file-transfer-check/check_file_transfer.sh
    defaultArgs: -ShareList "{ToolDir}/shares.lst"
    configFiles:
      - label: shares.lst
        path: file-transfer-check/shares.lst
        paramKey: shareList
    parameters:
      - key: shareList
        label: 共有リスト
        type: text
        argument: -ShareList
        linuxArgument: -l
        default: "{ToolDir}/shares.lst"
      - key: sizeMB
        label: テストサイズMB
        type: number
        argument: -SizeMB
        linuxArgument: -s
        default: 10
      - key: timeoutSec
        label: タイムアウト秒
        type: number
        argument: -TimeoutSec
        linuxArgument: -t
        default: 60
      - key: html
        label: HTML レポート
        type: checkbox
        argument: -HtmlReport
        linuxArgument: -o
        value: "{ArtifactsDir}/file-transfer-check.html"
        default: true
      - key: failOnly
        label: 失敗のみ
        type: checkbox
        argument: -FailOnly
        linuxArgument: -f
        default: false
```

- [ ] **Step 2: Verify YAML parses**

Run:
```
powershell -NoProfile -Command "Get-Content tools/tool-catalog.yaml -Raw | Out-Null; 'read-ok'"
```
（プロジェクトに YAML パーサのテストがあればそれを実行。無ければ既存 GUI 起動でメニュー表示を目視確認。）
Expected: 既存カタログ読み込み処理でエラーが出ないこと。

- [ ] **Step 3: Commit**

```bash
git add tools/tool-catalog.yaml
git commit -m "feat(file-transfer-check): tool-catalog.yaml に登録"
```

---

## Task 10: CHANGELOG 更新

**Files:**
- Modify: `CHANGELOG.md`（`[Unreleased]` の Added に追記）

- [ ] **Step 1: Add CHANGELOG entry**

`CHANGELOG.md` の `[Unreleased]` → `### Added` に追記（節が無ければ作成）:

```markdown
### Added
- `tools/file-transfer-check`: SMB 共有への往復ファイル転送で疎通・整合性(SHA-256)・スループットを確認するスタンドアロンツール(Windows bat/PowerShell、Linux smbclient)。統合認証／専用ユーザー両対応、パスワードは実行時入力。
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: CHANGELOG に file-transfer-check を追記"
```

---

## Self-Review 結果（プラン作成者による確認）

- **Spec coverage:** 確認レベル(往復)=Task 3、SMB=Task 3/7、認証両対応=Task 3(PS)/7(sh)、PW 実行時入力=Task 3/7、複数対象=Task 1、サイズ指定＋速度=Task 2/3、Windows bat 引数渡し=Task 6、Linux=Task 7、出力/HTML/終了コード=Task 4/7、カタログ=Task 9、テスト=Task 1/2/4(単体)＋Task 8(手動)。全項目に対応タスクあり。
- **Placeholder scan:** 「add error handling」等の曖昧指示なし。全コードは実体を記載。
- **Type consistency:** `Read-ShareList`→`share/username/expected/description`、`Invoke-SmbRoundTrip`→`uploadOk/downloadOk/verifyOk/upMbps/downMbps/cleanupWarn/message`、`Get-TransferEval`/`Get-TransferSpeed`/`Test-HashMatch` の呼出し名・引数は全タスクで一致。終了コード/既定値は Global Constraints と一致。
