# filelist カテゴリ実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `server-snapshot` に新カテゴリ `filelist` を追加し、`filelist.conf` で指定したディレクトリ配下のファイル・ディレクトリ一覧を権限・オーナー情報付きで収集・比較できるようにする。

**Architecture:** 既存の `middleware` カテゴリの構造（設定ファイル + `Read-*Conf` / `Get-*Info` / `Compare-*` + Python 側 `_load_*_conf` / `collect_*` / `cat_*`）に完全に揃える。Windows は `Get-Acl` で NTFS ACL とオーナーを取得、Linux は `os.stat` + `pwd` / `grp` で POSIX 権限とオーナーを取得。設定ファイルは単一 `filelist.conf` に `[target:<key>]` セクションを並べ、対象ごとに `os` フィールドで OS を絞り込む。

**Tech Stack:** PowerShell 5.1 (Windows), Bash 4+ / Python 3 (Linux), Pester 5 (tests), INI-like config parser.

**参照設計書:** [docs/superpowers/specs/2026-07-01-filelist-category-design.md](../specs/2026-07-01-filelist-category-design.md)

**関連ファイル（既存）:**
- `tools/server-snapshot/ServerSnapshot.ps1`（1397 行、Windows 本体）
- `tools/server-snapshot/server_snapshot.sh`（972 行、Linux 本体 + Python 埋め込み）
- `tools/server-snapshot/compare_server_info.py`（457 行、比較エンジン）
- `tools/server-snapshot/middleware.conf`（設定ファイルの参考例）
- `tests/`（Pester テスト置き場、現状 `AwsConfig.Tests.ps1` 等 3 ファイル）

**Windows 本体 の追加箇所（既存コードの行番号）:**
- `$validCategories`（39 行目）に `'filelist'` 追加
- `Get-MiddlewareInfo` の後（346 行目付近）に `Read-FilelistConf` / `Get-FilelistInfo` を追加
- `Invoke-Collect` の `$allCategories`（731 行目）と `switch ($cat)`（760 行目）に `filelist` を追加
- `Compare-Middleware` の後（1052 行目付近）に `Compare-Filelist` を追加
- `Invoke-Compare` の `$allCats`（1250 行目）と `switch ($cat)`（1261 行目）に `filelist` を追加

**Linux 本体 の追加箇所:**
- `server_snapshot.sh` の `all_cats`（131 行目）と `_OPS_FILELIST_CONF` の export（146 行目付近）
- Python 埋め込みブロック内で `_load_filelist_conf()` / `collect_filelist()` を追加、`CAT_MAP`（834 行目）に登録
- `compare_server_info.py` の `cat_middleware` の後（228 行目付近）に `cat_filelist` を追加し、`CATEGORIES`（229 行目）に登録

---

## Task 1: `filelist.conf` テンプレートと `$validCategories` 登録

**Files:**
- Create: `tools/server-snapshot/filelist.conf`
- Modify: `tools/server-snapshot/ServerSnapshot.ps1:39`
- Modify: `tools/server-snapshot/server_snapshot.sh:131`
- Test: `tests/Filelist.Category.Tests.ps1`

- [ ] **Step 1: 失敗するテストを書く（カテゴリが受理される）**

Create `tests/Filelist.Category.Tests.ps1`:

```powershell
$Script = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'

Describe 'filelist category is accepted' {
    It 'accepts -Category filelist without error' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script `
            collect -Category filelist -OutputPath (Join-Path $env:TEMP 'filelist-smoke.json') 2>&1
        $LASTEXITCODE | Should -Be 0
    }
}
```

- [ ] **Step 2: テスト失敗を確認**

Run: `Invoke-Pester -Path tests/Filelist.Category.Tests.ps1`
Expected: FAIL — `Invalid -Category 'filelist'` エラー（exit 1）

- [ ] **Step 3: `$validCategories` に追加**

Edit `tools/server-snapshot/ServerSnapshot.ps1` 行 39:

```powershell
$validCategories = @('all','os','network','services','packages','users','filesystem','environment','security','patches','tuning','scheduled','middleware','filelist')
```

- [ ] **Step 4: bash 側の `all_cats` にも追加**

Edit `tools/server-snapshot/server_snapshot.sh` 行 131:

```bash
    local all_cats="os network services packages users filesystem environment security patches tuning scheduled middleware filelist"
```

- [ ] **Step 5: 空の `filelist.conf` テンプレートを作成**

Create `tools/server-snapshot/filelist.conf`（BOM なし / LF）:

```ini
# server-snapshot filelist collection config.
# Empty by default: no targets → snapshot.filelist = [].
#
# Add [target:<key>] sections to scan directories:
#
# [target:etc-nginx]
# path    = /etc/nginx         # required
# os      = linux              # windows | linux | both (default: both)
# depth   = unlimited          # integer or "unlimited" (default: unlimited)
# exclude = *.bak,cache/*      # comma-separated globs (default: empty)
# hash    = false              # true = compute sha256 for files (default: false)

[limits]
max_entries_per_target = 100000
```

- [ ] **Step 6: テスト通過を確認**

Run: `Invoke-Pester -Path tests/Filelist.Category.Tests.ps1`
Expected: PASS — 出力 JSON は `filelist` キーを含まない（次タスクで追加）が、`-Category filelist` はエラーにならない

- [ ] **Step 7: コミット**

```bash
git add tools/server-snapshot/filelist.conf tools/server-snapshot/ServerSnapshot.ps1 tools/server-snapshot/server_snapshot.sh tests/Filelist.Category.Tests.ps1
git commit -m "feat(server-snapshot): register filelist category and template config"
```

---

## Task 2: `Read-FilelistConf` パーサ（Windows）

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Read-MwConf` の後、行 609 付近に挿入）
- Test: `tests/Filelist.Config.Tests.ps1`

- [ ] **Step 1: 失敗するテストを書く**

Create `tests/Filelist.Config.Tests.ps1`:

