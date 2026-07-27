# aws.html — AWS 構成。
# SG / IAM ロールは複数サーバで共有されるため、リソース単位に 1 回だけ出し、
# 適用サーバを逆引きで併記する。

function New-EnvDocSgRuleTable {
    param($Rules, [string]$Direction)

    $rows = New-Object System.Collections.ArrayList
    foreach ($r in @($Rules)) {
        $proto = [string](Get-JsonValue -Object $r -Path 'protocol' -Default '-')
        $from  = Get-JsonValue -Object $r -Path 'from_port'
        $to    = Get-JsonValue -Object $r -Path 'to_port'
        $port  = if ($null -eq $from -and $null -eq $to) { 'all' }
                 elseif ("$from" -eq "$to") { "$from" }
                 else { "$from-$to" }
        $cidrs = (@(Get-JsonValue -Object $r -Path 'cidrs'   -Default @()) -join ', ')
        $refs  = (@(Get-JsonValue -Object $r -Path 'sg_refs' -Default @()) -join ', ')
        [void]$rows.Add(@{
            Cells = @(
                (ConvertTo-HtmlText -Text $Direction),
                (ConvertTo-HtmlText -Text $proto),
                (ConvertTo-HtmlText -Text $port),
                (ConvertTo-HtmlText -Text $cidrs),
                (ConvertTo-HtmlText -Text $refs)
            )
            Mismatch = $false
        })
    }
    return $rows.ToArray()
}

