# network.html — ネットワーク構成 + リモートアクセスの横断表
# New-EnvDocCrossTable は middleware / os-baseline からも使う共通ヘルパ
#
# Listen ポート行は PageMiddleware.ps1 の Get-EnvDocMwProduct を使う。
# dot-source 順は PageNetwork が先だが、PowerShell の関数解決は呼び出し時のため問題ない。

function New-EnvDocCrossTable {
    param(
        [Parameter(Mandatory)][hashtable]$Model,
        [Parameter(Mandatory)]$Servers,
        [Parameter(Mandatory)]$Rows
    )

    $srvArray = @($Servers)
    if ($srvArray.Count -eq 0) { return '<p class="empty">対象サーバがありません</p>' }

    $headers = @('項目') + @($srvArray | ForEach-Object { $_.Hostname })
    $tableRows = New-Object System.Collections.ArrayList

    foreach ($r in $Rows) {
        $valuesByKey = @{}
        $cells = New-Object System.Collections.ArrayList
        [void]$cells.Add((ConvertTo-HtmlText -Text $r.Label))

        foreach ($s in $srvArray) {
            if (-not $s.HasSnapshot) {
                # 未収集サーバは比較対象に含めない(登録しないこと自体が「不一致にしない」実装)
                [void]$cells.Add('<span class="missing">未収集</span>')
                continue
            }
            # Arg は行ごとの追加引数(不要な行の Getter は param($s) だけを宣言すればよい)
            $v = [string](& $r.Getter $s $r.Arg)
            if ($v -eq '__MISSING__') {
                # このサーバはカテゴリ未収集。比較対象に含めない
                [void]$cells.Add('<span class="missing">未収集</span>')
            }
            else {
                $valuesByKey[$s.Key] = $v
                [void]$cells.Add((ConvertTo-HtmlText -Text $v))
            }
        }

        # NoCompare の行は不一致判定から除外する。
        # 最終起動時刻や空きメモリのような揮発値はサーバごとに違って当然であり、
        # ハイライトすると「揃っているべきものが揃っていない」という本来の検出が埋もれる。
        $isMismatch = $false
        if (-not $r.NoCompare) {
            $isMismatch = Test-EnvDocMismatch -ValuesByKey $valuesByKey -Groups $Model.Groups
        }

        [void]$tableRows.Add(@{
            Cells    = $cells.ToArray()
            Mismatch = $isMismatch
        })
    }

    return New-HtmlTable -Headers $headers -Rows $tableRows.ToArray()
}

function Get-EnvDocCategoryValue {
    param($Server, [string]$Category, [scriptblock]$Getter)

    if (-not (Test-EnvDocCategory -Server $Server -Category $Category)) { return '__MISSING__' }
    return [string](& $Getter $Server)
}

# remote_access は Windows と Linux でトップレベルの構造が違うため、共通軸を作らず
# OS 別サブ表として描画する。行定義自体を OS で切り替える。
function Get-EnvDocRaScalar {
    param($Server, [string]$Path)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'remote_access')) { return '__MISSING__' }
    $v = Get-JsonValue -Object $Server.Snapshot -Path $Path -Default $null
    if ($null -eq $v) { return '-' }
    if ($v -is [bool]) { if ($v) { return '有効' } else { return '無効' } }
    return [string]$v
}

# 定義書なので稼働状態(status)ではなく起動設定(start_type)を出す。
# 「今動いているか」ではなく「起動する設定になっているか」が定義。
function Get-EnvDocRaServiceConfig {
    param($Server, [string]$Path, [string]$NameFilter = '')

    if (-not (Test-EnvDocCategory -Server $Server -Category 'remote_access')) { return '__MISSING__' }
    $svcs = @(Get-JsonValue -Object $Server.Snapshot -Path $Path -Default @())
    if ($NameFilter) { $svcs = @($svcs | Where-Object { [string]$_.name -eq $NameFilter }) }
    if ($svcs.Count -eq 0) { return 'なし' }
    return ((@($svcs | ForEach-Object { '{0}: {1}' -f $_.name, $_.start_type })) -join "`n")
}

