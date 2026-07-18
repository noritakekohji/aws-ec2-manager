<#
.SYNOPSIS
    Security Group tab: view/edit SGs of the selected instance.
.DESCRIPTION
    左ペインの選択インスタンスに追従。VPC 内 SG は AppState.SgCache に
    インスタンス ID 単位でキャッシュし、タブがアクティブなときだけ取得する。
    取得・適用は AsyncRunner 経由(UI はブロックしない)。
    差分プレビュー / 実効ルール diff / HTML レポートは v1 から移植。
    PowerShell 5.1 compatible. App.ps1 から dot-source される。
#>

$reloadSgButton = Find-Control -Name 'ReloadSgButton'
$sgStatusText = Find-Control -Name 'SgStatusText'
$applySgButton = Find-Control -Name 'ApplySgButton'
$exportSgReportButton = Find-Control -Name 'ExportSgReportButton'
$appliedSgList = Find-Control -Name 'AppliedSgList'
$availableSgList = Find-Control -Name 'AvailableSgList'
$moveToAppliedButton = Find-Control -Name 'MoveToAppliedButton'
$moveToAvailableButton = Find-Control -Name 'MoveToAvailableButton'
$sgDiffPanel = Find-Control -Name 'SgDiffPanel'

$sgTabState = [PSCustomObject]@{
    OriginalSgIds     = @()
    OriginalSgItems   = @()
    CurrentInstanceId = $null
    CurrentVpcId      = $null
    LastReportPath    = $null
    Loaded            = $false
}

function Test-SgTabActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $tabs = Find-Control -Name 'DetailTabs'
    return ($tabs.SelectedIndex -eq 1)
}

function Get-SgDisplayItem {
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [string]$GroupName,
        [string]$Description,
        [string]$VpcId,
        [object[]]$IpPermissions,
        [object[]]$IpPermissionsEgress
    )
    $name = if ([string]::IsNullOrEmpty($GroupName)) { '' } else { $GroupName }
    [PSCustomObject]@{
        GroupId             = $GroupId
        GroupName           = $name
        Description         = $Description
        VpcId               = $VpcId
        IpPermissions       = @($IpPermissions)
        IpPermissionsEgress = @($IpPermissionsEgress)
        DisplayLabel        = "$GroupId ($name)"
    }
}

function Get-SgLabel {
    param($Item)
    if ($null -eq $Item) { return '' }
    $name = [string](Get-ObjectPropertyValue -Object $Item -Name 'GroupName')
    $id = [string](Get-ObjectPropertyValue -Object $Item -Name 'GroupId')
    if ([string]::IsNullOrWhiteSpace($name)) { return $id }
    return "$id ($name)"
}

function Get-SgItemsFromList {
    param($ListBox)
    $items = @()
    if ($null -ne $ListBox.ItemsSource) {
        foreach ($x in $ListBox.ItemsSource) { $items += $x }
    }
    return $items
}

function Add-SgDiffText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,
        [string]$Color = '#E5E7EB',
        [bool]$Bold = $false,
        [double]$FontSize = 13,
        [int]$Bottom = 4
    )

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
    $tb.FontSize = $FontSize
    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tb.Margin = New-Object System.Windows.Thickness 0, 0, 0, $Bottom
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $sgDiffPanel.Children.Add($tb) | Out-Null
    return $tb
}

function Get-SgRuleDetailText {
    param($SecurityGroup)
    $lines = @()
    $lines += "Description: $($SecurityGroup.Description)"
    $rules = @(Get-SgRuleRowsForItems -Items @($SecurityGroup))
    $inRules = @($rules | Where-Object { $_.Direction -eq 'Inbound' })
    $outRules = @($rules | Where-Object { $_.Direction -eq 'Outbound' })
    $lines += ''
    $lines += '[Inbound]'
    if ($inRules.Count -eq 0) { $lines += '  ルールなし' }
    foreach ($rule in $inRules) { $lines += ('  ' + (Format-SgRuleLine -Rule $rule)) }
    $lines += ''
    $lines += '[Outbound]'
    if ($outRules.Count -eq 0) { $lines += '  ルールなし' }
    foreach ($rule in $outRules) { $lines += ('  ' + (Format-SgRuleLine -Rule $rule)) }
    return ($lines -join "`r`n")
}

function Add-SgDiffExpander {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mark,
        [Parameter(Mandatory = $true)]$SecurityGroup
    )

    $color = '#94A3B8'
    if ($Mark -eq '[+]') { $color = '#38BDF8' }
    if ($Mark -eq '[-]') { $color = '#F97373' }
    $expander = New-Object System.Windows.Controls.Expander
    $expander.IsExpanded = $false
    $expander.Margin = New-Object System.Windows.Thickness 0, 4, 0, 6
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = "$Mark $(Get-SgLabel -Item $SecurityGroup)"
    $header.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $header.FontWeight = [System.Windows.FontWeights]::SemiBold
    $expander.Header = $header

    $content = New-Object System.Windows.Controls.TextBox
    $content.Text = Get-SgRuleDetailText -SecurityGroup $SecurityGroup
    $content.IsReadOnly = $true
    $content.AcceptsReturn = $true
    $content.TextWrapping = [System.Windows.TextWrapping]::NoWrap
    $content.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $content.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $content.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas, Yu Gothic UI, Meiryo UI'
    $content.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E5E7EB'))
    $content.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0B1220'))
    $content.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#263247'))
    $content.Margin = New-Object System.Windows.Thickness 18, 6, 0, 0
    $content.MinHeight = 120
    $expander.Content = $content
    $sgDiffPanel.Children.Add($expander) | Out-Null
}

