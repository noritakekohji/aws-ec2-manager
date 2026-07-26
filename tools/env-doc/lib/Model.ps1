# 入力 JSON の読み込みと中間モデルの構築。
# レンダラは snapshot JSON を直接参照せず、ここで作るモデルのみを見る。

function Get-JsonValue {
    param($Object, [string]$Path, $Default = $null)

    $cur = $Object
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$seg]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Get-EnvDocJsonKind {
    param($Json)

    $tool = Get-JsonValue -Object $Json -Path 'meta.tool'
    if ($tool -eq 'aws_instance_audit') { return 'aws' }

    $osType = Get-JsonValue -Object $Json -Path 'meta.os_type'
    $cats   = Get-JsonValue -Object $Json -Path 'meta.categories'
    if ($null -ne $osType -and $null -ne $cats) { return 'snapshot' }

    return 'unknown'
}

function Read-EnvDocInput {
    param([Parameter(Mandatory)][string]$InputDir)

    if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
        throw "入力ディレクトリが見つかりません: $InputDir"
    }

    $result = @{
        Snapshots = @{}
        Aws       = @{}
        Warnings  = @()
    }

    $files = @(Get-ChildItem -LiteralPath $InputDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object Name)

    foreach ($f in $files) {
        # Get-Content は CP932 環境で日本語を破壊するため使わない
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        $json = $null
        try {
            $json = ConvertFrom-Json $text
        }
        catch {
            $result.Warnings += "$($f.Name): JSON として読めませんでした。スキップします"
            continue
        }

        $kind = Get-EnvDocJsonKind -Json $json
        if ($kind -eq 'unknown') {
            $result.Warnings += "$($f.Name): server-snapshot / aws-instance-audit のいずれでもありません。スキップします"
            continue
        }

        $hostName = [string](Get-JsonValue -Object $json -Path 'meta.hostname' -Default '')
        if ($hostName -eq '') {
            $result.Warnings += "$($f.Name): meta.hostname が空です。スキップします"
            continue
        }
        # Linux は小文字、Windows は大文字を返すため、キーは小文字に正規化する
        $key = $hostName.ToLowerInvariant()

        if ($kind -eq 'snapshot') {
            if ($result.Snapshots.ContainsKey($key)) {
                $result.Warnings += "$($f.Name): ホスト $hostName の snapshot が重複しています。後勝ちで上書きします"
            }
            $result.Snapshots[$key] = $json
        }
        else {
            if ($result.Aws.ContainsKey($key)) {
                $result.Warnings += "$($f.Name): ホスト $hostName の aws 監査が重複しています。後勝ちで上書きします"
            }
            $result.Aws[$key] = $json
        }
    }

    return $result
}

function Test-EnvDocCategory {
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)][string]$Category)

    if (-not $Server.HasSnapshot) { return $false }
    return (@($Server.Categories) -contains $Category)
}

function New-EnvDocServerEntry {
    param([string]$Hostname, $Definition, $Snapshot)

    $categories = @()
    $osType = 'unknown'
    $collectedAt = ''
    if ($null -ne $Snapshot) {
        $rawCats = Get-JsonValue -Object $Snapshot -Path 'meta.categories' -Default @()
        $categories = @($rawCats)
        # -Category all で収集した場合は 'all' が入りうるため、全カテゴリ扱いにする
        if ($categories -contains 'all') {
            # ServerSnapshot.ps1 の $allCategories と一致させること
            $categories = @('os', 'network', 'services', 'remote_access', 'packages', 'users',
                'filesystem', 'environment', 'security', 'patches', 'tuning', 'scheduled',
                'middleware', 'filelist')
        }
        $osType = [string](Get-JsonValue -Object $Snapshot -Path 'meta.os_type' -Default 'unknown')
        $collectedAt = [string](Get-JsonValue -Object $Snapshot -Path 'meta.collected_at' -Default '')
    }

    $getDef = {
        param([string]$Key, $Fallback)
        if ($null -eq $Definition) { return $Fallback }
        if (-not $Definition.Contains($Key)) { return $Fallback }
        $v = $Definition[$Key]
        if ($null -eq $v) { return $Fallback }
        return $v
    }

    return @{
        Hostname        = $Hostname
        Key             = $Hostname.ToLowerInvariant()
        Role            = [string](& $getDef 'role' '')
        Note            = [string](& $getDef 'note' '')
        ShowConfigs     = [bool](& $getDef 'show_configs' $false)
        ShowEnvironment = [bool](& $getDef 'show_environment' $false)
        OsType          = $osType
        Snapshot        = $Snapshot
        CollectedAt     = $collectedAt
        Categories      = $categories
        Aws             = $null
        HasSnapshot     = ($null -ne $Snapshot)
    }
}

function Build-EnvDocModel {
    param(
        [Parameter(Mandatory)]$SystemDef,
        [Parameter(Mandatory)][hashtable]$Inputs
    )

    $sys = $null
    if ($null -ne $SystemDef -and $SystemDef.Contains('system')) { $sys = $SystemDef['system'] }
    if ($null -eq $sys) { throw "system.yaml に system セクションがありません" }

    $sysId = [string]$sys['id']
    if ($sysId -notmatch '^[A-Za-z0-9_-]+$') {
        throw "system.id は半角英数・ハイフン・アンダースコアのみ使えます(現在: '$sysId')"
    }
    $sysName = [string]$sys['name']
    if ([string]::IsNullOrWhiteSpace($sysName)) { throw "system.name は必須です" }

    $warnings = @()
    $warnings += @($Inputs.Warnings)

    $servers = New-Object System.Collections.ArrayList
    $seen = @{}

    $defined = @()
    if ($SystemDef.Contains('servers') -and $null -ne $SystemDef['servers']) {
        $defined = @($SystemDef['servers'])
    }

    foreach ($def in $defined) {
        $hostName = [string]$def['hostname']
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            $warnings += 'servers に hostname の無い項目があります。スキップします'
            continue
        }
        $key = $hostName.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $warnings += "system.yaml でホスト $hostName が重複しています。最初の定義を使います"
            continue
        }
        $seen[$key] = $true

        $snap = $null
        if ($Inputs.Snapshots.ContainsKey($key)) { $snap = $Inputs.Snapshots[$key] }
        else { $warnings += "$hostName : system.yaml に定義されていますが snapshot がありません(未収集として掲載します)" }

        [void]$servers.Add((New-EnvDocServerEntry -Hostname $hostName -Definition $def -Snapshot $snap))
    }

    # snapshot にあるが system.yaml に無いサーバ = 定義漏れ。可視化のため末尾に足す
    foreach ($key in (@($Inputs.Snapshots.Keys) | Sort-Object)) {
        if ($seen.ContainsKey($key)) { continue }
        $snap = $Inputs.Snapshots[$key]
        $hostName = [string](Get-JsonValue -Object $snap -Path 'meta.hostname' -Default $key)
        $warnings += "$hostName : snapshot がありますが system.yaml に定義されていません(役割未設定で掲載します)"
        [void]$servers.Add((New-EnvDocServerEntry -Hostname $hostName -Definition $null -Snapshot $snap))
    }

    return @{
        System  = @{
            Id          = $sysId
            Name        = $sysName
            Owner       = [string]$sys['owner']
            Contact     = [string]$sys['contact']
            Description = [string]$sys['description']
            Diagram     = [string]$sys['diagram']
        }
        Servers = @($servers.ToArray())
        Aws     = $null
        Groups  = @()
        Meta    = @{
            GeneratedAt = [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
            Warnings    = $warnings
        }
    }
}