function Get-EnvDocRaFirewallSummary {
    param($Server)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'remote_access')) { return '__MISSING__' }
    $rules = @(Get-JsonValue -Object $Server.Snapshot -Path 'remote_access.firewall_rules' -Default @())
    if ($rules.Count -eq 0) { return 'なし' }
    return ('{0} 件' -f $rules.Count)
}

function Get-EnvDocRemoteAccessRows {
    param([string]$OsType)

    $scalar  = { param($s, $p) Get-EnvDocRaScalar -Server $s -Path $p }
    $svcPath = { param($s, $p) Get-EnvDocRaServiceConfig -Server $s -Path $p }

    if ($OsType -eq 'windows') {
        return @(
            @{ Label = 'RDP';                 Arg = 'remote_access.rdp.enabled';              Getter = $scalar }
            @{ Label = 'RDP ポート';           Arg = 'remote_access.rdp.port_number';          Getter = $scalar }
            @{ Label = 'NLA';                 Arg = 'remote_access.rdp.nla_enabled';           Getter = $scalar }
            @{ Label = '最小暗号化レベル';      Arg = 'remote_access.rdp.min_encryption_level'; Getter = $scalar }
            @{ Label = 'セキュリティレイヤ';    Arg = 'remote_access.rdp.security_layer';       Getter = $scalar }
            @{ Label = 'SSH サービス';         Arg = 'sshd'; Getter = { param($s, $n) Get-EnvDocRaServiceConfig -Server $s -Path 'remote_access.services' -NameFilter $n } }
            @{ Label = '関連 FW ルール';       Getter = { param($s) Get-EnvDocRaFirewallSummary -Server $s } }
        )
    }
    return @(
        @{ Label = 'SSH サービス';  Arg = 'remote_access.ssh.services'; Getter = $svcPath }
        @{ Label = 'RDP (xrdp)';   Arg = 'remote_access.rdp.services'; Getter = $svcPath }
        @{ Label = 'VNC';          Arg = 'remote_access.vnc.services'; Getter = $svcPath }
    )
}

# proxy と firewall は OS で構造が違うため関数で分岐する（監査 M09 / M15）。
# network.html の横断表は OS 混在のまま 1 表にするので、getter 内で $Server.OsType を見る。
function Get-EnvDocProxySummary {
    param($Server)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'network')) { return '__MISSING__' }
    if ($Server.OsType -eq 'windows') {
        $en = Get-JsonValue -Object $Server.Snapshot -Path 'network.proxy.enabled' -Default $false
        if (-not $en) { return '無効' }
        return [string](Get-JsonValue -Object $Server.Snapshot -Path 'network.proxy.server' -Default '有効')
    }
    # Linux は {http_proxy, https_proxy, no_proxy}。enabled / server キーは存在しない
    $vals = @()
    foreach ($k in @('http_proxy', 'https_proxy')) {
        $v = [string](Get-JsonValue -Object $Server.Snapshot -Path ('network.proxy.{0}' -f $k) -Default '')
        if ($v) { $vals += ('{0}={1}' -f $k, $v) }
    }
    if ($vals.Count -eq 0) { return '無効' }
    return ($vals -join "`n")
}

function Get-EnvDocFirewallSummary {
    param($Server)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'security')) { return '__MISSING__' }
    if ($Server.OsType -eq 'windows') {
        # security.firewall というキーは無い。firewall_profiles[] = {name, enabled, ...}
        $profiles = @(Get-JsonValue -Object $Server.Snapshot -Path 'security.firewall_profiles' -Default @())
        if ($profiles.Count -eq 0) { return '-' }
        $parts = @()
        foreach ($p in $profiles) {
            $st = if ($p.enabled) { '有効' } else { '無効' }
            $parts += ('{0}: {1}' -f [string]$p.name, $st)
        }
        return ($parts -join "`n")
    }
    # Linux の security.firewall は firewalld / iptables を検出したときだけ生える（監査 C05）
    $fw = Get-JsonValue -Object $Server.Snapshot -Path 'security.firewall'
    if ($null -eq $fw) { return '-' }
    $type  = [string](Get-JsonValue -Object $fw -Path 'type'  -Default '')
    $state = [string](Get-JsonValue -Object $fw -Path 'state' -Default '')
    $s = ('{0} {1}' -f $type, $state).Trim()
    if ($s -eq '') { return '-' }
    return $s
}

