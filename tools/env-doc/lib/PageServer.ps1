# servers/<host>.html — サーバ詳細(要約)

function New-EnvDocKeyValueRows {
    param($Snapshot, $Pairs)

    $rows = New-Object System.Collections.ArrayList
    foreach ($p in $Pairs) {
        $v = Get-JsonValue -Object $Snapshot -Path $p.Path -Default ''
        [void]$rows.Add(@{ Cells = @((ConvertTo-HtmlText -Text $p.Label), (ConvertTo-HtmlText -Text ([string]$v))); Mismatch = $false })
    }
    # カンマを付けないと空配列が $null にアンロールされ、New-HtmlTable 側で
    # @($null) が 1 要素になって空行が出る
    return , $rows.ToArray()
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
    # 目次用。セクションを足すたびにここへ id とラベルを積む
    $toc = New-Object System.Collections.ArrayList

    # 基本情報
    $basic = New-Object System.Collections.ArrayList
    [void]$basic.Add(@{ Cells = @('ホスト名', (ConvertTo-HtmlText -Text $Server.Hostname)); Mismatch = $false })
    [void]$basic.Add(@{ Cells = @('役割', (ConvertTo-HtmlText -Text $Server.Role)); Mismatch = $false })
    [void]$basic.Add(@{ Cells = @('備考', (ConvertTo-HtmlText -Text $Server.Note)); Mismatch = $false })
    [void]$toc.Add(@{ Id = 'basic'; Label = '基本情報' })
    [void]$body.Append((New-HtmlSection -Title '基本情報' -Id 'basic' -Body (New-HtmlTable -Headers @('項目', '値') -Rows $basic.ToArray())))

    # AWS 要約(aws.json があるサーバのみ再掲。詳細は aws.html を参照)
    if ($null -ne $Server.Aws) {
        $awsRows = New-Object System.Collections.ArrayList
        [void]$awsRows.Add(@{ Cells = @('インスタンスタイプ', (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $Server.Aws -Path 'instance.instance_type' -Default '-')))); Mismatch = $false })
        [void]$awsRows.Add(@{ Cells = @('AZ', (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $Server.Aws -Path 'instance.availability_zone' -Default '-')))); Mismatch = $false })
        [void]$awsRows.Add(@{ Cells = @('Private IP', (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $Server.Aws -Path 'instance.private_ip' -Default '-')))); Mismatch = $false })
        $sgNames = @(Get-JsonValue -Object $Server.Aws -Path 'security_groups' -Default @() | ForEach-Object { [string](Get-JsonValue -Object $_ -Path 'group_name' -Default '-') })
        [void]$awsRows.Add(@{ Cells = @('Security Group', (ConvertTo-HtmlText -Text (($sgNames -join ', ')))); Mismatch = $false })
        # IAM ロールの行だけは New-HtmlCell に生の文字列を渡す。New-HtmlCell は内部で
        # ConvertTo-HtmlText を通すため、ここで先に ConvertTo-HtmlText すると二重エスケープになる
        [void]$awsRows.Add(@{ Cells = @('IAM ロール', (New-HtmlCell -Text ([string](Get-JsonValue -Object $Server.Aws -Path 'iam.role_name' -Default '-')) -Link '../aws.html')); Mismatch = $false })
        $t = New-HtmlTable -Headers @('項目', '値') -Rows $awsRows.ToArray()
        [void]$toc.Add(@{ Id = 'aws'; Label = 'AWS 要約' })
        [void]$body.Append((New-HtmlSection -Title 'AWS 要約' -Id 'aws' -Body $t))
    }

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
        )
        $rows = New-EnvDocKeyValueRows -Snapshot $snap -Pairs $pairs
        [void]$toc.Add(@{ Id = 'os'; Label = 'OS / ハードウェア' })
        [void]$body.Append((New-HtmlSection -Title 'OS / ハードウェア' -Id 'os' -Body (New-HtmlTable -Headers @('項目', '値') -Rows $rows)))
    }
    else {
        [void]$toc.Add(@{ Id = 'os'; Label = 'OS / ハードウェア' })
        [void]$body.Append((New-HtmlSection -Title 'OS / ハードウェア' -Id 'os' -Body '<p class="missing">未収集</p>'))
    }

    # サービス(要約のみ。全件は <host>-services.html に逃がす)
    # 実機では 300 件近くになり、詳細ページに並べるとスクロールが破綻するため。
    [void]$toc.Add(@{ Id = 'services'; Label = 'サービス' })
    if (Test-EnvDocCategory -Server $Server -Category 'services') {
        $svcs = @(Get-JsonValue -Object $snap -Path 'services' -Default @())
        $sum = Get-EnvDocServiceSummary -Services $svcs

        $svcRows = New-Object System.Collections.ArrayList
        [void]$svcRows.Add(@{ Cells = @('総数', (ConvertTo-HtmlText -Text ('{0} 件' -f $sum.Total))); Mismatch = $false })
        [void]$svcRows.Add(@{ Cells = @('自動起動', (ConvertTo-HtmlText -Text ('{0} 件' -f $sum.AutoStart))); Mismatch = $false })
        # 全件ページは 0 件だと生成されない。無条件にリンクするとリンク切れになるため、
        # packages と同じく件数 0 のときは「なし」を出す
        $link = if ($sum.Total -gt 0) {
            New-HtmlCell -Text '全件を見る' -Link ('{0}-services.html' -f $Server.Hostname)
        } else { Format-EnvDocMissing -Collected $true -Count 0 }
        [void]$svcRows.Add(@{ Cells = @('一覧', $link); Mismatch = $false })

        $t = New-HtmlTable -Headers @('項目', '値') -Rows $svcRows.ToArray()
        [void]$body.Append((New-HtmlSection -Title 'サービス' -Id 'services' -Body $t))
    }
    else {
        [void]$body.Append((New-HtmlSection -Title 'サービス' -Id 'services' -Body '<p class="missing">未収集</p>'))
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
        [void]$toc.Add(@{ Id = 'environment'; Label = '環境変数' })
        [void]$body.Append((New-HtmlSection -Title '環境変数' -Id 'environment' -Body $t))
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
    [void]$toc.Add(@{ Id = 'details'; Label = '詳細データ' })
    [void]$body.Append((New-HtmlSection -Title '詳細データ' -Id 'details' -Body $t))

    $title = 'サーバ詳細: {0}' -f $Server.Hostname
    # 目次は本文の先頭に置く
    $page = (New-HtmlToc -Items $toc.ToArray()) + $body.ToString()
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body $page
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}.html' -f $Server.Hostname)) -Content $html
}