```powershell
$Script = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'

Describe 'Read-FilelistConf' {
    BeforeAll {
        . $Script -Command list -ErrorAction SilentlyContinue 2>&1 | Out-Null
        # Dot-source with dummy arg to make functions available (Invoke-List is harmless).
        # If direct dot-source causes side effects, use Import-Module strategy instead.
    }

    It 'returns empty targets when conf is missing' {
        $env:_OPS_FILELIST_CONF = Join-Path $env:TEMP 'no-such-file.conf'
        $conf = Read-FilelistConf
        $conf.targets.Count | Should -Be 0
        $conf.max_entries_per_target | Should -Be 100000
    }

    It 'parses a single target with defaults' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @'
[target:etc]
path = /etc/nginx
'@
        $env:_OPS_FILELIST_CONF = $f.FullName
        $conf = Read-FilelistConf
        $conf.targets.Count | Should -Be 1
        $conf.targets[0].key      | Should -Be 'etc'
        $conf.targets[0].path     | Should -Be '/etc/nginx'
        $conf.targets[0].os       | Should -Be 'both'
        $conf.targets[0].depth    | Should -Be 'unlimited'
        $conf.targets[0].exclude  | Should -BeNullOrEmpty
        $conf.targets[0].hash     | Should -Be $false
    }

    It 'parses depth as integer and unlimited' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @'
[target:a]
path  = /a
depth = 2

[target:b]
path  = /b
depth = unlimited

[target:c]
path  = /c
depth = notanumber
'@
        $env:_OPS_FILELIST_CONF = $f.FullName
        $conf = Read-FilelistConf
        ($conf.targets | Where-Object key -eq 'a').depth | Should -Be 2
        ($conf.targets | Where-Object key -eq 'b').depth | Should -Be 'unlimited'
        ($conf.targets | Where-Object key -eq 'c').depth | Should -Be 'unlimited'
    }

    It 'parses exclude as comma-separated globs (trimmed)' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @'
[target:x]
path    = /x
exclude = *.tmp , cache/* ,  *.log
'@
        $env:_OPS_FILELIST_CONF = $f.FullName
        $conf = Read-FilelistConf
        $conf.targets[0].exclude | Should -Be @('*.tmp','cache/*','*.log')
    }

    It 'parses hash as boolean' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @'
[target:y]
path = /y
hash = true

[target:z]
path = /z
hash = TRUE
'@
        $env:_OPS_FILELIST_CONF = $f.FullName
        $conf = Read-FilelistConf
        ($conf.targets | Where-Object key -eq 'y').hash | Should -Be $true
        ($conf.targets | Where-Object key -eq 'z').hash | Should -Be $true
    }

    It 'parses [limits] max_entries_per_target' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @'
[limits]
max_entries_per_target = 500
'@
        $env:_OPS_FILELIST_CONF = $f.FullName
        $conf = Read-FilelistConf
        $conf.max_entries_per_target | Should -Be 500
    }

    AfterAll { Remove-Item Env:_OPS_FILELIST_CONF -ErrorAction SilentlyContinue }
}
```

- [ ] **Step 2: テスト失敗を確認**

Run: `Invoke-Pester -Path tests/Filelist.Config.Tests.ps1`
Expected: FAIL — `Read-FilelistConf` が未定義

- [ ] **Step 3: `Read-FilelistConf` を実装**

Insert after line 609（`Read-MwConf` の閉じ括弧の直後）in `tools/server-snapshot/ServerSnapshot.ps1`:

```powershell
function Read-FilelistConf {
    # Parse filelist.conf: returns @{ targets = @(...); max_entries_per_target = <int> }
    # Each target: @{ key; path; os; depth; exclude; hash }
    $conf = @{
        targets = @()
        max_entries_per_target = 100000
    }
    $path = if ($env:_OPS_FILELIST_CONF) { $env:_OPS_FILELIST_CONF } else { Join-Path $PSScriptRoot 'filelist.conf' }
    if (-not (Test-Path -LiteralPath $path)) { return $conf }

    $section = ''
    $currentKey = ''
    $current = $null
    $targets = @()

    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            # Save previous target before switching section
            if ($current -ne $null) { $targets += ,$current; $current = $null }
            $header = $Matches[1].Trim()
            if ($header -match '^target:(.+)$') {
                $currentKey = $Matches[1].Trim()
                $current = @{
                    key     = $currentKey
                    path    = ''
                    os      = 'both'
                    depth   = 'unlimited'
                    exclude = @()
                    hash    = $false
                }
                $section = 'target'
            } else {
                $section = $header.ToLower()
            }
            continue
        }
        $kv = $t -split '=', 2
        if ($kv.Count -lt 2) { continue }
        $key = $kv[0].Trim().ToLower()
        $val = $kv[1].Trim()

        if ($section -eq 'target' -and $current -ne $null) {
            switch ($key) {
                'path'    { $current.path = $val }
                'os'      {
                    $v = $val.ToLower()
                    if ($v -in @('windows','linux','both')) { $current.os = $v }
                }
                'depth'   {
                    if ($val -match '^\s*unlimited\s*$') { $current.depth = 'unlimited' }
                    else {
                        $n = 0
                        if ([int]::TryParse($val, [ref]$n) -and $n -ge 0) { $current.depth = $n }
                        else { $current.depth = 'unlimited' }
                    }
                }
                'exclude' {
                    $list = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    $current.exclude = $list
                }
                'hash'    { $current.hash = ($val.ToLower() -eq 'true') }
            }
        }
        elseif ($section -eq 'limits' -and $key -eq 'max_entries_per_target') {
            $n = 0
            if ([int]::TryParse($val, [ref]$n) -and $n -gt 0) { $conf.max_entries_per_target = $n }
        }
    }
    if ($current -ne $null) { $targets += ,$current }
    $conf.targets = $targets
    return $conf
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `Invoke-Pester -Path tests/Filelist.Config.Tests.ps1`
Expected: PASS（全 5 It 通過）

- [ ] **Step 5: コミット**

```bash
git add tools/server-snapshot/ServerSnapshot.ps1 tests/Filelist.Config.Tests.ps1
git commit -m "feat(server-snapshot): add Read-FilelistConf parser"
```

---

## Task 3: `Get-FilelistInfo`（Windows）単一ファイル・ディレクトリのメタデータ取得

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Read-FilelistConf` の後に挿入）
- Test: `tests/Filelist.Collect.Tests.ps1`

- [ ] **Step 1: 失敗するテストを書く**

Create `tests/Filelist.Collect.Tests.ps1`:

```powershell
$Script = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'

Describe 'Get-FilelistInfo (Windows metadata basics)' {
    BeforeAll {
        # Dot-source the script to expose functions
        . $Script *> $null 2>&1
    }

    BeforeEach {
        $script:TmpRoot = Join-Path $env:TEMP ("filelist-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:_OPS_FILELIST_CONF -ErrorAction SilentlyContinue
    }

    It 'returns empty array when no filelist.conf' {
        $env:_OPS_FILELIST_CONF = Join-Path $env:TEMP 'nope.conf'
        $result = Get-FilelistInfo
        ,$result | Should -BeOfType [System.Array]
        $result.Count | Should -Be 0
    }

    It 'marks nonexistent path with exists=false' {
        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:missing]
path = $($script:TmpRoot)\does-not-exist
os   = both
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $result.Count | Should -Be 1
        $result[0].key        | Should -Be 'missing'
        $result[0].exists     | Should -Be $false
        $result[0].entries.Count | Should -Be 0
    }

    It 'marks os mismatch with os_matched=false and skips scan' {
        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:linuxonly]
path = $($script:TmpRoot)
os   = linux
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $result.Count | Should -Be 1
        $result[0].os_matched | Should -Be $false
        $result[0].entries.Count | Should -Be 0
    }

    It 'records file entry with owner and acl on Windows' {
        $target = Join-Path $script:TmpRoot 'data'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'a.txt') -Value 'hello'

        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path = $target
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $result.Count | Should -Be 1
        $result[0].exists     | Should -Be $true
        $result[0].os_matched | Should -Be $true

        $file = $result[0].entries | Where-Object { $_.rel_path -eq 'a.txt' }
        $file            | Should -Not -BeNullOrEmpty
        $file.type       | Should -Be 'file'
        $file.size       | Should -Be 5
        $file.owner      | Should -Not -BeNullOrEmpty
        $file.mode       | Should -BeNullOrEmpty     # POSIX mode is null on Windows
        $file.uid        | Should -BeNullOrEmpty
        $file.acl        | Should -Not -BeNullOrEmpty
        $file.acl.Count  | Should -BeGreaterThan 0
        $file.sha256     | Should -BeNullOrEmpty     # hash disabled by default
    }

    It 'computes sha256 when hash=true' {
        $target = Join-Path $script:TmpRoot 'h'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'a.txt') -Value 'hello' -NoNewline

        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path = $target
hash = true
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $file = $result[0].entries | Where-Object { $_.rel_path -eq 'a.txt' }
        # sha256 of "hello" (no newline) = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        $file.sha256 | Should -Be '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
    }
}
```