function Write-EnvDocNetworkPage {
    param([Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][string]$OutputRoot)

    $servers = @($Model.Servers)

    $rows = @(
        @{ Label = 'IP アドレス'; Getter = {
            param($s) Get-EnvDocCategoryValue -Server $s -Category 'network' -Getter {
                # network.interfaces の要素は {name, address, prefix}
                param($x) (@(Get-JsonValue -Object $x.Snapshot -Path 'network.interfaces' -Default @() |
                    ForEach-Object { '{0}: {1}/{2}' -f $_.name, $_.address, $_.prefix }) -join "`n")
            }
        }}
        @{ Label = 'DNS サーバ'; Getter = {
            param($s) Get-EnvDocCategoryValue -Server $s -Category 'network' -Getter {
                param($x)
                # dns_servers はフラットな配列ではなく [{interface, servers:[...]}]
                $all = @()
                foreach ($e in @(Get-JsonValue -Object $x.Snapshot -Path 'network.dns_servers' -Default @())) {
                    foreach ($srv in @(Get-JsonValue -Object $e -Path 'servers' -Default @())) { $all += [string]$srv }
                }
                if ($all.Count -eq 0) { return 'なし' }
                (@($all | Select-Object -Unique) -join ', ')
            }
        }}
        @{ Label = '時刻同期'; Getter = {
            param($s) Get-EnvDocCategoryValue -Server $s -Category 'network' -Getter {
                param($x)
                # ntp ではなく time_sync
                $srv = @(Get-JsonValue -Object $x.Snapshot -Path 'network.time_sync.servers' -Default @())
                if ($srv.Count -eq 0) { return 'なし' }
                ($srv -join ', ')
            }
        }}
        @{ Label = 'プロキシ';         Getter = { param($s) Get-EnvDocProxySummary    -Server $s } }
        @{ Label = 'ファイアウォール'; Getter = { param($s) Get-EnvDocFirewallSummary -Server $s } }
        @{ Label = 'Listen ポート'; Getter = {
            param($s) Get-EnvDocCategoryValue -Server $s -Category 'middleware' -Getter {
                param($x)
                # ポートのフィールド名は製品ごとに違う(ports / port / connector_ports)
                $ports = @()
                $mw = Get-JsonValue -Object $x.Snapshot -Path 'middleware'
                if ($null -ne $mw) {
                    foreach ($prop in $mw.PSObject.Properties) {
                        $product = Get-EnvDocMwProduct -Key $prop.Name
                        if ($null -eq $product) { continue }
                        foreach ($inst in @($prop.Value)) {
                            if ($product.PortIsScalar) {
                                $p = Get-JsonValue -Object $inst -Path $product.PortPath -Default 0
                                if ($p) { $ports += [string]$p }
                            }
                            else {
                                foreach ($p in @(Get-JsonValue -Object $inst -Path $product.PortPath -Default @())) {
                                    $ports += [string]$p
                                }
                            }
                        }
                    }
                }
                if ($ports.Count -eq 0) { return 'なし' }
                (@($ports | Sort-Object -Unique) -join ', ')
            }
        }}
    )

    $body = New-Object System.Text.StringBuilder
    [void]$body.Append((New-HtmlSection -Title 'ネットワーク設定(横断)' -Body (New-EnvDocCrossTable -Model $Model -Servers $servers -Rows $rows)))

    # リモートアクセス(構造が OS で異なるため OS 別サブ表)
    $osTypes = @($servers | Where-Object { $_.HasSnapshot } | ForEach-Object { $_.OsType } | Select-Object -Unique | Sort-Object)
    foreach ($osType in $osTypes) {
        $osServers = @($servers | Where-Object { $_.HasSnapshot -and $_.OsType -eq $osType })
        $label = switch ($osType) { 'windows' { 'Windows' } 'linux' { 'Linux' } default { $osType } }
        $sub = New-EnvDocCrossTable -Model $Model -Servers $osServers -Rows (Get-EnvDocRemoteAccessRows -OsType $osType)
        [void]$body.Append((New-HtmlSection -Title ('リモートアクセス - {0} ({1} 台)' -f $label, $osServers.Count) -Body $sub))
    }

    $html = New-HtmlPage -Title 'ネットワーク' -SystemName $Model.System.Name -RelRoot '.' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot 'network.html') -Content $html
}