# 起動設定の語彙は OS で違う(Windows: automatic / Linux: enabled)。
# 定義書では「自動起動するか」だけを扱い、今動いているかどうかは扱わない。
function Test-EnvDocServiceAutoStart {
    param([string]$StartType)
    return (@('automatic', 'auto', 'enabled') -contains $StartType.ToLowerInvariant())
}

function Get-EnvDocServiceSummary {
    param($Services)

    $svcs = @($Services)
    $auto = 0
    foreach ($s in $svcs) {
        $start = [string](Get-JsonValue -Object $s -Path 'start_type' -Default '')
        if (Test-EnvDocServiceAutoStart -StartType $start) { $auto++ }
    }
    return @{ Total = $svcs.Count; AutoStart = $auto }
}

# 稼働状態(status)は実行時の情報なので列に含めない。
# 定義として意味を持つのは「起動設定」「実行ユーザー」「実行ファイル」。
function New-EnvDocServiceRows {
    param($Services)

    $rows = New-Object System.Collections.ArrayList
    foreach ($s in @($Services)) {
        [void]$rows.Add(@{
            Cells = @(
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $s -Path 'name'         -Default '-'))),
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $s -Path 'display_name' -Default ''))),
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $s -Path 'start_type'   -Default '-'))),
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $s -Path 'start_name'   -Default ''))),
                (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $s -Path 'path_name'    -Default '')))
            )
            Mismatch = $false
        })
    }
    # 該当 0 件のとき空配列が $null にアンロールされないようカンマを付ける
    return , $rows.ToArray()
}

