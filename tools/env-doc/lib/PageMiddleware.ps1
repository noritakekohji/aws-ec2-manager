# middleware.html — ミドルウェアの横断表(製品ごとにセクション)

# 製品ごとに識別子・バージョン相当・ポートのフィールド名が異なる。
# ServerSnapshot.ps1 の Compare-Middleware にある $specs と対応させること。
#   IdPaths      : インスタンスの識別子(複数なら '/' で連結)
#   VersionPath  : バージョン相当として見せるフィールド
#   PortPath     : ポート。PortIsScalar が $true ならスカラ、$false なら配列
#
# 未実装の予約フィールドに注意（監査 M05 / M16）:
#   - tomcat / hana / sap の `state` は収集側で '' 固定。表示は '-' になるのが正しい
#   - hana / sap の `ports` は @() 固定。値が入るのは sqlserver の `port` と tomcat の `connector_ports` だけ
#   これらは「収集されていない」のではなく「収集側が未実装」なので、'未収集' ではなく '-' を出す
$script:EnvDocMwProducts = @(
    @{ Key = 'hana';      Label = 'SAP HANA';   IdPaths = @('sid');                  VersionPath = 'version';        PortPath = 'ports';           PortIsScalar = $false }
    @{ Key = 'sap';       Label = 'SAP';        IdPaths = @('sid', 'instance');      VersionPath = 'kernel_version'; PortPath = 'ports';           PortIsScalar = $false }
    @{ Key = 'sqlserver'; Label = 'SQL Server'; IdPaths = @('instance_name');        VersionPath = 'version';        PortPath = 'port';            PortIsScalar = $true }
    @{ Key = 'tomcat';    Label = 'Tomcat';     IdPaths = @('name', 'catalina_base'); VersionPath = 'version';       PortPath = 'connector_ports'; PortIsScalar = $false }
)

function Get-EnvDocMwProduct {
    param([string]$Key)

    foreach ($p in $script:EnvDocMwProducts) {
        if ($p.Key -eq $Key) { return $p }
    }
    return $null
}

function Get-EnvDocMwInstanceId {
    param($Instance, $Product)

    $parts = @()
    foreach ($path in $Product.IdPaths) {
        $v = [string](Get-JsonValue -Object $Instance -Path $path -Default '')
        if ($v) { $parts += $v }
    }
    if ($parts.Count -eq 0) { return '(名称不明)' }
    return ($parts -join '/')
}

function Get-EnvDocMwSummary {
    param($Server, [string]$ProductKey, [string]$Field)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'middleware')) { return '__MISSING__' }
    $product = Get-EnvDocMwProduct -Key $ProductKey
    if ($null -eq $product) { return 'なし' }

    # 検出されなかった製品はキーごと省かれる(空配列ではない)
    $instances = @(Get-JsonValue -Object $Server.Snapshot -Path ('middleware.{0}' -f $ProductKey) -Default @())
    if ($instances.Count -eq 0) { return 'なし' }

    $vals = @()
    foreach ($i in $instances) {
        $name = Get-EnvDocMwInstanceId -Instance $i -Product $product
        $v = switch ($Field) {
            'version' { [string](Get-JsonValue -Object $i -Path $product.VersionPath -Default '-') }
            'state'   { [string](Get-JsonValue -Object $i -Path 'state' -Default '-') }
            'ports'   {
                if ($product.PortIsScalar) {
                    $p = Get-JsonValue -Object $i -Path $product.PortPath -Default 0
                    if (-not $p) { '-' } else { [string]$p }
                }
                else {
                    $ps = @(Get-JsonValue -Object $i -Path $product.PortPath -Default @())
                    if ($ps.Count -eq 0) { '-' } else { ($ps -join ', ') }
                }
            }
            default   { '' }
        }
        $vals += ('{0}: {1}' -f $name, $v)
    }
    return ($vals -join "`n")
}

function Write-EnvDocMiddlewarePage {
    param([Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][string]$OutputRoot)

    $servers = @($Model.Servers)
    $body = New-Object System.Text.StringBuilder

    foreach ($p in $script:EnvDocMwProducts) {
        # 全サーバで「なし」または未収集の製品はセクションごと省く
        $anyPresent = $false
        foreach ($s in $servers) {
            if (-not (Test-EnvDocCategory -Server $s -Category 'middleware')) { continue }
            if (@(Get-JsonValue -Object $s.Snapshot -Path ('middleware.{0}' -f $p.Key) -Default @()).Count -gt 0) {
                $anyPresent = $true
                break
            }
        }
        if (-not $anyPresent) { continue }

        # ループ変数を scriptblock に捕まえないよう、製品キーは Arg で渡す
        # (GetNewClosure() は $script: 参照を壊すためプロジェクト規約で禁止)
        $mwGetter = { param($s, $a) Get-EnvDocMwSummary -Server $s -ProductKey $a.Product -Field $a.Field }
        $rows = @(
            @{ Label = 'バージョン';    Arg = @{ Product = $p.Key; Field = 'version' }; Getter = $mwGetter }
            @{ Label = 'Listen ポート'; Arg = @{ Product = $p.Key; Field = 'ports'   }; Getter = $mwGetter }
        )
        $t = New-EnvDocCrossTable -Model $Model -Servers $servers -Rows $rows
        [void]$body.Append((New-HtmlSection -Title $p.Label -Body $t))
    }

    if ($body.Length -eq 0) {
        [void]$body.Append('<p class="empty">ミドルウェアは検出されませんでした</p>')
    }

    $html = New-HtmlPage -Title 'ミドルウェア' -SystemName $Model.System.Name -RelRoot '.' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot 'middleware.html') -Content $html
}
