# servers/<host>.html — サーバ詳細(要約)

function New-EnvDocKeyValueRows {
    param($Snapshot, $Pairs)

    $rows = New-Object System.Collections.ArrayList
    foreach ($p in $Pairs) {
        $v = Get-JsonValue -Object $Snapshot -Path $p.Path -Default ''
        [void]$rows.Add(@{ Cells = @((ConvertTo-HtmlText -Text $p.Label), (ConvertTo-HtmlText -Text ([string]$v))); Mismatch = $false })
    }
    return $rows.ToArray()
}

function Write-EnvDocServerPage {
    param(
        [Parameter(Mandatory)][hashtable]$Model,
        [Parameter(Mandatory)][hashtable]$Server,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    if (-not $Server.HasSnapshot) { return }

    $snap = $Server.Snapshot
    $body = New-Object System.Text.StringBuilder

    # 基本情報
    $basic = New-Object System.Collections.ArrayList
    [void]$basic.Add(@{ Cells = @('ホスト名', (ConvertTo-HtmlText -Text $Server.Hostname)); Mismatch = $false })
    [void]$basic.Add(@{ Cells = @('役割', (ConvertTo-HtmlText -Text $Server.Role)); Mismatch = $false })
    [void]$basic.Add(@{ Cells = @('備考', (ConvertTo-HtmlText -Text $Server.Note)); Mismatch = $false })
    [void]$basic.Add(@{ Cells = @('収集日時', (ConvertTo-HtmlText -Text $Server.CollectedAt)); Mismatch = $false })
    [void]$body.Append((New-HtmlSection -Title '基本情報' -Body (New-HtmlTable -Headers @('項目', '値') -Rows $basic.ToArray())))

    # OS / ハードウェア
    if (Test-EnvDocCategory -Server $Server -Category 'os') {
        $pairs = @(
            @{ Label = 'OS';           Path = 'os.os_name' }
            @{ Label = 'バージョン';    Path = 'os.os_version' }
            @{ Label = 'アーキテクチャ'; Path = 'os.architecture' }
            @{ Label = 'タイムゾーン';   Path = 'os.timezone' }
            @{ Label = 'CPU';          Path = 'os.cpu_model' }
            @{ Label = 'CPU コア数';    Path = 'os.cpu_cores' }
            @{ Label = 'メモリ (GB)';   Path = 'os.total_memory_gb' }
            @{ Label = '仮想化';        Path = 'os.hardware.virtualization' }
            @{ Label = '最終起動';      Path = 'os.last_boot' }
        )
        $rows = New-EnvDocKeyValueRows -Snapshot $snap -Pairs $pairs
        [void]$body.Append((New-HtmlSection -Title 'OS / ハードウェア' -Body (New-HtmlTable -Headers @('項目', '値') -Rows $rows)))
    }
    else {
        [void]$body.Append((New-HtmlSection -Title 'OS / ハードウェア' -Body '<p class="missing">未収集</p>'))
    }

    # サービス
    if (Test-EnvDocCategory -Server $Server -Category 'services') {
        $svcRows = New-Object System.Collections.ArrayList
        foreach ($svc in @(Get-JsonValue -Object $snap -Path 'services' -Default @())) {
            [void]$svcRows.Add(@{
                Cells = @(
                    (ConvertTo-HtmlText -Text ([string]$svc.name)),
                    (ConvertTo-HtmlText -Text ([string]$svc.status)),
                    (ConvertTo-HtmlText -Text ([string]$svc.start_type))
                )
                Mismatch = $false
            })
        }
        $t = New-HtmlTable -Headers @('サービス名', '状態', '起動設定') -Rows $svcRows.ToArray()
        [void]$body.Append((New-HtmlSection -Title 'サービス' -Body $t))
    }
    else {
        [void]$body.Append((New-HtmlSection -Title 'サービス' -Body '<p class="missing">未収集</p>'))
    }

    # 環境変数(opt-in)
    # environment はフラットではなく {machine:{...}, user:{...}} の 2 段。
    # Linux は machine のみで user キーが存在しない(監査 M07)
    if ($Server.ShowEnvironment -and (Test-EnvDocCategory -Server $Server -Category 'environment')) {
        $envObj = Get-JsonValue -Object $snap -Path 'environment'
        $envRows = New-Object System.Collections.ArrayList
        foreach ($scope in @('machine', 'user')) {
            $scopeObj = Get-JsonValue -Object $envObj -Path $scope
            if ($null -eq $scopeObj) { continue }
            foreach ($prop in $scopeObj.PSObject.Properties) {
                [void]$envRows.Add(@{
                    Cells = @(
                        (ConvertTo-HtmlText -Text $scope),
                        (ConvertTo-HtmlText -Text $prop.Name),
                        (ConvertTo-HtmlText -Text ([string]$prop.Value))
                    )
                    Mismatch = $false
                })
            }
        }
        $t = New-HtmlTable -Headers @('スコープ', '変数名', '値') -Rows $envRows.ToArray()
        [void]$body.Append((New-HtmlSection -Title '環境変数' -Body $t))
    }

    # 全件ページへのリンク
    $linkRows = New-Object System.Collections.ArrayList

    $pkgCollected = Test-EnvDocCategory -Server $Server -Category 'packages'
    $pkgCount = if ($pkgCollected) { @(Get-JsonValue -Object $snap -Path 'packages' -Default @()).Count } else { 0 }
    $pkgCell = if ($pkgCollected -and $pkgCount -gt 0) {
        New-HtmlCell -Text ('{0} 件' -f $pkgCount) -Link ('{0}-packages.html' -f $Server.Hostname)
    } else { Format-EnvDocMissing -Collected $pkgCollected -Count $pkgCount }
    [void]$linkRows.Add(@{ Cells = @('パッケージ', $pkgCell); Mismatch = $false })

    $flCollected = Test-EnvDocCategory -Server $Server -Category 'filelist'
    $flCount = 0
    if ($flCollected) {
        foreach ($t2 in @(Get-JsonValue -Object $snap -Path 'filelist' -Default @())) {
            $flCount += @(Get-JsonValue -Object $t2 -Path 'entries' -Default @()).Count
        }
    }
    $flCell = if ($flCollected -and $flCount -gt 0) {
        New-HtmlCell -Text ('{0} 件' -f $flCount) -Link ('{0}-filelist.html' -f $Server.Hostname)
    } else { Format-EnvDocMissing -Collected $flCollected -Count $flCount }
    [void]$linkRows.Add(@{ Cells = @('ファイル一覧', $flCell); Mismatch = $false })

    $cfgCell = if ($Server.ShowConfigs) {
        New-HtmlCell -Text '全文を見る' -Link ('{0}-configs.html' -f $Server.Hostname)
    } else { '<span class="missing">非掲載 (show_configs: false)</span>' }
    [void]$linkRows.Add(@{ Cells = @('設定ファイル', $cfgCell); Mismatch = $false })

    $t = New-HtmlTable -Headers @('区分', '内容') -Rows $linkRows.ToArray()
    [void]$body.Append((New-HtmlSection -Title '詳細データ' -Body $t))

    $title = 'サーバ詳細: {0}' -f $Server.Hostname
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}.html' -f $Server.Hostname)) -Content $html
}