function Show-SgDiffPanel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param($Diff)

    $sgDiffPanel.Children.Clear()
    if ([string]::IsNullOrEmpty($sgTabState.CurrentInstanceId)) {
        Add-SgDiffText -Text 'インスタンスを選択してください。' -Color '#94A3B8' | Out-Null
        return
    }
    if ($null -eq $Diff) {
        Add-SgDiffText -Text '差分を計算できません。' -Color '#F97373' -Bold $true | Out-Null
        return
    }

    Add-SgDiffText -Text "Instance: $($sgTabState.CurrentInstanceId)" -Color '#E5E7EB' -Bold $true | Out-Null
    Add-SgDiffText -Text "適用前SG: $($Diff.BeforeIds -join ', ')" -Color '#94A3B8' -Bottom 2 | Out-Null
    Add-SgDiffText -Text "適用後SG: $($Diff.AfterIds -join ', ')" -Color '#94A3B8' -Bottom 10 | Out-Null

    Add-SgDiffText -Text '実効ルール差分（メモ欄は対象外）' -Color '#BAE6FD' -Bold $true -FontSize 14 | Out-Null
    $netAdded = @($Diff.AddedRules)
    $netRemoved = @($Diff.RemovedRules)
    if ($netAdded.Count -gt 0 -or $netRemoved.Count -gt 0) {
        foreach ($rule in $netAdded) {
            Add-SgDiffText -Text ('[+] ' + (Format-SgNetRuleLine -Rule $rule)) -Color '#38BDF8' | Out-Null
        }
        foreach ($rule in $netRemoved) {
            Add-SgDiffText -Text ('[-] ' + (Format-SgNetRuleLine -Rule $rule)) -Color '#F97373' | Out-Null
        }
    }
    else {
        Add-SgDiffText -Text '実効ルール差分なし（SGの組合せは変わっても開放ルールは同じです）' -Color '#94A3B8' | Out-Null
    }
    Add-SgDiffText -Text '' -Color '#94A3B8' -Bottom 6 | Out-Null

    Add-SgDiffText -Text 'Security Group 差分' -Color '#BAE6FD' -Bold $true -FontSize 14 | Out-Null
    if ($Diff.Changed) {
        foreach ($sg in @($Diff.AddedSgs)) {
            Add-SgDiffText -Text ('[+] ' + (Get-SgLabel -Item $sg)) -Color '#38BDF8' -Bold $true | Out-Null
        }
        foreach ($sg in @($Diff.RemovedSgs)) {
            Add-SgDiffText -Text ('[-] ' + (Get-SgLabel -Item $sg)) -Color '#F97373' -Bold $true | Out-Null
        }

        Add-SgDiffText -Text '差分SGの内容（クリックで開閉）' -Color '#BAE6FD' -Bold $true -FontSize 14 -Bottom 6 | Out-Null
        foreach ($sg in @($Diff.AddedSgs)) {
            Add-SgDiffExpander -Mark '[+]' -SecurityGroup $sg
        }
        foreach ($sg in @($Diff.RemovedSgs)) {
            Add-SgDiffExpander -Mark '[-]' -SecurityGroup $sg
        }
    }
    else {
        Add-SgDiffText -Text 'SG差分はありません。' -Color '#94A3B8' | Out-Null
    }

    if (@($Diff.ExistingSgs).Count -gt 0) {
        Add-SgDiffText -Text '元からあるSGの内容（クリックで開閉）' -Color '#BAE6FD' -Bold $true -FontSize 14 -Bottom 6 | Out-Null
        foreach ($sg in @($Diff.ExistingSgs)) {
            Add-SgDiffExpander -Mark '[=]' -SecurityGroup $sg
        }
    }
}

function Update-SgDiffPreview {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param()
    $diff = Get-SgDiffData
    Show-SgDiffPanel -Diff $diff
    $exportSgReportButton.IsEnabled = $true
}