function Write-EnvDocAwsPage {
    param([Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][string]$OutputRoot)

    $aws = $Model.Aws
    $body = New-Object System.Text.StringBuilder

    # インスタンス一覧(aws 未収集のサーバも行として出す)
    $instByHost = @{}
    foreach ($i in @($aws.Instances)) { $instByHost[$i.Hostname] = $i }

    $rows = New-Object System.Collections.ArrayList
    foreach ($s in $Model.Servers) {
        $nameCell = if ($s.HasSnapshot) { New-HtmlCell -Text $s.Hostname -Link ('servers/{0}.html' -f $s.Hostname) }
                    else { ConvertTo-HtmlText -Text $s.Hostname }

        if (-not $instByHost.ContainsKey($s.Hostname)) {
            [void]$rows.Add(@{
                Cells = @($nameCell) + (1..6 | ForEach-Object { '<span class="missing">未収集</span>' })
                Mismatch = $false
            })
            continue
        }
        $i = $instByHost[$s.Hostname]
        [void]$rows.Add(@{
            Cells = @(
                $nameCell,
                (ConvertTo-HtmlText -Text $i.InstanceId),
                (ConvertTo-HtmlText -Text $i.InstanceType),
                (ConvertTo-HtmlText -Text $i.Az),
                (ConvertTo-HtmlText -Text $i.PrivateIp),
                (ConvertTo-HtmlText -Text $i.SubnetId),
                (ConvertTo-HtmlText -Text $i.VpcId)
            )
            Mismatch = $false
        })
    }
    $t = New-HtmlTable -Headers @('ホスト名', 'インスタンス ID', 'タイプ', 'AZ', 'Private IP', 'Subnet', 'VPC') -Rows $rows.ToArray()
    [void]$body.Append((New-HtmlSection -Title 'インスタンス一覧' -Body $t))

    # ネットワーク構成
    $netRows = New-Object System.Collections.ArrayList
    foreach ($v in @($aws.Vpcs)) {
        foreach ($sub in @($aws.Subnets | Where-Object { $_.VpcId -eq $v.VpcId })) {
            [void]$netRows.Add(@{
                Cells = @(
                    (ConvertTo-HtmlText -Text ('{0} ({1})' -f $v.VpcId, $v.Cidr)),
                    (ConvertTo-HtmlText -Text ('{0} ({1})' -f $sub.SubnetId, $sub.Cidr)),
                    (ConvertTo-HtmlText -Text $sub.Az),
                    (ConvertTo-HtmlText -Text ((@($sub.Hosts)) -join ', '))
                )
                Mismatch = $false
            })
        }
    }
    $t = New-HtmlTable -Headers @('VPC', 'Subnet', 'AZ', '所属サーバ') -Rows $netRows.ToArray()
    [void]$body.Append((New-HtmlSection -Title 'ネットワーク構成' -Body $t))

    # ルートテーブル
    $rtRows = New-Object System.Collections.ArrayList
    foreach ($rt in @($aws.RouteTables)) {
        foreach ($r in @($rt.Routes)) {
            [void]$rtRows.Add(@{
                Cells = @(
                    (ConvertTo-HtmlText -Text $rt.RouteTableId),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $r -Path 'dest'   -Default '-'))),
                    (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $r -Path 'target' -Default '-')))
                )
                Mismatch = $false
            })
        }
    }
    $t = New-HtmlTable -Headers @('ルートテーブル', '宛先', 'ターゲット') -Rows $rtRows.ToArray()
    [void]$body.Append((New-HtmlSection -Title 'ルートテーブル' -Body $t))

    # Security Group(リソース単位)
    $sgBody = New-Object System.Text.StringBuilder
    foreach ($sg in @($aws.SecurityGroups)) {
        [void]$sgBody.Append('<h3>').Append((ConvertTo-HtmlText -Text ('{0} ({1})' -f $sg.GroupName, $sg.GroupId))).Append('</h3>')
        if ($sg.Description) {
            [void]$sgBody.Append('<p class="meta">').Append((ConvertTo-HtmlText -Text $sg.Description)).Append('</p>')
        }
        [void]$sgBody.Append('<p class="meta">適用サーバ: ').Append((ConvertTo-HtmlText -Text ((@($sg.AppliedTo)) -join ', '))).Append('</p>')
        $ruleRows = @(New-EnvDocSgRuleTable -Rules $sg.Ingress -Direction 'ingress') +
                    @(New-EnvDocSgRuleTable -Rules $sg.Egress  -Direction 'egress')
        [void]$sgBody.Append((New-HtmlTable -Headers @('方向', 'プロトコル', 'ポート', 'CIDR', '参照 SG') -Rows $ruleRows))
    }
    if ($sgBody.Length -eq 0) { [void]$sgBody.Append('<p class="empty">データなし</p>') }
    [void]$body.Append((New-HtmlSection -Title 'Security Group' -Body $sgBody.ToString()))

    # IAM(リソース単位)
    $iamBody = New-Object System.Text.StringBuilder
    foreach ($role in @($aws.IamRoles)) {
        [void]$iamBody.Append('<h3>').Append((ConvertTo-HtmlText -Text $role.RoleName)).Append('</h3>')
        [void]$iamBody.Append('<p class="meta">使用サーバ: ').Append((ConvertTo-HtmlText -Text ((@($role.AppliedTo)) -join ', '))).Append('</p>')

        $pRows = New-Object System.Collections.ArrayList
        foreach ($p in @($role.AttachedPolicies)) {
            [void]$pRows.Add(@{
                Cells = @('managed', (ConvertTo-HtmlText -Text ([string](Get-JsonValue -Object $p -Path 'name' -Default '-'))))
                Mismatch = $false
            })
        }
        foreach ($p in @($role.InlinePolicies)) {
            [void]$pRows.Add(@{ Cells = @('inline', (ConvertTo-HtmlText -Text ([string]$p))); Mismatch = $false })
        }
        [void]$iamBody.Append((New-HtmlTable -Headers @('種別', 'ポリシー名') -Rows $pRows.ToArray()))
    }
    if ($iamBody.Length -eq 0) { [void]$iamBody.Append('<p class="empty">データなし</p>') }
    [void]$body.Append((New-HtmlSection -Title 'IAM' -Body $iamBody.ToString()))

    $html = New-HtmlPage -Title 'AWS 構成' -SystemName $Model.System.Name -RelRoot '.' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot 'aws.html') -Content $html
}