function Write-EnvDocPackagesPage {
    param([hashtable]$Model, [hashtable]$Server, [string]$OutputRoot)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'packages')) { return }
    $pkgs = @(Get-JsonValue -Object $Server.Snapshot -Path 'packages' -Default @())

    $rows = New-Object System.Collections.ArrayList
    foreach ($p in $pkgs) {
        [void]$rows.Add(@{
            Cells = @(
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $p -Path 'name'      -Default '-'))),
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $p -Path 'version'   -Default '-'))),
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $p -Path 'vendor' -Default '')))
            )
            Mismatch = $false
        })
    }
    $t = New-HtmlTable -Headers @('名称', 'バージョン', '提供元') -Rows $rows.ToArray()
    $title = 'パッケージ一覧: {0}' -f $Server.Hostname
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body (New-HtmlSection -Title ('全 {0} 件' -f $pkgs.Count) -Body $t)
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}-packages.html' -f $Server.Hostname)) -Content $html
}

function Write-EnvDocFilelistPage {
    param([hashtable]$Model, [hashtable]$Server, [string]$OutputRoot)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'filelist')) { return }
    $targets = @(Get-JsonValue -Object $Server.Snapshot -Path 'filelist' -Default @())

    $body = New-Object System.Text.StringBuilder
    $total = 0
    foreach ($t in $targets) {
        $key = [string](Get-JsonValue -Object $t -Path 'key' -Default '-')
        $entries = @(Get-JsonValue -Object $t -Path 'entries' -Default @())
        $total += $entries.Count

        $rows = New-Object System.Collections.ArrayList
        foreach ($e in $entries) {
            [void]$rows.Add(@{
                Cells = @(
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'rel_path' -Default '-'))),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'type'     -Default '-'))),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'size'     -Default ''))),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'mtime'    -Default ''))),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'owner'    -Default '')))
                )
                Mismatch = $false
            })
        }
        $sub = New-HtmlTable -Headers @('相対パス', '種別', 'サイズ', '更新日時', 'オーナー') -Rows $rows.ToArray()
        if (Get-JsonValue -Object $t -Path 'truncated' -Default $false) {
            $sub = '<div class="warn">上限に達したため一部のみ収集されています</div>' + $sub
        }
        [void]$body.Append((New-HtmlSection -Title ('{0} ({1} 件)' -f $key, $entries.Count) -Body $sub))
    }

    $title = 'ファイル一覧: {0}' -f $Server.Hostname
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}-filelist.html' -f $Server.Hostname)) -Content $html
}