function ConvertTo-SgRuleRows {
    param(
        [object[]]$Permissions,
        [Parameter(Mandatory = $true)][string]$Direction
    )
    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($perm in @($Permissions)) {
        if ($null -eq $perm) { continue }
        $protocol = [string](Get-ObjectPropertyValue -Object $perm -Name 'IpProtocol')
        if ([string]::IsNullOrWhiteSpace($protocol)) { $protocol = 'all' }
        $fromPort = Get-ObjectPropertyValue -Object $perm -Name 'FromPort'
        $toPort = Get-ObjectPropertyValue -Object $perm -Name 'ToPort'
        $portText = 'All'
        if ($null -ne $fromPort -and $null -ne $toPort) {
            if ([string]$fromPort -eq [string]$toPort) { $portText = [string]$fromPort } else { $portText = "$fromPort-$toPort" }
        }

        $targets = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($r in @((Get-ObjectPropertyValue -Object $perm -Name 'IpRanges'))) {
            $cidr = [string](Get-ObjectPropertyValue -Object $r -Name 'CidrIp')
            $desc = [string](Get-ObjectPropertyValue -Object $r -Name 'Description')
            if (-not [string]::IsNullOrWhiteSpace($cidr)) { $targets.Add([PSCustomObject]@{ Target = $cidr; Description = $desc }) }
        }
        foreach ($r in @((Get-ObjectPropertyValue -Object $perm -Name 'Ipv6Ranges'))) {
            $cidr6 = [string](Get-ObjectPropertyValue -Object $r -Name 'CidrIpv6')
            $desc6 = [string](Get-ObjectPropertyValue -Object $r -Name 'Description')
            if (-not [string]::IsNullOrWhiteSpace($cidr6)) { $targets.Add([PSCustomObject]@{ Target = $cidr6; Description = $desc6 }) }
        }
        foreach ($r in @((Get-ObjectPropertyValue -Object $perm -Name 'UserIdGroupPairs'))) {
            $groupId = [string](Get-ObjectPropertyValue -Object $r -Name 'GroupId')
            $descGroup = [string](Get-ObjectPropertyValue -Object $r -Name 'Description')
            if (-not [string]::IsNullOrWhiteSpace($groupId)) { $targets.Add([PSCustomObject]@{ Target = $groupId; Description = $descGroup }) }
        }
        foreach ($r in @((Get-ObjectPropertyValue -Object $perm -Name 'PrefixListIds'))) {
            $prefixId = [string](Get-ObjectPropertyValue -Object $r -Name 'PrefixListId')
            $descPrefix = [string](Get-ObjectPropertyValue -Object $r -Name 'Description')
            if (-not [string]::IsNullOrWhiteSpace($prefixId)) { $targets.Add([PSCustomObject]@{ Target = $prefixId; Description = $descPrefix }) }
        }
        if ($targets.Count -eq 0) { $targets.Add([PSCustomObject]@{ Target = '(targetなし)'; Description = '' }) }

        foreach ($target in $targets) {
            $rows.Add([PSCustomObject]@{
                    Direction   = $Direction
                    Protocol    = $protocol
                    Port        = $portText
                    Target      = $target.Target
                    Description = $target.Description
                })
        }
    }
    if ($rows.Count -eq 0) {
        $rows.Add([PSCustomObject]@{
                Direction   = $Direction
                Protocol    = '(ルールなし)'
                Port        = ''
                Target      = ''
                Description = ''
            })
    }
    return $rows.ToArray()
}

function Get-SgRuleKey {
    param($Rule)
    $parts = @(
        [string]$Rule.Direction,
        [string]$Rule.Protocol,
        [string]$Rule.Port,
        [string]$Rule.Target,
        [string]$Rule.Description,
        [string]$Rule.SecurityGroupId
    )
    return ($parts -join '|')
}

function Get-SgRuleRowsForItems {
    param([object[]]$Items)
    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($sg in @($Items)) {
        if ($null -eq $sg) { continue }
        $sgLabel = Get-SgLabel -Item $sg
        $inRows = @(ConvertTo-SgRuleRows -Permissions $sg.IpPermissions -Direction 'Inbound')
        $outRows = @(ConvertTo-SgRuleRows -Permissions $sg.IpPermissionsEgress -Direction 'Outbound')
        foreach ($row in @($inRows + $outRows)) {
            if ([string]$row.Protocol -eq '(ルールなし)') { continue }
            $row | Add-Member -NotePropertyName SecurityGroupId -NotePropertyValue ([string]$sg.GroupId) -Force
            $row | Add-Member -NotePropertyName SecurityGroup -NotePropertyValue $sgLabel -Force
            $row | Add-Member -NotePropertyName RuleKey -NotePropertyValue (Get-SgRuleKey -Rule $row) -Force
            $rows.Add($row)
        }
    }
    return $rows.ToArray()
}

function Get-SgDiffData {
    [CmdletBinding()]
    param()

    $currentItems = @(Get-SgItemsFromList -ListBox $appliedSgList)
    $currentIds = @()
    foreach ($x in $currentItems) { $currentIds += [string]$x.GroupId }
    $originalIds = @()
    if ($null -ne $sgTabState.OriginalSgIds) { $originalIds = @($sgTabState.OriginalSgIds) }
    $originalItems = @()
    if ($null -ne $sgTabState.OriginalSgItems) { $originalItems = @($sgTabState.OriginalSgItems) }

    $addedSgs = @()
    foreach ($item in $currentItems) {
        if ($originalIds -notcontains [string]$item.GroupId) { $addedSgs += $item }
    }

    $existingSgs = @()
    foreach ($item in $currentItems) {
        if ($originalIds -contains [string]$item.GroupId) { $existingSgs += $item }
    }

    $removedSgs = @()
    foreach ($item in $originalItems) {
        if ($currentIds -notcontains [string]$item.GroupId) { $removedSgs += $item }
    }

    $beforeRules = @(Get-SgRuleRowsForItems -Items $originalItems)
    $afterRules = @(Get-SgRuleRowsForItems -Items $currentItems)
    $ruleDiff = Get-SgRuleDiff -BeforeRules $beforeRules -AfterRules $afterRules
    $addedRules = @($ruleDiff.Added)
    $removedRules = @($ruleDiff.Removed)

    [PSCustomObject]@{
        BeforeIds    = $originalIds
        AfterIds     = $currentIds
        AddedSgs     = $addedSgs
        RemovedSgs   = $removedSgs
        ExistingSgs  = $existingSgs
        ChangedSgs   = @($addedSgs + $removedSgs)
        Changed      = (($addedSgs.Count -gt 0) -or ($removedSgs.Count -gt 0))
        AddedRules   = $addedRules
        RemovedRules = $removedRules
    }
}

function Format-SgRuleLine {
    param(
        [Parameter(Mandatory = $true)]$Rule
    )
    return ("{0,-8} {1,-7} {2,-9} {3,-22} # {4}" -f $Rule.Direction, $Rule.Protocol, $Rule.Port, $Rule.Target, $Rule.Description)
}

