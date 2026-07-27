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

    $title = 'サーバ詳細: {0}' -f $Server.Hostname
    $html = New-HtmlPage -Title $title -SystemName $Model.System.Name -RelRoot '..' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot ('servers\{0}.html' -f $Server.Hostname)) -Content $html
}