function Write-EnvDocServicesPage {
    param([hashtable]$Model, [hashtable]$Server, [string]$OutputRoot)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'services')) { return }
    $svcs = @(Get-JsonValue -Object $Server.Snapshot -Path 'services' -Default @())
    if ($svcs.Count -eq 0) { return }

    $sum = Get-EnvDocServiceSummary -Services $svcs
    $body = New-Object System.Text.StringBuilder
    $toc  = New-Object System.Collections.ArrayList

    $starts = @($svcs |
        ForEach-Object { [string](Get-JsonValue -Object $_ -Path 'start_type' -Default '-') } |
        Select-Object -Unique | Sort-Object)

    # 起動設定ごとの件数。自動起動がいくつあるかを開かずに把握できるようにする
    $sumRows = New-Object System.Collections.ArrayList
    foreach ($sp in $starts) {
        $n = @($svcs | Where-Object { [string](Get-JsonValue -Object $_ -Path 'start_type' -Default '-') -eq $sp }).Count
        [void]$sumRows.Add(@{
            Cells = @((ConvertTo-HtmlText -Text $sp), (ConvertTo-HtmlText -Text ([string]$n)))
            Mismatch = $false
        })
    }
    [void]$toc.Add(@{ Id = 'summary'; Label = 'サマリ' })
    [void]$body.Append((New-HtmlSection -Title 'サマリ' -Id 'summary' `
        -Body (New-HtmlTable -Headers @('起動設定', '件数') -Rows $sumRows.ToArray())))

    # 起動設定ごとの一覧。件数が多いので既定は閉じておく
    [void]$toc.Add(@{ Id = 'by-start-type'; Label = '起動設定別の一覧' })
    $byStart = New-Object System.Text.StringBuilder
    foreach ($sp in $starts) {
        $group = @($svcs |
            Where-Object { [string](Get-JsonValue -Object $_ -Path 'start_type' -Default '-') -eq $sp } |
            Sort-Object { [string](Get-JsonValue -Object $_ -Path 'name' -Default '') })
        $rows = New-EnvDocServiceRows -Services $group
        $t = New-HtmlTable -Headers @('サービス名', '表示名', '起動設定', '実行ユーザー', '実行ファイル') -Rows $rows
        [void]$byStart.Append((New-HtmlDetails -Summary ('{0} ({1} 件)' -f $sp, $group.Count) -Body $t))
    }
    [void]$body.Append((New-HtmlSection -Title '起動設定別の一覧' -Id 'by-start-type' -Body $byStart.ToString()))

    $title = 'サービス一覧: {0}' -f $Server.Hostname
    $head = '<p class="meta">全 {0} 件 (自動起動 {1})</p>' -f $sum.Total, $sum.AutoStart
    $page = (New-HtmlToc -Items $toc.ToArray()) + $head + $body.ToString() + (New-HtmlBackToTop)
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body $page
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}-services.html' -f $Server.Hostname)) -Content $html
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
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body ((New-HtmlSection -Title ('全 {0} 件' -f $pkgs.Count) -Body $t) + (New-HtmlBackToTop))
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}-packages.html' -f $Server.Hostname)) -Content $html
}

# --- ファイル一覧のディレクトリツリー ---
# rel_path はフラットな文字列で来る(Windows は '\'、Linux は '/' 区切り)。
# そのまま 1000 行の表にすると読めないため、パスを分解して階層に組み直す。

function New-EnvDocFileTreeNode {
    return @{ Dirs = [ordered]@{}; Files = (New-Object System.Collections.ArrayList) }
}

function New-EnvDocFileTree {
    param($Entries)

    $root = New-EnvDocFileTreeNode
    foreach ($e in @($Entries)) {
        $rel = [string](Get-JsonValue -Object $e -Path 'rel_path' -Default '')
        if ($rel -eq '') { continue }
        # Windows / Linux の両方の区切りを受ける
        $parts = @($rel -split '[\\/]' | Where-Object { $_ -ne '' })
        if ($parts.Count -eq 0) { continue }

        # 途中のディレクトリは entry が無くても作る(収集対象外でも階層は必要)
        $node = $root
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $name = $parts[$i]
            if (-not $node.Dirs.Contains($name)) { $node.Dirs[$name] = (New-EnvDocFileTreeNode) }
            $node = $node.Dirs[$name]
        }

        $leaf = $parts[$parts.Count - 1]
        $type = [string](Get-JsonValue -Object $e -Path 'type' -Default 'file')
        if ($type -eq 'dir') {
            if (-not $node.Dirs.Contains($leaf)) { $node.Dirs[$leaf] = (New-EnvDocFileTreeNode) }
        }
        else {
            [void]$node.Files.Add(@{ Name = $leaf; Entry = $e })
        }
    }
    return $root
}

function Get-EnvDocFileTreeCount {
    param($Node)

    $files = @($Node.Files).Count
    $dirs = 0
    foreach ($k in @($Node.Dirs.Keys)) {
        $dirs++
        $c = Get-EnvDocFileTreeCount -Node $Node.Dirs[$k]
        $files += $c.Files
        $dirs   += $c.Dirs
    }
    return @{ Files = $files; Dirs = $dirs }
}

function New-EnvDocFileTreeHtml {
    param($Node)

    $sb = New-Object System.Text.StringBuilder

    # サブディレクトリ(既定は閉じる。開いたままだとスクロール量が元に戻る)
    foreach ($name in @($Node.Dirs.Keys)) {
        $child = $Node.Dirs[$name]
        $c = Get-EnvDocFileTreeCount -Node $child
        $summary = '{0}/  ({1} ファイル / {2} ディレクトリ)' -f $name, $c.Files, $c.Dirs
        $inner = New-EnvDocFileTreeHtml -Node $child
        [void]$sb.Append((New-HtmlDetails -Summary $summary -Body $inner))
    }

    # このディレクトリ直下のファイル。階層で位置が分かるので名前だけ出す
    $files = @($Node.Files)
    if ($files.Count -gt 0) {
        $rows = New-Object System.Collections.ArrayList
        foreach ($f in ($files | Sort-Object { $_.Name })) {
            $e = $f.Entry
            [void]$rows.Add(@{
                Cells = @(
                    (ConvertTo-HtmlText -Text ([string]$f.Name)),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'type'  -Default '-'))),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'size'  -Default ''))),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $e -Path 'owner' -Default '')))
                )
                Mismatch = $false
            })
        }
        # mtime は実行時に変わる情報なので定義書には出さない
        [void]$sb.Append((New-HtmlTable -Headers @('名前', '種別', 'サイズ', 'オーナー') -Rows $rows.ToArray()))
    }

    if ($sb.Length -eq 0) { return '<p class="empty">データなし</p>' }
    return $sb.ToString()
}

function Write-EnvDocFilelistPage {
    param([hashtable]$Model, [hashtable]$Server, [string]$OutputRoot)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'filelist')) { return }
    $targets = @(Get-JsonValue -Object $Server.Snapshot -Path 'filelist' -Default @())

    $body = New-Object System.Text.StringBuilder
    $toc  = New-Object System.Collections.ArrayList
    $idx = 0
    foreach ($t in $targets) {
        $idx++
        $key = [string](Get-JsonValue -Object $t -Path 'key' -Default '-')
        $path = [string](Get-JsonValue -Object $t -Path 'path' -Default '')
        $entries = @(Get-JsonValue -Object $t -Path 'entries' -Default @())

        $tree = New-EnvDocFileTree -Entries $entries
        $sub = New-Object System.Text.StringBuilder
        if ($path) {
            [void]$sub.Append('<p class="meta">').Append((ConvertTo-HtmlText -Text $path)).Append('</p>')
        }
        if (Get-JsonValue -Object $t -Path 'truncated' -Default $false) {
            [void]$sub.Append('<div class="warn">上限に達したため一部のみ収集されています</div>')
        }
        [void]$sub.Append((New-EnvDocFileTreeHtml -Node $tree))

        $id = 'target-{0}' -f $idx
        [void]$toc.Add(@{ Id = $id; Label = $key })
        [void]$body.Append((New-HtmlSection -Title ('{0} ({1} 件)' -f $key, $entries.Count) -Id $id -Body $sub.ToString()))
    }

    $title = 'ファイル一覧: {0}' -f $Server.Hostname
    $page = (New-HtmlToc -Items $toc.ToArray()) + $body.ToString() + (New-HtmlBackToTop)
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body $page
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
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body ($body.ToString() + (New-HtmlBackToTop))
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}-configs.html' -f $Server.Hostname)) -Content $html
}