function Format-SgNetRuleLine {
    param(
        [Parameter(Mandatory = $true)]$Rule
    )
    $src = ''
    $labels = @($Rule.SourceSgs)
    if ($labels.Count -gt 0) {
        $first = [string]$labels[0]
        if ($labels.Count -gt 1) { $src = " (from $first +$($labels.Count - 1))" }
        else { $src = " (from $first)" }
    }
    return ("{0,-8} {1,-7} {2,-9} {3}{4}" -f $Rule.Direction, $Rule.Protocol, $Rule.Port, $Rule.Target, $src)
}

function Get-SgReportDirectory {
    [CmdletBinding()]
    param()
    return (Get-AppLogDirectory)
}

function New-SgReportHtml {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-requested local HTML report generation.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    if ([string]::IsNullOrEmpty($sgTabState.CurrentInstanceId)) {
        Set-StatusText -Message 'インスタンス未選択のためHTML出力できません'
        return $null
    }

    $diff = Get-SgDiffData
    $dir = $Directory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeInstanceId = Get-SafeFileName -Name $sgTabState.CurrentInstanceId
    $path = Join-Path $dir ("sg-change-{0}-{1}.html" -f $safeInstanceId, $stamp)

    $sgRows = ''
    foreach ($sg in @($diff.AddedSgs)) {
        $sgRows += "<tr><td class='added'>[+]</td><td>$(ConvertTo-HtmlText (Get-SgLabel -Item $sg))</td><td>$(ConvertTo-HtmlText $sg.Description)</td></tr>`r`n"
    }
    foreach ($sg in @($diff.RemovedSgs)) {
        $sgRows += "<tr><td class='removed'>[-]</td><td>$(ConvertTo-HtmlText (Get-SgLabel -Item $sg))</td><td>$(ConvertTo-HtmlText $sg.Description)</td></tr>`r`n"
    }
    if ([string]::IsNullOrWhiteSpace($sgRows)) {
        $sgRows = "<tr><td colspan='3'>SG差分はありません</td></tr>`r`n"
    }

    $detailBlocks = ''
    foreach ($sg in @($diff.ChangedSgs)) {
        $markClass = if (@($diff.AddedSgs | Where-Object { $_.GroupId -eq $sg.GroupId }).Count -gt 0) { 'added' } else { 'removed' }
        $markText = if ($markClass -eq 'added') { '[+]' } else { '[-]' }
        $ruleRows = ''
        foreach ($rule in @(Get-SgRuleRowsForItems -Items @($sg))) {
            $ruleRows += "<tr><td>$(ConvertTo-HtmlText $rule.Direction)</td><td>$(ConvertTo-HtmlText $rule.Protocol)</td><td>$(ConvertTo-HtmlText $rule.Port)</td><td>$(ConvertTo-HtmlText $rule.Target)</td><td>$(ConvertTo-HtmlText $rule.Description)</td></tr>`r`n"
        }
        if ([string]::IsNullOrWhiteSpace($ruleRows)) {
            $ruleRows = "<tr><td colspan='5'>ルールなし</td></tr>`r`n"
        }
        $detailBlocks += "<details class='sg-detail'><summary class='$markClass'>$markText $(ConvertTo-HtmlText (Get-SgLabel -Item $sg))</summary>`r`n"
        $detailBlocks += "<table><thead><tr><th>方向</th><th>Protocol</th><th>Port</th><th>Source / Destination</th><th>Description</th></tr></thead><tbody>$ruleRows</tbody></table>`r`n"
        $detailBlocks += "</details>`r`n"
    }

    $existingBlocks = ''
    foreach ($sg in @($diff.ExistingSgs)) {
        $ruleRows = ''
        foreach ($rule in @(Get-SgRuleRowsForItems -Items @($sg))) {
            $ruleRows += "<tr><td>$(ConvertTo-HtmlText $rule.Direction)</td><td>$(ConvertTo-HtmlText $rule.Protocol)</td><td>$(ConvertTo-HtmlText $rule.Port)</td><td>$(ConvertTo-HtmlText $rule.Target)</td><td>$(ConvertTo-HtmlText $rule.Description)</td></tr>`r`n"
        }
        if ([string]::IsNullOrWhiteSpace($ruleRows)) {
            $ruleRows = "<tr><td colspan='5'>ルールなし</td></tr>`r`n"
        }
        $existingBlocks += "<details class='sg-detail'><summary class='existing'>[=] $(ConvertTo-HtmlText (Get-SgLabel -Item $sg))</summary>`r`n"
        $existingBlocks += "<table><thead><tr><th>方向</th><th>Protocol</th><th>Port</th><th>Source / Destination</th><th>Description</th></tr></thead><tbody>$ruleRows</tbody></table>`r`n"
        $existingBlocks += "</details>`r`n"
    }

    $beforeRows = ''
    foreach ($id in @($diff.BeforeIds)) { $beforeRows += "<li>$(ConvertTo-HtmlText $id)</li>`r`n" }
    $afterRows = ''
    foreach ($id in @($diff.AfterIds)) { $afterRows += "<li>$(ConvertTo-HtmlText $id)</li>`r`n" }

    $netRuleRows = ''
    foreach ($rule in @($diff.AddedRules)) {
        $netRuleRows += "<tr><td class='added'>[+]</td><td>$(ConvertTo-HtmlText $rule.Direction)</td><td>$(ConvertTo-HtmlText $rule.Protocol)</td><td>$(ConvertTo-HtmlText $rule.Port)</td><td>$(ConvertTo-HtmlText $rule.Target)</td><td>$(ConvertTo-HtmlText ((@($rule.SourceSgs)) -join ', '))</td></tr>`r`n"
    }
    foreach ($rule in @($diff.RemovedRules)) {
        $netRuleRows += "<tr><td class='removed'>[-]</td><td>$(ConvertTo-HtmlText $rule.Direction)</td><td>$(ConvertTo-HtmlText $rule.Protocol)</td><td>$(ConvertTo-HtmlText $rule.Port)</td><td>$(ConvertTo-HtmlText $rule.Target)</td><td>$(ConvertTo-HtmlText ((@($rule.SourceSgs)) -join ', '))</td></tr>`r`n"
    }
    if ([string]::IsNullOrWhiteSpace($netRuleRows)) {
        $netRuleRows = "<tr><td colspan='6'>実効ルール差分なし</td></tr>`r`n"
    }

    $html = @"
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8" />
<title>Security Group Change Report - $(ConvertTo-HtmlText $sgTabState.CurrentInstanceId)</title>
<style>
body { font-family: "Yu Gothic UI", "Meiryo UI", sans-serif; margin: 24px; color: #172033; background: #f8fafc; }
h1 { margin: 0 0 8px; font-size: 22px; }
h2 { margin-top: 24px; font-size: 16px; border-bottom: 1px solid #cbd5e1; padding-bottom: 6px; }
h3 { margin: 18px 0 8px; font-size: 14px; }
details.sg-detail { border: 1px solid #cbd5e1; border-radius: 8px; padding: 10px 12px; margin: 10px 0; background: #f8fafc; }
summary { cursor: pointer; font-weight: 700; }
.meta { color: #475569; margin-bottom: 18px; }
.panel { background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
.note { color: #475569; background: #f1f5f9; border-left: 4px solid #94a3b8; padding: 10px 12px; margin: 10px 0 12px; line-height: 1.6; }
table { border-collapse: collapse; width: 100%; background: #ffffff; margin-top: 8px; }
th, td { border: 1px solid #cbd5e1; padding: 8px 10px; text-align: left; vertical-align: top; word-break: break-word; }
th { background: #e2e8f0; }
.added { color: #0369a1; font-weight: 700; }
.removed { color: #b91c1c; font-weight: 700; }
.existing { color: #475569; font-weight: 700; }
.cols { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
ul { margin-top: 8px; }
</style>
</head>
<body>
<h1>Security Group Change Report</h1>
<div class="meta">Instance: $(ConvertTo-HtmlText $sgTabState.CurrentInstanceId) / VPC: $(ConvertTo-HtmlText $sgTabState.CurrentVpcId) / Status: $(ConvertTo-HtmlText $Status) / Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
<div class="panel">
<h2>実効ルール差分（メモ欄は対象外）</h2>
<div class="note">
<strong>留意事項:</strong>
この差分は Security Group のルール内容（方向、Protocol、Port、Source / Destination）を比較したものです。
ルールの Description、Security Group 参照先に内包される SG やその先のルール、NACL、OS ファイアウォール、アプリケーション側の許可設定は考慮しません。
</div>
<table>
<thead><tr><th>差分</th><th>方向</th><th>Protocol</th><th>Port</th><th>Source / Destination</th><th>対象SG</th></tr></thead>
<tbody>
$netRuleRows
</tbody>
</table>
</div>
<div class="panel">
<h2>Security Group 差分</h2>
<table>
<thead><tr><th>差分</th><th>Security Group</th><th>Description</th></tr></thead>
<tbody>
$sgRows
</tbody>
</table>
</div>
<div class="panel">
<h2>差分SGの内容</h2>
$detailBlocks
</div>
<div class="panel">
<h2>元からあるSGの内容</h2>
$existingBlocks
</div>
<div class="panel cols">
<div><h2>適用前</h2><ul>$beforeRows</ul></div>
<div><h2>適用後</h2><ul>$afterRows</ul></div>
</div>
</body>
</html>
"@
    Set-Content -LiteralPath $path -Value $html -Encoding UTF8 -ErrorAction Stop
    $sgTabState.LastReportPath = $path
    return $path
}

function Invoke-SgReportHtmlExport {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrEmpty($sgTabState.CurrentInstanceId)) {
        Set-StatusText -Message 'インスタンス未選択のためHTML出力できません'
        return
    }

    $reportDir = Get-SgReportDirectory
    Set-StatusText -Message 'SG差分HTMLを出力中...'
    $path = New-SgReportHtml -Status 'Preview' -Directory $reportDir
    if ($null -eq $path) { return }

    Write-AppLog -Level 'INFO' -Message "SG差分HTML出力: $path"
    $browser = Open-HtmlFile -Path $path
    Set-StatusText -Message "SG差分HTMLを出力してブラウザで開きました: $path"
    Write-AppLog -Level 'INFO' -Message "SG差分HTMLブラウザ起動: $path ($browser)"
}

function Show-SgDetailWindow {
    [CmdletBinding()]
    param($SecurityGroup)
    if ($null -eq $SecurityGroup) { return }

    $detailXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Security Group Details"
        Width="920" Height="620"
        MinWidth="760" MinHeight="500"
        WindowStartupLocation="CenterOwner"
        Background="#0F172A"
        FontFamily="Yu Gothic UI, Meiryo UI, Segoe UI"
        FontSize="13">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,12">
            <TextBlock x:Name="TitleText" FontSize="19" FontWeight="SemiBold" Foreground="#F8FAFC" />
            <TextBlock x:Name="MetaText" Foreground="#94A3B8" Margin="0,4,0,0" TextWrapping="Wrap" />
        </StackPanel>
        <DockPanel Grid.Row="1" Margin="0,0,0,12">
            <TextBlock DockPanel.Dock="Top" Text="インバウンド" FontWeight="SemiBold" Foreground="#BAE6FD" Margin="0,0,0,8" />
            <DataGrid x:Name="InboundGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="None">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Protocol" Binding="{Binding Protocol}" Width="100" />
                    <DataGridTextColumn Header="Port" Binding="{Binding Port}" Width="90" />
                    <DataGridTextColumn Header="Source" Binding="{Binding Target}" Width="*" />
                    <DataGridTextColumn Header="Description" Binding="{Binding Description}" Width="220" />
                </DataGrid.Columns>
            </DataGrid>
        </DockPanel>
        <DockPanel Grid.Row="2" Margin="0,0,0,12">
            <TextBlock DockPanel.Dock="Top" Text="アウトバウンド" FontWeight="SemiBold" Foreground="#BAE6FD" Margin="0,0,0,8" />
            <DataGrid x:Name="OutboundGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="None">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Protocol" Binding="{Binding Protocol}" Width="100" />
                    <DataGridTextColumn Header="Port" Binding="{Binding Port}" Width="90" />
                    <DataGridTextColumn Header="Destination" Binding="{Binding Target}" Width="*" />
                    <DataGridTextColumn Header="Description" Binding="{Binding Description}" Width="220" />
                </DataGrid.Columns>
            </DataGrid>
        </DockPanel>
        <Button x:Name="CloseButton" Grid.Row="3" Content="閉じる" Width="96" HorizontalAlignment="Right" />
    </Grid>
</Window>
'@
    [xml]$xamlDoc = $detailXaml
    $reader2 = New-Object System.Xml.XmlNodeReader $xamlDoc
    $dialog = [Windows.Markup.XamlReader]::Load($reader2)
    $dialog.Owner = $window
    $dialog.Title = "Security Group Details - $($SecurityGroup.GroupId)"
    $dialog.FindName('TitleText').Text = Get-SgLabel -Item $SecurityGroup
    $dialog.FindName('MetaText').Text = "VPC: $($SecurityGroup.VpcId) / $($SecurityGroup.Description)"
    $dialog.FindName('InboundGrid').ItemsSource = ConvertTo-SgRuleRows -Permissions $SecurityGroup.IpPermissions -Direction 'Inbound'
    $dialog.FindName('OutboundGrid').ItemsSource = ConvertTo-SgRuleRows -Permissions $SecurityGroup.IpPermissionsEgress -Direction 'Outbound'
    $dialog.FindName('CloseButton').Add_Click({ $dialog.Close() })
    $dialog.ShowDialog() | Out-Null
}

function Update-SgApplyButtonState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $id = [string]$sgTabState.CurrentInstanceId
    if ([string]::IsNullOrEmpty($id)) {
        $applySgButton.IsEnabled = $false
        return
    }
    $applySgButton.IsEnabled = (-not (Test-InstanceLocked -InstanceId $id)) -and (-not (Test-AsyncTaskRunning))
}

function Clear-SgTab {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$Message = ''
    )
    $appliedSgList.ItemsSource = $null
    $availableSgList.ItemsSource = $null
    $sgTabState.OriginalSgIds = @()
    $sgTabState.OriginalSgItems = @()
    $sgTabState.CurrentInstanceId = $null
    $sgTabState.CurrentVpcId = $null
    $sgTabState.Loaded = $false
    $sgDiffPanel.Children.Clear()
    if ([string]::IsNullOrEmpty($Message)) { $Message = 'インスタンスを選択してください。' }
    Add-SgDiffText -Text $Message -Color '#94A3B8' | Out-Null
    $sgStatusText.Text = 'Security Groups'
    Update-SgApplyButtonState
}

function Show-SgListsFromData {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$VpcSgs
    )

    $appliedIds = @()
    if ($null -ne (Get-ObjectPropertyValue -Object $Instance -Name 'SecurityGroupIds')) {
        $appliedIds = @($Instance.SecurityGroupIds)
    }

    $applied = New-Object System.Collections.Generic.List[PSCustomObject]
    $available = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($sg in @($VpcSgs)) {
        if ($appliedIds -contains $sg.GroupId) {
            $applied.Add($sg)
        }
        else {
            $available.Add($sg)
        }
    }

    # describe-security-groups の結果に適用中 SG が無い場合でも表示に出す
    foreach ($id in $appliedIds) {
        $hit = $applied | Where-Object { $_.GroupId -eq $id } | Select-Object -First 1
        if ($null -eq $hit) {
            $applied.Add((Get-SgDisplayItem -GroupId $id -GroupName '?' -Description ''))
        }
    }

    $appliedSgList.ItemsSource = $applied.ToArray()
    $availableSgList.ItemsSource = $available.ToArray()

    $appliedSnapshot = @($applied.ToArray())
    $sgTabState.OriginalSgIds = [string[]]($appliedSnapshot | ForEach-Object { [string]$_.GroupId })
    $sgTabState.OriginalSgItems = @($appliedSnapshot)
    $sgTabState.CurrentInstanceId = [string]$Instance.InstanceId
    $sgTabState.CurrentVpcId = [string]$Instance.VpcId
    $sgTabState.Loaded = $true
    Update-SgDiffPreview
    Update-SgApplyButtonState

    $isLocked = Test-InstanceLocked -InstanceId ([string]$Instance.InstanceId)
    if ($isLocked) {
        $sgStatusText.Text = "ロック中のため適用不可 / 適用 $($applied.Count) / 候補 $($available.Count)"
    }
    else {
        $sgStatusText.Text = "適用 $($applied.Count) / 候補 $($available.Count)"
    }
}

function Invoke-SgLoadAsync {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts async load by design.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [switch]$Force
    )

    $instanceId = [string]$Instance.InstanceId
    $vpcId = [string](Get-ObjectPropertyValue -Object $Instance -Name 'VpcId')
    if ([string]::IsNullOrEmpty($vpcId)) {
        Clear-SgTab -Message "$instanceId は VPC 情報がありません。"
        Set-StatusText -Message "$instanceId は VPC 情報がありません"
        return
    }

    if ((-not $Force) -and $script:AppState.SgCache.ContainsKey($instanceId)) {
        Show-SgListsFromData -Instance $Instance -VpcSgs @($script:AppState.SgCache[$instanceId].VpcSgs)
        return
    }

    if (Test-AsyncTaskRunning) {
        $sgStatusText.Text = '他のタスクを実行中のため未取得です。完了後に「再取得」を押してください。'
        return
    }

    $name = Get-SelectedProfile
    if ($null -eq $name) { return }

    $sgStatusText.Text = "SG 情報を取得中… ($vpcId)"
    Set-StatusText -Message "$instanceId の SG 取得中…"
    $appliedSgList.ItemsSource = $null
    $availableSgList.ItemsSource = $null
    $sgDiffPanel.Children.Clear()
    Add-SgDiffText -Text "SG 情報を取得中… ($instanceId)" -Color '#94A3B8' | Out-Null

    $started = Start-AsyncTask -Name "SG 取得: $instanceId" -Work {
        param($Channel, $ReportProgress, $profileName, $targetVpcId)
        [object[]]$vpcSgs = Get-VpcSecurityGroups -Profile $profileName -VpcId $targetVpcId
        if ($null -eq $vpcSgs) { $vpcSgs = @() }
        return , $vpcSgs
    } -ArgumentList @([string]$name, $vpcId) -Context @{ InstanceId = $instanceId } -OnSuccess {
        param($result, $ctx)
        $items = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($sg in @($result)) {
            $items.Add((Get-SgDisplayItem -GroupId $sg.GroupId -GroupName $sg.GroupName -Description $sg.Description -VpcId $sg.VpcId -IpPermissions $sg.IpPermissions -IpPermissionsEgress $sg.IpPermissionsEgress))
        }
        # キャッシュは取得依頼したインスタンスのキーに保存する。
        # 描画は取得中に選択が変わっていない場合のみ行う。
        $fetchedFor = [string]$ctx.InstanceId
        $script:AppState.SgCache[$fetchedFor] = @{ VpcSgs = $items.ToArray() }
        $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
        if ($null -ne $inst -and [string]$inst.InstanceId -eq $fetchedFor) {
            Show-SgListsFromData -Instance $inst -VpcSgs $items.ToArray()
            Set-StatusText -Message "SG 情報を取得しました ($($items.Count) 件)"
        }
    } -OnError {
        param($err, $ctx)
        $sgStatusText.Text = "SG 取得エラー: $err"
        Set-StatusText -Message "SG 取得エラー: $err"
        Write-AppLog -Level 'ERROR' -Message "SG 取得エラー: $err"
    }
    if (-not $started) {
        $sgStatusText.Text = '他のタスクを実行中のため未取得です。完了後に「再取得」を押してください。'
    }
}

function Update-SgTabForSelection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        Clear-SgTab
        return
    }
    if (-not (Test-SgTabActive)) {
        # タブ非表示のときは取得しない(タブ表示時に呼び直される)
        if ([string]$sgTabState.CurrentInstanceId -ne [string]$inst.InstanceId) {
            $sgTabState.Loaded = $false
        }
        return
    }
    if ($sgTabState.Loaded -and [string]$sgTabState.CurrentInstanceId -eq [string]$inst.InstanceId) {
        Update-SgApplyButtonState
        return
    }
    Invoke-SgLoadAsync -Instance $inst
}

function Move-SgItem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$From,
        [Parameter(Mandatory = $true)]$To
    )
    if ($null -eq $From.SelectedItems -or $From.SelectedItems.Count -eq 0) { return }

    $selectedIds = @()
    foreach ($item in @($From.SelectedItems)) {
        $groupId = [string](Get-ObjectPropertyValue -Object $item -Name 'GroupId')
        if (-not [string]::IsNullOrWhiteSpace($groupId)) { $selectedIds += $groupId }
    }
    if ($selectedIds.Count -eq 0) { return }

    $fromList = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($null -ne $From.ItemsSource) {
        foreach ($x in $From.ItemsSource) {
            if ($selectedIds -notcontains [string](Get-ObjectPropertyValue -Object $x -Name 'GroupId')) {
                $fromList.Add($x)
            }
        }
    }
    $toList = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($null -ne $To.ItemsSource) {
        foreach ($x in $To.ItemsSource) { $toList.Add($x) }
    }
    foreach ($x in @($From.ItemsSource)) {
        if ($selectedIds -contains [string](Get-ObjectPropertyValue -Object $x -Name 'GroupId')) {
            $toList.Add($x)
        }
    }

    $From.SelectedIndex = -1
    $To.SelectedIndex = -1
    $From.ItemsSource = $fromList.ToArray()
    $To.ItemsSource = $toList.ToArray()
    Update-SgDiffPreview
}

$reloadSgButton.Add_Click({
        try {
            $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
            if ($null -eq $inst) {
                Set-StatusText -Message 'インスタンス未選択'
                return
            }
            Invoke-SgLoadAsync -Instance $inst -Force
        }
        catch {
            Set-StatusText -Message "SG 再取得エラー: $($_.Exception.Message)"
        }
    })

$moveToAppliedButton.Add_Click({
        try {
            Move-SgItem -From $availableSgList -To $appliedSgList
        }
        catch {
            Set-StatusText -Message "SG 移動エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SG 移動エラー(未適用 -> 適用済み): $($_.Exception.Message)"
        }
    })

$moveToAvailableButton.Add_Click({
        try {
            Move-SgItem -From $appliedSgList -To $availableSgList
        }
        catch {
            Set-StatusText -Message "SG 移動エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SG 移動エラー(適用済み -> 未適用): $($_.Exception.Message)"
        }
    })

$appliedSgList.Add_MouseDoubleClick({
        Show-SgDetailWindow -SecurityGroup $appliedSgList.SelectedItem
    })

$availableSgList.Add_MouseDoubleClick({
        Show-SgDetailWindow -SecurityGroup $availableSgList.SelectedItem
    })

$exportSgReportButton.Add_Click({
        try {
            Invoke-SgReportHtmlExport
        }
        catch {
            Set-StatusText -Message "HTML出力エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SG差分HTML出力エラー: $($_.Exception.Message)"
        }
    })

$applySgButton.Add_Click({
        try {
            $name = Get-SelectedProfile
            if ($null -eq $name) { return }
            if ([string]::IsNullOrEmpty($sgTabState.CurrentInstanceId)) {
                Set-StatusText -Message 'インスタンス未選択'
                return
            }
            $instanceId = [string]$sgTabState.CurrentInstanceId
            if (-not (Test-InstanceOperationAllowed -InstanceId $instanceId -OperationLabel 'SG 適用')) { return }

            $newIds = @()
            if ($null -ne $appliedSgList.ItemsSource) {
                foreach ($x in $appliedSgList.ItemsSource) { $newIds += [string]$x.GroupId }
            }
            $origIds = @()
            if ($null -ne $sgTabState.OriginalSgIds) { $origIds = @($sgTabState.OriginalSgIds) }

            if ($newIds.Count -eq 0) {
                Set-StatusText -Message '適用済み SG が 0 件です。最低 1 件必要です'
                return
            }

            $added = @($newIds | Where-Object { $origIds -notcontains $_ })
            $removed = @($origIds | Where-Object { $newIds -notcontains $_ })

            if ($added.Count -eq 0 -and $removed.Count -eq 0) {
                Set-StatusText -Message '変更はありません'
                return
            }

            $addText = if ($added.Count -eq 0) { '(なし)' } else { ($added -join ', ') }
            $delText = if ($removed.Count -eq 0) { '(なし)' } else { ($removed -join ', ') }
            if (-not (Show-ConfirmDialog -Message "$instanceId に適用しますか？`n追加: $addText`n削除: $delText")) {
                Set-StatusText -Message 'SG 適用をキャンセルしました'
                return
            }

            Set-StatusText -Message "$instanceId に SG 適用中…"
            Write-AppLog -Level 'INFO' -Message "SG 適用開始: $instanceId 追加=$addText 削除=$delText"

            $started = Start-AsyncTask -Name "SG 適用: $instanceId" -Work {
                param($Channel, $ReportProgress, $profileName, $targetId, $groupIds)
                return (Set-InstanceSecurityGroups -Profile $profileName -InstanceId $targetId -GroupIds @($groupIds))
            } -ArgumentList @([string]$name, $instanceId, $newIds) -Context @{ InstanceId = $instanceId } -OnSuccess {
                param($result, $ctx)
                $targetId = [string]$ctx.InstanceId
                if ($result) {
                    $reportPath = $null
                    try {
                        $reportPath = New-SgReportHtml -Status 'Applied' -Directory (Get-SgReportDirectory)
                    }
                    catch {
                        Write-AppLog -Level 'WARN' -Message "SG適用HTML出力エラー: $($_.Exception.Message)"
                    }
                    if ($null -ne $reportPath) {
                        Set-StatusText -Message "$targetId に SG を適用しました。HTML: $reportPath"
                        Write-AppLog -Level 'INFO' -Message "SG適用HTML出力: $reportPath"
                    }
                    else {
                        Set-StatusText -Message "$targetId に SG を適用しました"
                    }
                    Write-AppLog -Level 'INFO' -Message "SG 適用完了: $targetId"
                    # 適用後は対象 1 台だけ再取得して一覧と SG タブへ反映する
                    Clear-InstanceScopedCaches -InstanceId $targetId
                    $sgTabState.Loaded = $false
                    Update-SingleInstanceAsync -InstanceId $targetId -After {
                        Update-SgTabForSelection
                    }
                }
                else {
                    Set-StatusText -Message "SG 適用に失敗しました"
                    Write-AppLog -Level 'ERROR' -Message "SG 適用失敗: $targetId"
                }
            } -OnError {
                param($err, $ctx)
                Set-StatusText -Message "SG 適用エラー: $err"
                Write-AppLog -Level 'ERROR' -Message "SG 適用エラー: $err"
            }
            if (-not $started) {
                Set-StatusText -Message '他のタスクを実行中です。完了後に再度お試しください。'
            }
        }
        catch {
            Set-StatusText -Message "エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SG 適用エラー: $($_.Exception.Message)"
        }
    })

Clear-SgTab