# config_files は「絶対パスをキー、値が {content, masked, size_bytes, sha256, readable, reason}」
# のマップ。配列ではない。sap のみキー名が profiles である点に注意。
function Add-EnvDocConfigFileBlock {
    param(
        [System.Text.StringBuilder]$Body,
        $ConfigMap,
        [string]$Owner,
        [Parameter(Mandatory)][bool]$ShowConfigs
    )

    # 機密の担保を呼び出し元 1 箇所に依存させない。将来この関数が別ページから
    # 呼ばれても、opt-in していないサーバの本文が出ないようここでも遮断する
    if (-not $ShowConfigs) { return 0 }
    if ($null -eq $ConfigMap) { return 0 }
    $count = 0
    foreach ($cf in $ConfigMap.PSObject.Properties) {
        $path = $cf.Name
        $e = $cf.Value
        $count++

        [void]$Body.Append('<h3>').Append((ConvertTo-HtmlText -Text ('{0} / {1}' -f $Owner, $path))).Append('</h3>')

        $readable = Get-JsonValue -Object $e -Path 'readable' -Default $true
        $reason   = [string](Get-JsonValue -Object $e -Path 'reason' -Default '')
        $sha      = [string](Get-JsonValue -Object $e -Path 'sha256' -Default '')
        $size     = [string](Get-JsonValue -Object $e -Path 'size_bytes' -Default '')
        $masked   = Get-JsonValue -Object $e -Path 'masked' -Default $false

        if ($sha -or $size) {
            [void]$Body.Append('<p class="meta">').Append((ConvertTo-HtmlText -Text ('sha256: {0} / サイズ: {1} バイト' -f $sha, $size))).Append('</p>')
        }
        if ($masked) {
            [void]$Body.Append('<p class="meta">機密値は *** にマスクされています</p>')
        }
        if (-not $readable -or $reason) {
            [void]$Body.Append('<p class="missing">').Append((ConvertTo-HtmlText -Text ('本文は保存されていません: {0}' -f $reason))).Append('</p>')
            continue
        }
        $content = [string](Get-JsonValue -Object $e -Path 'content' -Default '')
        [void]$Body.Append('<pre>').Append((ConvertTo-HtmlText -Text $content)).Append('</pre>')
    }
    return $count
}

function Write-EnvDocConfigsPage {
    param([hashtable]$Model, [hashtable]$Server, [string]$OutputRoot)

    # 設定ファイル全文は機密濃度が高いため、opt-in したサーバのみ出力する
    if (-not $Server.ShowConfigs) { return }
    if (-not $Server.HasSnapshot) { return }

    $snap = $Server.Snapshot
    $body = New-Object System.Text.StringBuilder
    $total = 0

    # middleware(sap のみ profiles)
    if (Test-EnvDocCategory -Server $Server -Category 'middleware') {
        $mw = Get-JsonValue -Object $snap -Path 'middleware'
        if ($null -ne $mw) {
            foreach ($prop in $mw.PSObject.Properties) {
                $product = Get-EnvDocMwProduct -Key $prop.Name
                $cfgKey = if ($prop.Name -eq 'sap') { 'profiles' } else { 'config_files' }
                foreach ($inst in @($prop.Value)) {
                    $instName = if ($null -ne $product) {
                        '{0} {1}' -f $prop.Name, (Get-EnvDocMwInstanceId -Instance $inst -Product $product)
                    } else { $prop.Name }
                    $total += Add-EnvDocConfigFileBlock -Body $body -ConfigMap (Get-JsonValue -Object $inst -Path $cfgKey) -Owner $instName -ShowConfigs $Server.ShowConfigs
                }
            }
        }
    }

    # services
    if (Test-EnvDocCategory -Server $Server -Category 'services') {
        foreach ($svc in @(Get-JsonValue -Object $snap -Path 'services' -Default @())) {
            $owner = 'service {0}' -f [string](Get-JsonValue -Object $svc -Path 'name' -Default '-')
            $total += Add-EnvDocConfigFileBlock -Body $body -ConfigMap (Get-JsonValue -Object $svc -Path 'config_files') -Owner $owner -ShowConfigs $Server.ShowConfigs
        }
    }

    # remote_access(Windows は ssh、Linux は ssh / rdp / vnc)
    if (Test-EnvDocCategory -Server $Server -Category 'remote_access') {
        $ra = Get-JsonValue -Object $snap -Path 'remote_access'
        if ($null -ne $ra) {
            foreach ($key in @('ssh', 'rdp', 'vnc')) {
                $node = Get-JsonValue -Object $ra -Path $key
                if ($null -eq $node) { continue }
                $total += Add-EnvDocConfigFileBlock -Body $body -ConfigMap (Get-JsonValue -Object $node -Path 'config_files') -Owner ('remote_access {0}' -f $key) -ShowConfigs $Server.ShowConfigs
            }
        }
    }

    if ($total -eq 0) {
        [void]$body.Append('<p class="empty">設定ファイルは収集されていません</p>')
    }

    $title = '設定ファイル: {0}' -f $Server.Hostname
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}-configs.html' -f $Server.Hostname)) -Content $html
}
