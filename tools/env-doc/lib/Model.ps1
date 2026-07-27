# 入力 JSON の読み込みと中間モデルの構築。
# レンダラは Server.Snapshot(生 snapshot JSON)を Get-JsonValue 経由でのみ読む。
# 生 JSON を直接 ConvertFrom-Json するのはここ(Read-EnvDocInput)に閉じている。

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

    if ($result.Snapshots.Count -eq 0) {
        throw "入力ディレクトリに有効な snapshot JSON が見つかりません: $InputDir"
    }

    return $result
}

# hostname は servers/<hostname>.html としてファイルパスに埋まる。
# FQDN を許すため '.' は通すが、パス区切りと '..' は必ず弾く。
function Test-EnvDocHostname {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    # .NET の '$' は末尾の改行の直前にもマッチするため、終端は '\z' を使う
    if ($Name -notmatch '^[A-Za-z0-9._-]+\z') { return $false }
    if ($Name.Contains('..')) { return $false }
    if ($Name -eq '.') { return $false }
    return $true
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
    # .NET の '$' は末尾の改行の直前にもマッチするため、終端は '\z' を使う(Test-EnvDocHostname と同じ理由)
    if ($sysId -notmatch '^[A-Za-z0-9_-]+\z') {
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
        # hostname は servers/<hostname>.html としてファイルパスに埋まるため、
        # ここで必ず検証する。素通しするとパストラバーサルで出力先の外に書ける
        if (-not (Test-EnvDocHostname -Name $hostName)) {
            $warnings += "$hostName : hostname に使えない文字が含まれています。スキップします"
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
        # snapshot 由来のホスト名も同じくファイルパスに埋まるため検証する
        if (-not (Test-EnvDocHostname -Name $hostName)) {
            $warnings += "$hostName : snapshot の meta.hostname に使えない文字が含まれています。スキップします"
            continue
        }
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

function Add-EnvDocAwsModel {
    param([Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][hashtable]$Inputs)

    $instances = New-Object System.Collections.ArrayList
    $vpcs    = [ordered]@{}
    $subnets = [ordered]@{}
    $sgs     = [ordered]@{}
    $roles   = [ordered]@{}
    $rtbs    = [ordered]@{}

    foreach ($srv in $Model.Servers) {
        if (-not $Inputs.Aws.ContainsKey($srv.Key)) { continue }
        $a = $Inputs.Aws[$srv.Key]
        $srv.Aws = $a

        [void]$instances.Add(@{
            Hostname     = $srv.Hostname
            InstanceId   = [string](Get-JsonValue -Object $a -Path 'instance.instance_id'       -Default '-')
            InstanceType = [string](Get-JsonValue -Object $a -Path 'instance.instance_type'     -Default '-')
            AmiId        = [string](Get-JsonValue -Object $a -Path 'instance.ami_id'            -Default '-')
            Az           = [string](Get-JsonValue -Object $a -Path 'instance.availability_zone' -Default '-')
            PrivateIp    = [string](Get-JsonValue -Object $a -Path 'instance.private_ip'        -Default '-')
            PublicIp     = [string](Get-JsonValue -Object $a -Path 'instance.public_ip'         -Default '')
            VpcId        = [string](Get-JsonValue -Object $a -Path 'instance.vpc_id'            -Default '-')
            SubnetId     = [string](Get-JsonValue -Object $a -Path 'instance.subnet_id'         -Default '-')
            Tags         = (Get-JsonValue -Object $a -Path 'instance.tags')
        })

        $vpc = Get-JsonValue -Object $a -Path 'network.vpc'
        if ($null -ne $vpc) {
            $id = [string](Get-JsonValue -Object $vpc -Path 'vpc_id' -Default '')
            if ($id -and -not $vpcs.Contains($id)) {
                $vpcs[$id] = @{ VpcId = $id; Cidr = [string](Get-JsonValue -Object $vpc -Path 'cidr' -Default '-') }
            }
        }

        $sub = Get-JsonValue -Object $a -Path 'network.subnet'
        if ($null -ne $sub) {
            $id = [string](Get-JsonValue -Object $sub -Path 'subnet_id' -Default '')
            if ($id -and -not $subnets.Contains($id)) {
                $subnets[$id] = @{
                    SubnetId = $id
                    Cidr     = [string](Get-JsonValue -Object $sub -Path 'cidr' -Default '-')
                    Az       = [string](Get-JsonValue -Object $sub -Path 'az'   -Default '-')
                    VpcId    = [string](Get-JsonValue -Object $a -Path 'instance.vpc_id' -Default '-')
                    Hosts    = (New-Object System.Collections.ArrayList)
                }
            }
            if ($id) { [void]$subnets[$id].Hosts.Add($srv.Hostname) }
        }

        # SG は複数サーバで共有されるため、リソース単位に束ねて適用サーバを逆引きする
        foreach ($sg in @(Get-JsonValue -Object $a -Path 'security_groups' -Default @())) {
            $id = [string](Get-JsonValue -Object $sg -Path 'group_id' -Default '')
            if (-not $id) { continue }
            if (-not $sgs.Contains($id)) {
                $sgs[$id] = @{
                    GroupId     = $id
                    GroupName   = [string](Get-JsonValue -Object $sg -Path 'group_name'  -Default '-')
                    Description = [string](Get-JsonValue -Object $sg -Path 'description' -Default '')
                    Ingress     = @(Get-JsonValue -Object $sg -Path 'ingress' -Default @())
                    Egress      = @(Get-JsonValue -Object $sg -Path 'egress'  -Default @())
                    AppliedTo   = (New-Object System.Collections.ArrayList)
                }
            }
            [void]$sgs[$id].AppliedTo.Add($srv.Hostname)
        }

        $roleName = [string](Get-JsonValue -Object $a -Path 'iam.role_name' -Default '')
        if ($roleName) {
            if (-not $roles.Contains($roleName)) {
                $roles[$roleName] = @{
                    RoleName         = $roleName
                    RoleArn          = [string](Get-JsonValue -Object $a -Path 'iam.role_arn' -Default '')
                    AttachedPolicies = @(Get-JsonValue -Object $a -Path 'iam.attached_policies' -Default @())
                    InlinePolicies   = @(Get-JsonValue -Object $a -Path 'iam.inline_policies'   -Default @())
                    AppliedTo        = (New-Object System.Collections.ArrayList)
                }
            }
            [void]$roles[$roleName].AppliedTo.Add($srv.Hostname)
        }

        foreach ($rt in @(Get-JsonValue -Object $a -Path 'network.route_tables' -Default @())) {
            $id = [string](Get-JsonValue -Object $rt -Path 'route_table_id' -Default '')
            if ($id -and -not $rtbs.Contains($id)) {
                $rtbs[$id] = @{ RouteTableId = $id; Routes = @(Get-JsonValue -Object $rt -Path 'routes' -Default @()) }
            }
        }
    }

    # ArrayList を配列に固める
    foreach ($k in $subnets.Keys) { $subnets[$k].Hosts     = @($subnets[$k].Hosts.ToArray()) }
    foreach ($k in $sgs.Keys)     { $sgs[$k].AppliedTo     = @($sgs[$k].AppliedTo.ToArray()) }
    foreach ($k in $roles.Keys)   { $roles[$k].AppliedTo   = @($roles[$k].AppliedTo.ToArray()) }

    $Model.Aws = @{
        Instances      = @($instances.ToArray())
        Vpcs           = @($vpcs.Keys    | ForEach-Object { $vpcs[$_] })
        Subnets        = @($subnets.Keys | ForEach-Object { $subnets[$_] })
        SecurityGroups = @($sgs.Keys     | ForEach-Object { $sgs[$_] })
        IamRoles       = @($roles.Keys   | ForEach-Object { $roles[$_] })
        RouteTables    = @($rtbs.Keys    | ForEach-Object { $rtbs[$_] })
    }
}