- [ ] **Step 2: テスト失敗を確認**

Run: `Invoke-Pester -Path tests/Filelist.Collect.Tests.ps1`
Expected: FAIL — `Get-FilelistInfo` が未定義

- [ ] **Step 3: `Get-FilelistInfo` と補助関数を実装**

Insert after `Read-FilelistConf` in `tools/server-snapshot/ServerSnapshot.ps1`:

```powershell
function Get-FilelistEntryMeta {
    # Build a single entry hashtable from a FileSystemInfo (file, dir, or symlink).
    # $item is the FileSystemInfo of the entry itself; $relPath is the rel-path from target root.
    param([System.IO.FileSystemInfo]$item, [string]$relPath, [bool]$computeHash)

    $isSymlink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    $isDir     = $item -is [System.IO.DirectoryInfo]
    $type      = if ($isSymlink) { 'symlink' } elseif ($isDir) { 'dir' } else { 'file' }

    $entry = [ordered]@{
        rel_path    = $relPath
        type        = $type
        size        = $null
        mtime       = $null
        mode        = $null      # POSIX-only, always null on Windows
        uid         = $null
        gid         = $null
        owner       = $null
        group       = $null      # Windows has no primary group in this sense
        acl         = $null
        sha256      = $null
        link_target = $null
    }
    try { $entry.mtime = $item.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ") } catch {}
    if ($type -eq 'file') {
        try { $entry.size = [int64]$item.Length } catch {}
    }
    if ($isSymlink) {
        try { $entry.link_target = $item.Target } catch {}
    }

    # Owner + ACL via Get-Acl (best-effort; permission failures leave fields null)
    try {
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        $entry.owner = "$($acl.Owner)"
        $aceList = @()
        foreach ($ace in $acl.Access) {
            $aceList += [ordered]@{
                principal = "$($ace.IdentityReference)"
                rights    = "$($ace.FileSystemRights)"
                type      = "$($ace.AccessControlType)"
            }
        }
        $entry.acl = $aceList
    } catch {
        # Leave owner / acl null; caller records the error separately
        throw
    }

    if ($computeHash -and $type -eq 'file') {
        try {
            $h = Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop
            $entry.sha256 = $h.Hash.ToLower()
        } catch { }
    }

    return $entry
}

function Test-FilelistExclude {
    # Match relPath against any glob in $globs; returns $true if excluded.
    param([string]$relPath, [string[]]$globs)
    if (-not $globs -or $globs.Count -eq 0) { return $false }
    $forward = $relPath -replace '\\','/'
    foreach ($g in $globs) {
        # Use PowerShell -like against forward-slash form
        if ($forward -like $g) { return $true }
        # Also match against basename for patterns without slash
        if ($g -notmatch '/' -and (Split-Path $forward -Leaf) -like $g) { return $true }
    }
    return $false
}

function Get-FilelistTarget {
    param(
        [hashtable]$target,
        [int]$maxEntries
    )
    $result = [ordered]@{
        key          = $target.key
        path         = $target.path
        os_matched   = $true
        exists       = $false
        depth        = $target.depth
        hash_enabled = [bool]$target.hash
        excluded     = @($target.exclude)
        entries      = @()
        entry_count  = 0
        truncated    = $false
        errors       = @()
    }

    # OS filter
    if ($target.os -eq 'linux') {
        $result.os_matched = $false
        return $result
    }

    # Path existence
    if (-not $target.path -or -not (Test-Path -LiteralPath $target.path)) {
        return $result
    }
    $result.exists = $true

    $rootFull = (Get-Item -LiteralPath $target.path).FullName
    $rootLen  = $rootFull.Length
    $limit    = if ($target.depth -eq 'unlimited') { [int]::MaxValue } else { [int]$target.depth }

    # BFS / DFS by manual recursion so we can enforce depth + exclude + max_entries.
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@{ dir = $rootFull; depth = 0 })
    $entries = New-Object System.Collections.Generic.List[object]

    while ($stack.Count -gt 0 -and -not $result.truncated) {
        $frame = $stack.Pop()
        $curDir = $frame.dir
        $curDepth = $frame.depth

        # List children of curDir (non-recursive)
        $children = $null
        try {
            $children = Get-ChildItem -LiteralPath $curDir -Force -ErrorAction Stop
        } catch {
            $rel = if ($curDir.Length -gt $rootLen) { $curDir.Substring($rootLen).TrimStart('\','/') } else { '' }
            $result.errors += @{ rel_path = $rel; reason = 'permission_denied' }
            continue
        }

        foreach ($child in $children) {
            if ($result.truncated) { break }
            $full = $child.FullName
            $rel  = $full.Substring($rootLen).TrimStart('\','/')
            if (Test-FilelistExclude -relPath $rel -globs $target.exclude) { continue }

            $isSymlink = ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            $isDir     = $child -is [System.IO.DirectoryInfo]

            try {
                $entry = Get-FilelistEntryMeta -item $child -relPath $rel -computeHash $result.hash_enabled
                $entries.Add($entry) | Out-Null
                if ($entries.Count -ge $maxEntries) {
                    $result.truncated = $true
                    break
                }
            } catch {
                $result.errors += @{ rel_path = $rel; reason = 'permission_denied' }
                continue
            }

            # Recurse into directories only (not symlinks) if depth allows
            if ($isDir -and -not $isSymlink -and ($curDepth + 1) -lt $limit) {
                $stack.Push(@{ dir = $full; depth = $curDepth + 1 })
            }
        }
    }

    # Deterministic ordering by rel_path
    $result.entries     = @($entries | Sort-Object -Property { $_.rel_path })
    $result.entry_count = $result.entries.Count
    return $result
}

function Get-FilelistInfo {
    Write-Host '  Collecting: filelist ...'
    $conf = Read-FilelistConf
    $results = @()
    foreach ($t in $conf.targets) {
        $results += ,(Get-FilelistTarget -target $t -maxEntries $conf.max_entries_per_target)
    }
    return @($results)
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `Invoke-Pester -Path tests/Filelist.Collect.Tests.ps1`
Expected: PASS（全 5 It 通過）

- [ ] **Step 5: コミット**

```bash
git add tools/server-snapshot/ServerSnapshot.ps1 tests/Filelist.Collect.Tests.ps1
git commit -m "feat(server-snapshot): implement Get-FilelistInfo for Windows"
```

---

## Task 4: depth / exclude / truncation の詳細テスト（Windows）

**Files:**
- Modify: `tests/Filelist.Collect.Tests.ps1`（既存 Describe に It を追加）

- [ ] **Step 1: 失敗するテストを追加**

Append to `tests/Filelist.Collect.Tests.ps1` inside `Describe 'Get-FilelistInfo (Windows metadata basics)'`:

```powershell
    It 'respects depth=0 (root children only, no recursion)' {
        $target = Join-Path $script:TmpRoot 'depth0'
        New-Item -ItemType Directory -Path (Join-Path $target 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'top.txt')          -Value 'x'
        Set-Content -LiteralPath (Join-Path $target 'sub\nested.txt')   -Value 'y'

        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path  = $target
depth = 0
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $rels = $result[0].entries | ForEach-Object { $_.rel_path }
        $rels | Should -Contain 'top.txt'
        $rels | Should -Contain 'sub'
        $rels | Should -Not -Contain 'sub\nested.txt'
    }

    It 'respects depth=1 (one level of recursion)' {
        $target = Join-Path $script:TmpRoot 'depth1'
        New-Item -ItemType Directory -Path (Join-Path $target 'sub\deep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'sub\nested.txt')      -Value 'y'
        Set-Content -LiteralPath (Join-Path $target 'sub\deep\deeper.txt') -Value 'z'

        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path  = $target
depth = 1
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $rels = $result[0].entries | ForEach-Object { $_.rel_path }
        $rels | Should -Contain 'sub\nested.txt'
        $rels | Should -Not -Contain 'sub\deep\deeper.txt'
    }

    It 'respects exclude glob on filenames' {
        $target = Join-Path $script:TmpRoot 'excl-file'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt')   -Value 'k'
        Set-Content -LiteralPath (Join-Path $target 'drop.tmp')   -Value 'd'

        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path    = $target
exclude = *.tmp
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $rels = $result[0].entries | ForEach-Object { $_.rel_path }
        $rels | Should -Contain 'keep.txt'
        $rels | Should -Not -Contain 'drop.tmp'
    }

    It 'respects exclude glob on directory subtree (cache/*)' {
        $target = Join-Path $script:TmpRoot 'excl-dir'
        New-Item -ItemType Directory -Path (Join-Path $target 'cache') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt')          -Value 'k'
        Set-Content -LiteralPath (Join-Path $target 'cache\file.dat')    -Value 'c'

        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path    = $target
exclude = cache,cache/*
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $rels = $result[0].entries | ForEach-Object { $_.rel_path }
        $rels | Should -Contain 'keep.txt'
        $rels | Should -Not -Contain 'cache'
        $rels | Should -Not -Contain 'cache\file.dat'
    }

    It 'sets truncated=true when max_entries_per_target reached' {
        $target = Join-Path $script:TmpRoot 'trunc'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        1..10 | ForEach-Object { Set-Content -LiteralPath (Join-Path $target "f$_.txt") -Value 'x' }

        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path = $target

[limits]
max_entries_per_target = 3
"@
        $env:_OPS_FILELIST_CONF = $confPath
        $result = @(Get-FilelistInfo)
        $result[0].truncated   | Should -Be $true
        $result[0].entry_count | Should -Be 3
    }
```

- [ ] **Step 2: テスト実行**

Run: `Invoke-Pester -Path tests/Filelist.Collect.Tests.ps1`
Expected: 全 It 通過（Task 3 の 5 件 + 追加 5 件 = 10 件）

もし exclude / depth / truncation のいずれかが失敗する場合は、`Get-FilelistTarget` の該当ロジックを修正:

- 「`exclude = cache,cache/*` で `cache` ディレクトリ自体もスキップ」が失敗する場合 → `Test-FilelistExclude` の basename マッチが `cache`（ディレクトリ）にも効いていることを確認
- 「truncated 時に `entry_count = 3`」が失敗する場合 → 走査ループの break 条件を見直し

- [ ] **Step 3: コミット**

```bash
git add tests/Filelist.Collect.Tests.ps1 tools/server-snapshot/ServerSnapshot.ps1
git commit -m "test(server-snapshot): depth/exclude/truncation coverage for filelist"
```

---

## Task 5: `Invoke-Collect` への統合（Windows）

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1:731,760-774`
- Test: `tests/Filelist.Integration.Tests.ps1`

- [ ] **Step 1: 失敗する統合テストを書く**

Create `tests/Filelist.Integration.Tests.ps1`:

```powershell
$Script = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'

Describe 'filelist integration in collect' {
    BeforeEach {
        $script:TmpRoot = Join-Path $env:TEMP ("filelist-int-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null
        $script:OutFile = Join-Path $script:TmpRoot 'snap.json'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:_OPS_FILELIST_CONF -ErrorAction SilentlyContinue
    }

    It 'includes filelist in -Category all output' {
        $target = Join-Path $script:TmpRoot 'data'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'a.txt') -Value 'x'
        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value @"
[target:t]
path = $target
"@
        $env:_OPS_FILELIST_CONF = $confPath

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script `
            collect -Category filelist -OutputPath $script:OutFile *> $null
        $LASTEXITCODE | Should -Be 0

        $json = Get-Content -LiteralPath $script:OutFile -Raw | ConvertFrom-Json
        $json.filelist.Count | Should -Be 1
        $json.filelist[0].key | Should -Be 't'
    }

    It 'omits filelist target scan when conf has no [target:*]' {
        $confPath = Join-Path $script:TmpRoot 'flist.conf'
        Set-Content -LiteralPath $confPath -Value ''
        $env:_OPS_FILELIST_CONF = $confPath

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script `
            collect -Category filelist -OutputPath $script:OutFile *> $null
        $LASTEXITCODE | Should -Be 0
        $json = Get-Content -LiteralPath $script:OutFile -Raw | ConvertFrom-Json
        $json.filelist | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: テスト失敗を確認**

Run: `Invoke-Pester -Path tests/Filelist.Integration.Tests.ps1`
Expected: FAIL — 出力 JSON に `filelist` キーが存在しない

- [ ] **Step 3: `Invoke-Collect` に `filelist` を追加**

Edit `tools/server-snapshot/ServerSnapshot.ps1`:

行 731（`$allCategories = @(...)`）:

```powershell
    $allCategories = @('os','network','services','packages','users','filesystem','environment','security','patches','tuning','scheduled','middleware','filelist')
```

行 760-774 の switch に 1 行追加:

```powershell
    foreach ($cat in $resolved) {
        $result[$cat] = switch ($cat) {
            'os'          { Get-OsInfo }
            'network'     { Get-NetworkInfo }
            'services'    { Get-ServicesInfo }
            'packages'    { Get-PackagesInfo }
            'users'       { Get-UsersInfo }
            'filesystem'  { Get-FilesystemInfo }
            'environment' { Get-EnvironmentInfo }
            'security'    { Get-SecurityInfo }
            'patches'     { Get-PatchesInfo }
            'tuning'      { Get-TuningInfo }
            'scheduled'   { Get-ScheduledInfo }
            'middleware'  { Get-MiddlewareInfo }
            'filelist'    { Get-FilelistInfo }
        }
    }
```

- [ ] **Step 4: テスト通過を確認**

Run: `Invoke-Pester -Path tests/Filelist.Integration.Tests.ps1`
Expected: PASS（2/2）

- [ ] **Step 5: コミット**

```bash
git add tools/server-snapshot/ServerSnapshot.ps1 tests/Filelist.Integration.Tests.ps1
git commit -m "feat(server-snapshot): wire filelist into Invoke-Collect (Windows)"
```

---

## Task 6: `Compare-Filelist`（Windows）

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Compare-Middleware` の後、行 1053 付近に挿入）
- Modify: `tools/server-snapshot/ServerSnapshot.ps1:1250,1261-1274`
- Test: `tests/Filelist.Compare.Tests.ps1`

- [ ] **Step 1: 失敗するテストを書く**

Create `tests/Filelist.Compare.Tests.ps1`:

```powershell
$Script = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'

Describe 'Compare-Filelist' {
    BeforeAll { . $Script *> $null 2>&1 }

    function New-FilelistCat {
        param([hashtable[]]$targets)
        return ,$targets
    }

    It 'detects ADDED target' {
        $b = New-FilelistCat @()
        $a = New-FilelistCat @(@{ key='new'; path='/tmp/new'; os_matched=$true; exists=$true; hash_enabled=$false; entries=@(); truncated=$false })
        $r = @(Compare-Filelist $b $a)
        $catNames = $r | ForEach-Object { $_.Name }
        $catNames | Should -Contain 'filelist/new'
        ($r | Where-Object Name -eq 'filelist/new').AddedCount + `
            ($r | Where-Object Name -eq 'filelist/new').ChangedCount | Should -BeGreaterOrEqual 0
    }

    It 'detects REMOVED entry within a target' {
        $b = New-FilelistCat @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
            entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='root' });
            truncated=$false })
        $a = New-FilelistCat @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
            entries=@(); truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object Name -eq 'filelist/t').RemovedCount | Should -Be 1
    }

    It 'detects CHANGED when owner differs' {
        $b = New-FilelistCat @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
            entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='root' });
            truncated=$false })
        $a = New-FilelistCat @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
            entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='admin' });
            truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object Name -eq 'filelist/t').ChangedCount | Should -Be 1
    }

    It 'compares sha256 only when hash_enabled=true on both sides' {
        $b = New-FilelistCat @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
            entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='aaa' });
            truncated=$false })
        $a = New-FilelistCat @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
            entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='bbb' });
            truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object Name -eq 'filelist/t').ChangedCount | Should -Be 1
    }
}
```

- [ ] **Step 2: テスト失敗を確認**

Run: `Invoke-Pester -Path tests/Filelist.Compare.Tests.ps1`
Expected: FAIL — `Compare-Filelist` が未定義

- [ ] **Step 3: `Compare-Filelist` を実装**

Insert after `Compare-Middleware` (行 1052 の閉じ括弧の後) in `tools/server-snapshot/ServerSnapshot.ps1`:

```powershell
function Compare-Filelist($b, $a) {
    # $b / $a are arrays of target objects (from snapshot.filelist).
    $results = [System.Collections.Generic.List[CategoryResult]]::new()

    $bArr = @(As-Array $b | ForEach-Object { Obj-To-Dict $_ })
    $aArr = @(As-Array $a | ForEach-Object { Obj-To-Dict $_ })

    $bByKey = @{}
    foreach ($t in $bArr) { $k = "$($t['key'])"; if ($k) { $bByKey[$k] = $t } }
    $aByKey = @{}
    foreach ($t in $aArr) { $k = "$($t['key'])"; if ($k) { $aByKey[$k] = $t } }

    $allKeys = @($bByKey.Keys) + @($aByKey.Keys) | Sort-Object -Unique

    foreach ($key in $allKeys) {
        $catName = "filelist/$key"
        $bt = $bByKey[$key]
        $at = $aByKey[$key]

        if (-not $bt) {
            # entire target added → treat as one ADDED row per entry
            $entries = @(As-Array $at['entries'] | ForEach-Object { Obj-To-Dict $_ })
            $rows = @($entries | ForEach-Object {
                $h = @{ name = "$($_['rel_path'])" }
                foreach ($f in @('type','size','mtime','mode','owner','group','sha256')) { $h[$f] = "$($_[$f])" }
                $h
            })
            $results.Add((Compare-List @() $rows 'name' @('type','size','mtime','mode','owner','group','sha256') $catName))
            continue
        }
        if (-not $at) {
            $entries = @(As-Array $bt['entries'] | ForEach-Object { Obj-To-Dict $_ })
            $rows = @($entries | ForEach-Object {
                $h = @{ name = "$($_['rel_path'])" }
                foreach ($f in @('type','size','mtime','mode','owner','group','sha256')) { $h[$f] = "$($_[$f])" }
                $h
            })
            $results.Add((Compare-List $rows @() 'name' @('type','size','mtime','mode','owner','group','sha256') $catName))
            continue
        }

        # both sides present → entry-level diff
        $bEntries = @(As-Array $bt['entries'] | ForEach-Object { Obj-To-Dict $_ })
        $aEntries = @(As-Array $at['entries'] | ForEach-Object { Obj-To-Dict $_ })
        $bHash = [bool]$bt['hash_enabled']
        $aHash = [bool]$at['hash_enabled']
        $bothHash = $bHash -and $aHash

        $fields = @('type','size','mtime','mode','owner','group')
        if ($bothHash) { $fields += 'sha256' }

        $bRows = @($bEntries | ForEach-Object {
            $h = @{ name = "$($_['rel_path'])" }
            foreach ($f in $fields) { $h[$f] = "$($_[$f])" }
            $h
        })
        $aRows = @($aEntries | ForEach-Object {
            $h = @{ name = "$($_['rel_path'])" }
            foreach ($f in $fields) { $h[$f] = "$($_[$f])" }
            $h
        })
        $results.Add((Compare-List $bRows $aRows 'name' $fields $catName))
    }
    return $results
}
```

- [ ] **Step 4: `Invoke-Compare` に登録**

Edit 行 1250:

```powershell
    $allCats   = @('os','network','services','packages','users','filesystem','environment','security','patches','tuning','scheduled','middleware','filelist')
```

Edit 行 1261-1274 の switch に 1 行追加:

```powershell
            'middleware'  { @(Compare-Middleware  $bCat $aCat) }
            'filelist'    { @(Compare-Filelist    $bCat $aCat) }
```

- [ ] **Step 5: テスト通過を確認**

Run: `Invoke-Pester -Path tests/Filelist.Compare.Tests.ps1`
Expected: PASS（4/4）

- [ ] **Step 6: コミット**

```bash
git add tools/server-snapshot/ServerSnapshot.ps1 tests/Filelist.Compare.Tests.ps1
git commit -m "feat(server-snapshot): implement Compare-Filelist and wire into Invoke-Compare"
```

---

## Task 7: Linux 側 `_load_filelist_conf` + `collect_filelist`

**Files:**
- Modify: `tools/server-snapshot/server_snapshot.sh`（Python 埋め込みブロック内、`collect_middleware` の後、行 832 付近）
- Modify: `tools/server-snapshot/server_snapshot.sh:146`（`export _OPS_FILELIST_CONF` 追加）
- Modify: `tools/server-snapshot/server_snapshot.sh:834-840`（`CAT_MAP` 登録）

（Linux 単体テストは Bats / pytest 資産がプロジェクトに無いため、smoke 実行で検証する。手元 Windows では skip 可能。）

- [ ] **Step 1: `_OPS_FILELIST_CONF` の export を追加**

Edit `tools/server-snapshot/server_snapshot.sh` 行 146 の直後:

```bash
    export _OPS_MW_CONF="${SCRIPT_DIR}/middleware.conf"   # consumed by _mw_load_conf (MW2)
    export _OPS_FILELIST_CONF="${SCRIPT_DIR}/filelist.conf"
```

- [ ] **Step 2: Python 埋め込みブロックに `_load_filelist_conf` を追加**

Insert into the `python3 - << 'PYEOF'` block, after `def collect_middleware():` (around line 832):

```python
# ─────────────── filelist collector ───────────────
def _load_filelist_conf():
    conf = {'targets': [], 'max_entries_per_target': 100000}
    path = os.environ.get('_OPS_FILELIST_CONF', '')
    if not path or not os.path.isfile(path):
        return conf
    section = ''
    current = None
    targets = []
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            for raw in f:
                t = raw.strip()
                if not t or t.startswith('#'): continue
                m = re.match(r'^\[(.+)\]$', t)
                if m:
                    if current is not None:
                        targets.append(current); current = None
                    header = m.group(1).strip()
                    tm = re.match(r'^target:(.+)$', header)
                    if tm:
                        current = {
                            'key': tm.group(1).strip(),
                            'path': '', 'os': 'both', 'depth': 'unlimited',
                            'exclude': [], 'hash': False,
                        }
                        section = 'target'
                    else:
                        section = header.lower()
                    continue
                if '=' not in t: continue
                k, v = t.split('=', 1); k = k.strip().lower(); v = v.strip()
                if section == 'target' and current is not None:
                    if k == 'path': current['path'] = v
                    elif k == 'os' and v.lower() in ('windows','linux','both'):
                        current['os'] = v.lower()
                    elif k == 'depth':
                        if v.lower() == 'unlimited': current['depth'] = 'unlimited'
                        else:
                            try: n = int(v);  current['depth'] = n if n >= 0 else 'unlimited'
                            except ValueError: current['depth'] = 'unlimited'
                    elif k == 'exclude':
                        current['exclude'] = [g.strip() for g in v.split(',') if g.strip()]
                    elif k == 'hash':
                        current['hash'] = (v.lower() == 'true')
                elif section == 'limits' and k == 'max_entries_per_target':
                    try:
                        n = int(v)
                        if n > 0: conf['max_entries_per_target'] = n
                    except ValueError: pass
    except Exception:
        return conf
    if current is not None: targets.append(current)
    conf['targets'] = targets
    return conf

def _filelist_matches_exclude(rel_path, globs):
    if not globs: return False
    forward = rel_path.replace('\\','/')
    import fnmatch as _fn
    for g in globs:
        if _fn.fnmatch(forward, g): return True
        if '/' not in g and _fn.fnmatch(os.path.basename(forward), g): return True
    return False

def _filelist_entry_meta(full_path, rel_path, compute_hash):
    import stat as _st
    try:
        st = os.lstat(full_path)
    except OSError:
        raise
    is_link = _st.S_ISLNK(st.st_mode)
    is_dir  = _st.S_ISDIR(st.st_mode) and not is_link
    entry_type = 'symlink' if is_link else ('dir' if is_dir else 'file')

    entry = {
        'rel_path': rel_path, 'type': entry_type,
        'size': None, 'mtime': None,
        'mode': None, 'uid': None, 'gid': None,
        'owner': None, 'group': None, 'acl': None,
        'sha256': None, 'link_target': None,
    }
    entry['mtime'] = datetime.datetime.utcfromtimestamp(st.st_mtime).strftime('%Y-%m-%dT%H:%M:%SZ')
    entry['mode'] = format(st.st_mode & 0o7777, '04o')
    entry['uid']  = int(st.st_uid)
    entry['gid']  = int(st.st_gid)
    try:
        import pwd
        entry['owner'] = pwd.getpwuid(st.st_uid).pw_name
    except Exception: entry['owner'] = str(st.st_uid)
    try:
        import grp
        entry['group'] = grp.getgrgid(st.st_gid).gr_name
    except Exception: entry['group'] = str(st.st_gid)
    if entry_type == 'file':
        entry['size'] = int(st.st_size)
        if compute_hash:
            try:
                import hashlib
                h = hashlib.sha256()
                with open(full_path, 'rb') as f:
                    for chunk in iter(lambda: f.read(65536), b''): h.update(chunk)
                entry['sha256'] = h.hexdigest()
            except Exception: pass
    if entry_type == 'symlink':
        try: entry['link_target'] = os.readlink(full_path)
        except OSError: pass
    return entry

def _filelist_scan_target(target, max_entries):
    result = {
        'key': target['key'], 'path': target['path'],
        'os_matched': True, 'exists': False,
        'depth': target['depth'], 'hash_enabled': bool(target['hash']),
        'excluded': list(target.get('exclude') or []),
        'entries': [], 'entry_count': 0, 'truncated': False, 'errors': [],
    }
    if target['os'] == 'windows':
        result['os_matched'] = False; return result
    if not target['path'] or not os.path.exists(target['path']):
        return result
    result['exists'] = True
    root = os.path.abspath(target['path'])
    root_len = len(root)
    limit = float('inf') if target['depth'] == 'unlimited' else int(target['depth'])
    stack = [(root, 0)]
    entries = []
    truncated = False
    while stack and not truncated:
        cur_dir, cur_depth = stack.pop()
        try:
            names = os.listdir(cur_dir)
        except OSError:
            rel = cur_dir[root_len:].lstrip(os.sep)
            result['errors'].append({'rel_path': rel, 'reason': 'permission_denied'})
            continue
        names.sort()
        for name in names:
            if truncated: break
            full = os.path.join(cur_dir, name)
            rel = full[root_len:].lstrip(os.sep)
            if _filelist_matches_exclude(rel, target.get('exclude') or []):
                continue
            try:
                entry = _filelist_entry_meta(full, rel, result['hash_enabled'])
            except OSError:
                result['errors'].append({'rel_path': rel, 'reason': 'permission_denied'})
                continue
            entries.append(entry)
            if len(entries) >= max_entries:
                truncated = True; break
            import stat as _st
            try:
                st = os.lstat(full)
                if _st.S_ISDIR(st.st_mode) and not _st.S_ISLNK(st.st_mode) and (cur_depth + 1) < limit:
                    stack.append((full, cur_depth + 1))
            except OSError: pass
    entries.sort(key=lambda e: e['rel_path'])
    result['entries'] = entries
    result['entry_count'] = len(entries)
    result['truncated'] = truncated
    return result

def collect_filelist():
    conf = _load_filelist_conf()
    return [_filelist_scan_target(t, conf['max_entries_per_target']) for t in conf['targets']]
```

- [ ] **Step 3: `CAT_MAP` に登録**

Edit `server_snapshot.sh` 行 834-840:

```python
CAT_MAP = {
    'os': collect_os, 'network': collect_network, 'services': collect_services,
    'packages': collect_packages, 'users': collect_users, 'filesystem': collect_filesystem,
    'environment': collect_environment, 'security': collect_security,
    'patches': collect_patches, 'tuning': collect_tuning, 'scheduled': collect_scheduled,
    'middleware': collect_middleware, 'filelist': collect_filelist,
}
```

- [ ] **Step 4: Linux 上での smoke 実行を確認**

（Linux 環境が手元にない場合、下記コマンドは Linux 相当環境（WSL 等）または EC2 で実行して確認する）

```bash
cd tools/server-snapshot
mkdir -p /tmp/flist-smoke/data
echo hello > /tmp/flist-smoke/data/a.txt

cat > /tmp/flist-smoke.conf << 'EOF'
[target:t]
path = /tmp/flist-smoke/data
os   = linux
hash = true
EOF

_OPS_FILELIST_CONF=/tmp/flist-smoke.conf ./server_snapshot.sh collect -c filelist -o /tmp/flist-smoke.json
python3 -c "import json; d=json.load(open('/tmp/flist-smoke.json')); print(json.dumps(d['filelist'], indent=2))"
```

Expected: `filelist` 配列に `key='t'` の 1 対象、`entries` に `a.txt` が含まれ、`owner` / `group` / `mode` / `sha256` が入っている。

Windows 環境で smoke 不可の場合はこのステップを skip し、後続の Task 9 の end-to-end テストでカバーする。

- [ ] **Step 5: コミット**

```bash
git add tools/server-snapshot/server_snapshot.sh
git commit -m "feat(server-snapshot): implement collect_filelist for Linux"
```

---

## Task 8: Python 側 `cat_filelist` を `compare_server_info.py` に追加

**Files:**
- Modify: `tools/server-snapshot/compare_server_info.py`（`cat_middleware` の後、行 228 付近）
- Modify: `tools/server-snapshot/compare_server_info.py:229-242`

**規約確認**: `compare_list`（`compare_server_info.py:63`）は `[(state, key, before, after)]` のタプル配列を返す。`CATEGORIES` のカテゴリ関数（例 `cat_middleware`）は、複数の対象・製品からまとめて **1 つのフラットなタプル配列** を返す。カテゴリ名は `CATEGORIES` タプルで固定（例 `'middleware'`）で、サブカテゴリはタプルの `key` 側にプレフィクス（例 `hana-instance-01::/path/to/config.ini`）として埋め込むのが既存パターン。`cat_filelist` も同様に、`key = "<target_key>::<rel_path>"` の形式で 1 フラット配列を返す。

- [ ] **Step 1: `cat_filelist` を追加**

Insert after `cat_middleware` (before `CATEGORIES = [...]`) in `tools/server-snapshot/compare_server_info.py`:

```python
def cat_filelist(b, a):
    """Compare filelist categories. Returns [(state, key, before, after)].

    key format: '<target_key>::<rel_path>' (mirrors cat_middleware's file-key convention).
    Differing hash_enabled between sides drops sha256 from the compared field set.
    """
    bl = b.get('filelist') or []
    al = a.get('filelist') or []
    if not isinstance(bl, list): bl = []
    if not isinstance(al, list): al = []
    b_by = {t.get('key'): t for t in bl if isinstance(t, dict) and t.get('key')}
    a_by = {t.get('key'): t for t in al if isinstance(t, dict) and t.get('key')}
    out = []
    for key in sorted(set(list(b_by.keys()) + list(a_by.keys()))):
        bt = b_by.get(key)
        at = a_by.get(key)
        b_entries = (bt or {}).get('entries') or []
        a_entries = (at or {}).get('entries') or []
        b_hash = bool((bt or {}).get('hash_enabled'))
        a_hash = bool((at or {}).get('hash_enabled'))
        fields = ['type','size','mtime','mode','owner','group']
        if b_hash and a_hash:
            fields.append('sha256')

        def _rows(entries, target_key):
            rows = []
            for e in entries:
                if not isinstance(e, dict):
                    continue
                row = {'name': f"{target_key}::{e.get('rel_path')}"}
                for f in fields:
                    row[f] = e.get(f)
                rows.append(row)
            return rows

        b_rows = _rows(b_entries, key)
        a_rows = _rows(a_entries, key)
        out += compare_list(b_rows, a_rows, 'name', fields)
    return out
```

- [ ] **Step 2: `CATEGORIES` に登録**

Edit lines 229-242:

```python
CATEGORIES = [
    ('os',          cat_os),
    ('services',    cat_services),
    ('packages',    cat_packages),
    ('users',       cat_users),
    ('filesystem',  cat_filesystem),
    ('environment', cat_environment),
    ('network',     cat_network),
    ('security',    cat_security),
    ('patches',     cat_patches),
    ('tuning',      cat_tuning),
    ('scheduled',   cat_scheduled),
    ('middleware',  cat_middleware),
    ('filelist',    cat_filelist),
]
```

- [ ] **Step 3: Linux 上での compare smoke 実行**

```bash
# 前提: Task 7 の smoke で作った /tmp/flist-smoke.json を before として使う
cp /tmp/flist-smoke.json /tmp/flist-before.json
echo "world" >> /tmp/flist-smoke/data/a.txt
_OPS_FILELIST_CONF=/tmp/flist-smoke.conf ./server_snapshot.sh collect -c filelist -o /tmp/flist-after.json
./server_snapshot.sh compare /tmp/flist-before.json /tmp/flist-after.json
```

Expected: 出力に `filelist/t` セクションが表示され、`a.txt` の `size` / `mtime` / `sha256` の変化が CHANGED として検出される。

もし `cat_filelist` の戻り値形式が既存 `CATEGORIES` ループ（`compare_server_info.py:246` 以降）と噛み合わない場合、既存の `cat_middleware` を再度精読し、`out` の形式（各要素の必須キー: `state` / `key` / `before` / `after` / `category` 等）を厳密に合わせて修正する。

- [ ] **Step 4: コミット**

```bash
git add tools/server-snapshot/compare_server_info.py
git commit -m "feat(server-snapshot): add cat_filelist to compare engine"
```

---

## Task 9: README 更新と end-to-end 検証

**Files:**
- Modify: `tools/server-snapshot/README.md`
- Modify: `CHANGELOG.md`（プロジェクトルート）

- [ ] **Step 1: README のカテゴリ表に filelist 行を追加**

Edit `tools/server-snapshot/README.md`（現状 line 108-124 のカテゴリ表）:

`middleware` 行の後に追加:

```markdown
| `filelist`    | 指定ディレクトリ配下のファイル・ディレクトリ一覧（権限・オーナー付き） |
```

- [ ] **Step 2: `middleware` の説明セクションの後に `filelist` セクションを追加**

Append to `tools/server-snapshot/README.md` after the middleware config file section:

```markdown
---

## `filelist` カテゴリ

指定ディレクトリ配下のファイル・ディレクトリ一覧を、権限とオーナー情報付きで収集します。
設定ファイル `filelist.conf` で対象ディレクトリを列挙します。

### `filelist.conf` — 対象と収集オプション

| キー | 既定 | 説明 |
|---|---|---|
| `path` | 必須 | 対象ディレクトリの絶対パス |
| `os` | `both` | `windows` / `linux` / `both`。現OSに合わない場合、対象ごとスキップ |
| `depth` | `unlimited` | 整数（0 は対象ルート直下のみ）または `unlimited` |
| `exclude` | 空 | カンマ区切りの glob。対象ルートからの相対パスにマッチ。ディレクトリにマッチした場合は配下ごとスキップ |
| `hash` | `false` | `true` でファイル sha256 を計算 |
| `[limits] max_entries_per_target` | `100000` | 対象ごとのエントリ上限。到達時に `truncated=true` |

例:

```ini
[target:etc-nginx]
path    = /etc/nginx
os      = linux
depth   = unlimited
exclude = *.bak,cache/*

[target:appdata]
path    = C:\ProgramData\MyApp
os      = windows
depth   = 2
hash    = true
```

### 収集内容

各エントリは以下のメタデータを持ちます:

- 共通: `rel_path` / `type`（file/dir/symlink）/ `size` / `mtime`
- Linux: `mode`（8進）/ `uid` / `gid` / `owner` / `group`
- Windows: `owner`（NTFS Owner）/ `acl`（主要 ACE の配列）
- `hash=true` のとき: `sha256`
- symlink: `link_target`

**シンボリックリンクは追跡しません**（リンク自体のメタデータのみ記録）。
**ファイル内容は保存しません**（sha256 のみ、有効時）。

### 比較の挙動

before/after 比較では、`target.key` + `rel_path` をキーに突き合わせ、以下いずれかが変化したエントリを `CHANGED` とします:

- `type` / `size` / `mtime` / `mode` / `uid` / `gid` / `owner` / `group` / `acl`
- `sha256`（双方で `hash_enabled = true` のときのみ）

対象キー自体の追加・削除、および `truncated=true` の対象は結果に警告として表示されます。
```

- [ ] **Step 3: CHANGELOG 追記**

Edit `CHANGELOG.md` の Unreleased セクションに追加:

```markdown
### Added
- server-snapshot に `filelist` カテゴリを追加。設定ファイル `filelist.conf` で
  指定したディレクトリ配下のファイル・ディレクトリ一覧を権限・オーナー情報付きで
  収集し、before/after 比較で差分を検出できる。
```

- [ ] **Step 4: 全 Pester テストを実行**

Run: `Invoke-Pester -Path tests/`
Expected: 全テスト PASS（filelist 系 + 既存の Aws/Logger 系すべて）

- [ ] **Step 5: end-to-end 手動確認（Windows）**

```powershell
# 一時対象を用意
$tmp = "$env:TEMP\filelist-e2e"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Set-Content -LiteralPath "$tmp\a.txt" -Value "before"

# filelist.conf を差し替え
$conf = @"
[target:e2e]
path = $tmp
hash = true
"@
Set-Content -LiteralPath ".\tools\server-snapshot\filelist.conf" -Value $conf

# before → 変更 → after
Push-Location .\tools\server-snapshot
.\server_snapshot.bat before -Label e2e
Set-Content -LiteralPath "$tmp\a.txt" -Value "after-content"
Set-Content -LiteralPath "$tmp\new.txt" -Value "brand new"
.\server_snapshot.bat after -Label e2e -HtmlReport "$tmp\report.html"
Pop-Location
```

Expected: 
- `a.txt` が `CHANGED`（size / mtime / sha256）
- `new.txt` が `ADDED`
- HTML レポートに `filelist/e2e` セクションが含まれる

確認後、`filelist.conf` は空テンプレートに戻す:

```powershell
Set-Content -LiteralPath ".\tools\server-snapshot\filelist.conf" -Value @'
# server-snapshot filelist collection config.
# Empty by default: no targets → snapshot.filelist = [].
[limits]
max_entries_per_target = 100000
'@
```

- [ ] **Step 6: 生成物のクリーンアップ**

```bash
git status
# _e2e_ / _label_ の一時スナップショット JSON があれば削除
Remove-Item -Force *_e2e_*.json, *_before_e2e_*.json, *_after_e2e_*.json -ErrorAction SilentlyContinue
```

- [ ] **Step 7: コミット**

```bash
git add tools/server-snapshot/README.md tools/server-snapshot/filelist.conf CHANGELOG.md
git commit -m "docs(server-snapshot): document filelist category"
```

---

## 完了条件チェックリスト

- [ ] `filelist.conf` の空テンプレートが `tools/server-snapshot/` に存在
- [ ] `server_snapshot.bat collect -Category filelist` が Windows で動く
- [ ] `bash server_snapshot.sh collect -c filelist` が Linux で動く
- [ ] `before` / `after` 比較で追加・削除・権限・sha256 の変更が検出される
- [ ] HTML レポートに `filelist/<key>` セクションが表示される
- [ ] `-Category all` で他カテゴリと同時に収集され、既存カテゴリの結果に影響しない
- [ ] README にカテゴリ表と `filelist.conf` の説明が追記されている
- [ ] `Invoke-Pester -Path tests/` が全てグリーン
