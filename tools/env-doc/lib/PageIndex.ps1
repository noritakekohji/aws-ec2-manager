# index.html — システム概要・サーバ一覧・生成メタ・警告

function Write-EnvDocIndexPage {
    param([Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][string]$OutputRoot)

    $sys = $Model.System
    $body = New-Object System.Text.StringBuilder

    # システム概要
    $overview = New-Object System.Collections.ArrayList
    [void]$overview.Add(@{ Cells = @('システム ID', (ConvertTo-HtmlText -Text $sys.Id)); Mismatch = $false })
    [void]$overview.Add(@{ Cells = @('システム名', (ConvertTo-HtmlText -Text $sys.Name)); Mismatch = $false })
    if ($sys.Owner)       { [void]$overview.Add(@{ Cells = @('管理部署', (ConvertTo-HtmlText -Text $sys.Owner)); Mismatch = $false }) }
    if ($sys.Contact)     { [void]$overview.Add(@{ Cells = @('連絡先', (ConvertTo-HtmlText -Text $sys.Contact)); Mismatch = $false }) }
    if ($sys.Description) { [void]$overview.Add(@{ Cells = @('概要', (ConvertTo-HtmlText -Text $sys.Description)); Mismatch = $false }) }
    [void]$overview.Add(@{ Cells = @('生成日時', (ConvertTo-HtmlText -Text $Model.Meta.GeneratedAt)); Mismatch = $false })
    [void]$body.Append((New-HtmlSection -Title 'システム概要' -Body (New-HtmlTable -Headers @('項目', '値') -Rows $overview.ToArray())))

    # 構成図
    if ($sys.Diagram) {
        $img = '<p><img src="{0}" alt="構成図" style="max-width:100%"></p>' -f (ConvertTo-HtmlText -Text $sys.Diagram)
        [void]$body.Append((New-HtmlSection -Title '構成図' -Body $img))
    }

    # サーバ一覧
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in $Model.Servers) {
        $link = ''
        $nameCell = ConvertTo-HtmlText -Text $s.Hostname
        if ($s.HasSnapshot) {
            $link = 'servers/{0}.html' -f $s.Hostname
            $nameCell = New-HtmlCell -Text $s.Hostname -Link $link
        }
        $osCell = if ($s.HasSnapshot) {
            ConvertTo-HtmlText -Text ('{0} ({1})' -f (Get-JsonValue -Object $s.Snapshot -Path 'os.os_name' -Default '-'), $s.OsType)
        } else { '<span class="missing">未収集</span>' }

        $ipCell = '<span class="missing">未収集</span>'
        if ($s.HasSnapshot) {
            # network.interfaces の要素は {name, address, prefix}
            $ips = @(Get-JsonValue -Object $s.Snapshot -Path 'network.interfaces' -Default @())
            $ipCell = ConvertTo-HtmlText -Text (@($ips | ForEach-Object { [string]$_.address }) -join ', ')
        }

        [void]$rows.Add(@{
            Cells = @(
                $nameCell,
                (ConvertTo-HtmlText -Text $s.Role),
                $osCell,
                $ipCell,
                (ConvertTo-HtmlText -Text $s.CollectedAt),
                (ConvertTo-HtmlText -Text $s.Note)
            )
            Mismatch = $false
        })
    }
    $table = New-HtmlTable -Headers @('ホスト名', '役割', 'OS', 'IP アドレス', '収集日時', '備考') -Rows $rows.ToArray()
    [void]$body.Append((New-HtmlSection -Title 'サーバ一覧' -Body $table))

    # 警告
    if (@($Model.Meta.Warnings).Count -gt 0) {
        $items = New-Object System.Text.StringBuilder
        [void]$items.Append('<div class="warn"><ul>')
        foreach ($w in $Model.Meta.Warnings) {
            [void]$items.Append('<li>').Append((ConvertTo-HtmlText -Text $w)).Append('</li>')
        }
        [void]$items.Append('</ul></div>')
        [void]$body.Append((New-HtmlSection -Title '警告' -Body $items.ToString()))
    }

    $html = New-HtmlPage -Title 'システム概要' -SystemName $Model.System.Name -RelRoot '.' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot 'index.html') -Content $html
}
