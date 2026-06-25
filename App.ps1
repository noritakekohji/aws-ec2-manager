<#
.SYNOPSIS
    aws-ec2-manager WPF entry point.
.DESCRIPTION
    Loads MainWindow.xaml, wires profile selection / SSO token check.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

Import-Module -Force (Join-Path $PSScriptRoot 'AwsConfig.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'AwsManager.psm1')

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Find-Control {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return $window.FindName($Name)
}

$profileComboBox = Find-Control -Name 'ProfileComboBox'
$profileInfoText = Find-Control -Name 'ProfileInfoText'
$checkTokenButton = Find-Control -Name 'CheckTokenButton'
$statusBarText = Find-Control -Name 'StatusBarText'

# Populate profiles
try {
    $profiles = @(Get-AwsProfiles)
    $profileComboBox.ItemsSource = $profiles
    if ($profiles.Count -gt 0) {
        $profileComboBox.SelectedIndex = 0
    }
    else {
        $statusBarText.Text = 'プロファイルが見つかりません (~/.aws/config を確認)'
    }
}
catch {
    $statusBarText.Text = "プロファイル読込エラー: $($_.Exception.Message)"
}

$profileComboBox.Add_SelectionChanged({
        try {
            $selected = $profileComboBox.SelectedItem
            if ($null -eq $selected) {
                $profileInfoText.Text = ''
                $statusBarText.Text = 'Ready'
                return
            }
            $detail = Get-AwsProfileDetail -Name $selected
            if ($null -eq $detail) {
                $profileInfoText.Text = '(プロファイル詳細を取得できません)'
            }
            else {
                $fmt = { param($v) if ($null -eq $v -or $v -eq '') { '(なし)' } else { $v } }
                $profileInfoText.Text = "SSO URL=$(& $fmt $detail.SsoStartUrl) | Region=$(& $fmt $detail.Region) | Account=$(& $fmt $detail.SsoAccountId)"
            }
            $statusBarText.Text = "Profile: $selected"
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
            return
        }
    })

$checkTokenButton.Add_Click({
        try {
            $selected = $profileComboBox.SelectedItem
            if ($null -eq $selected) {
                $statusBarText.Text = 'プロファイル未選択'
                return
            }
            $ok = Test-SsoToken -Name $selected
            if ($ok) {
                $statusBarText.Text = 'SSO トークン有効'
            }
            else {
                $statusBarText.Text = "要 SSO ログイン: aws sso login --profile $selected"
            }
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
            return
        }
    })

$refreshInstancesButton = Find-Control -Name 'RefreshInstancesButton'
$startInstanceButton = Find-Control -Name 'StartInstanceButton'
$stopInstanceButton = Find-Control -Name 'StopInstanceButton'
$restartInstanceButton = Find-Control -Name 'RestartInstanceButton'
$instancesGrid = Find-Control -Name 'InstancesGrid'

$pumpUi = {
    $window.Dispatcher.Invoke(
        [Action] {},
        [System.Windows.Threading.DispatcherPriority]::Background
    )
}

function Get-SelectedProfile {
    $sel = $profileComboBox.SelectedItem
    if ($null -eq $sel) {
        $statusBarText.Text = 'プロファイル未選択'
        return $null
    }
    return [string]$sel
}

function Get-SelectedInstance {
    $row = $instancesGrid.SelectedItem
    if ($null -eq $row) {
        $statusBarText.Text = 'インスタンスを選択してください'
        return $null
    }
    return $row
}

$refreshInstancesButton.Add_Click({
        try {
            $name = Get-SelectedProfile
            if ($null -eq $name) { return }
            $statusBarText.Text = '取得中…'
            & $pumpUi
            $items = @(Get-Ec2Instances -Profile $name)
            $prevId = $null
            if ($null -ne $instancesGrid.SelectedItem) {
                $prevId = $instancesGrid.SelectedItem.InstanceId
            }
            $instancesGrid.ItemsSource = $items
            if ($null -ne $prevId) {
                $match = $items | Where-Object { $_.InstanceId -eq $prevId } | Select-Object -First 1
                if ($null -ne $match) { $instancesGrid.SelectedItem = $match }
            }
            $statusBarText.Text = "$($items.Count) 件"
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
            return
        }
    })

function Invoke-InstanceAction {
    param(
        [Parameter(Mandatory = $true)][string]$ActionLabel,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }
        $row = Get-SelectedInstance
        if ($null -eq $row) { return }
        $instanceId = [string]$row.InstanceId
        $answer = [System.Windows.MessageBox]::Show(
            "$instanceId を $ActionLabel しますか？",
            'aws-ec2-manager',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            $statusBarText.Text = "$ActionLabel をキャンセルしました"
            return
        }
        $statusBarText.Text = "$instanceId を $ActionLabel 中…"
        & $pumpUi
        $ok = & $Action $name $instanceId
        if ($ok) {
            $statusBarText.Text = "$instanceId の $ActionLabel 要求を送信しました（更新ボタンで反映）"
        }
        else {
            $statusBarText.Text = "$instanceId の $ActionLabel に失敗しました"
        }
    }
    catch {
        $statusBarText.Text = "エラー: $($_.Exception.Message)"
        return
    }
}

$startInstanceButton.Add_Click({
        Invoke-InstanceAction -ActionLabel '起動' -Action {
            param($n, $id) Start-Ec2Instance -Profile $n -InstanceId $id
        }
    })

$stopInstanceButton.Add_Click({
        Invoke-InstanceAction -ActionLabel '停止' -Action {
            param($n, $id) Stop-Ec2Instance -Profile $n -InstanceId $id
        }
    })

$restartInstanceButton.Add_Click({
        Invoke-InstanceAction -ActionLabel '再起動' -Action {
            param($n, $id) Restart-Ec2Instance -Profile $n -InstanceId $id
        }
    })

#----------------------------------------------------------------------
# Tab2: Security Groups
#----------------------------------------------------------------------

$sgInstanceComboBox = Find-Control -Name 'SgInstanceComboBox'
$loadSgButton = Find-Control -Name 'LoadSgButton'
$applySgButton = Find-Control -Name 'ApplySgButton'
$appliedSgList = Find-Control -Name 'AppliedSgList'
$availableSgList = Find-Control -Name 'AvailableSgList'
$moveToAppliedButton = Find-Control -Name 'MoveToAppliedButton'
$moveToAvailableButton = Find-Control -Name 'MoveToAvailableButton'

# Module-scope state for Tab2 (avoid $script: under StrictMode pitfalls).
$tab2State = [PSCustomObject]@{
    OriginalSgIds = @()
    CurrentInstanceId = $null
    CurrentVpcId = $null
}

function Get-SgDisplayItem {
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [string]$GroupName,
        [string]$Description
    )
    $name = if ([string]::IsNullOrEmpty($GroupName)) { '' } else { $GroupName }
    [PSCustomObject]@{
        GroupId      = $GroupId
        GroupName    = $name
        Description  = $Description
        DisplayLabel = "$GroupId ($name)"
    }
}

function Update-SgInstanceComboBox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param()
    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }
        $statusBarText.Text = 'インスタンス取得中…'
        & $pumpUi
        $items = @(Get-Ec2Instances -Profile $name)
        $display = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($it in $items) {
            $label = if ([string]::IsNullOrEmpty($it.Name)) { $it.InstanceId } else { "$($it.InstanceId) ($($it.Name))" }
            $display.Add([PSCustomObject]@{
                InstanceId       = $it.InstanceId
                Name             = $it.Name
                VpcId            = $it.VpcId
                SecurityGroupIds = $it.SecurityGroupIds
                DisplayLabel     = $label
            })
        }
        $sgInstanceComboBox.ItemsSource = $display.ToArray()
        $statusBarText.Text = "インスタンス $($display.Count) 件"
    }
    catch {
        $statusBarText.Text = "エラー: $($_.Exception.Message)"
    }
}

function Update-SgListsForInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param($Instance)
    if ($null -eq $Instance) {
        $appliedSgList.ItemsSource = $null
        $availableSgList.ItemsSource = $null
        return
    }
    if ([string]::IsNullOrEmpty($Instance.VpcId)) {
        $statusBarText.Text = "$($Instance.InstanceId) は VPC 情報がありません"
        $appliedSgList.ItemsSource = $null
        $availableSgList.ItemsSource = $null
        return
    }
    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }
        $statusBarText.Text = "$($Instance.InstanceId) の SG 取得中…"
        & $pumpUi
        $vpcSgs = @(Get-VpcSecurityGroups -Profile $name -VpcId $Instance.VpcId)

        $appliedIds = @()
        if ($null -ne $Instance.SecurityGroupIds) { $appliedIds = @($Instance.SecurityGroupIds) }

        $applied = New-Object System.Collections.Generic.List[PSCustomObject]
        $available = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($sg in $vpcSgs) {
            $item = Get-SgDisplayItem -GroupId $sg.GroupId -GroupName $sg.GroupName -Description $sg.Description
            if ($appliedIds -contains $sg.GroupId) {
                $applied.Add($item)
            }
            else {
                $available.Add($item)
            }
        }

        # If applied SG was somehow not in describe-security-groups result, still surface it.
        foreach ($id in $appliedIds) {
            $hit = $applied | Where-Object { $_.GroupId -eq $id } | Select-Object -First 1
            if ($null -eq $hit) {
                $applied.Add((Get-SgDisplayItem -GroupId $id -GroupName '?' -Description ''))
            }
        }

        $appliedSgList.ItemsSource = $applied.ToArray()
        $availableSgList.ItemsSource = $available.ToArray()

        $tab2State.OriginalSgIds = [string[]]$appliedIds
        $tab2State.CurrentInstanceId = $Instance.InstanceId
        $tab2State.CurrentVpcId = $Instance.VpcId

        $statusBarText.Text = "$($Instance.InstanceId): 適用 $($applied.Count) / 候補 $($available.Count)"
    }
    catch {
        $statusBarText.Text = "エラー: $($_.Exception.Message)"
    }
}

function Move-SgItem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$From,
        [Parameter(Mandatory = $true)]$To
    )
    if ($null -eq $From.SelectedItems -or $From.SelectedItems.Count -eq 0) { return }
    $selected = @($From.SelectedItems)
    $fromList = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($null -ne $From.ItemsSource) {
        foreach ($x in $From.ItemsSource) { $fromList.Add($x) }
    }
    $toList = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($null -ne $To.ItemsSource) {
        foreach ($x in $To.ItemsSource) { $toList.Add($x) }
    }
    foreach ($s in $selected) {
        $null = $fromList.Remove($s)
        $toList.Add($s)
    }
    $From.ItemsSource = $fromList.ToArray()
    $To.ItemsSource = $toList.ToArray()
}

$loadSgButton.Add_Click({
        Update-SgInstanceComboBox
    })

$sgInstanceComboBox.Add_SelectionChanged({
        try {
            $sel = $sgInstanceComboBox.SelectedItem
            if ($null -eq $sel) { return }
            Update-SgListsForInstance -Instance $sel
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$moveToAppliedButton.Add_Click({
        Move-SgItem -From $availableSgList -To $appliedSgList
    })

$moveToAvailableButton.Add_Click({
        Move-SgItem -From $appliedSgList -To $availableSgList
    })

$applySgButton.Add_Click({
        try {
            $name = Get-SelectedProfile
            if ($null -eq $name) { return }
            if ([string]::IsNullOrEmpty($tab2State.CurrentInstanceId)) {
                $statusBarText.Text = 'インスタンス未選択'
                return
            }
            $instanceId = $tab2State.CurrentInstanceId

            $newIds = @()
            if ($null -ne $appliedSgList.ItemsSource) {
                foreach ($x in $appliedSgList.ItemsSource) { $newIds += [string]$x.GroupId }
            }
            $origIds = @()
            if ($null -ne $tab2State.OriginalSgIds) { $origIds = @($tab2State.OriginalSgIds) }

            if ($newIds.Count -eq 0) {
                $statusBarText.Text = '適用済み SG が 0 件です。最低 1 件必要です'
                return
            }

            $added = @($newIds | Where-Object { $origIds -notcontains $_ })
            $removed = @($origIds | Where-Object { $newIds -notcontains $_ })

            if ($added.Count -eq 0 -and $removed.Count -eq 0) {
                $statusBarText.Text = '変更はありません'
                return
            }

            $addText = if ($added.Count -eq 0) { '(なし)' } else { ($added -join ', ') }
            $delText = if ($removed.Count -eq 0) { '(なし)' } else { ($removed -join ', ') }
            $msg = "$instanceId に適用しますか？`n追加: $addText`n削除: $delText"
            $answer = [System.Windows.MessageBox]::Show(
                $msg,
                'aws-ec2-manager',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
                $statusBarText.Text = 'SG 適用をキャンセルしました'
                return
            }

            $statusBarText.Text = "$instanceId に SG 適用中…"
            & $pumpUi
            $ok = Set-InstanceSecurityGroups -Profile $name -InstanceId $instanceId -GroupIds $newIds
            if ($ok) {
                $statusBarText.Text = "$instanceId に SG を適用しました"
                # Reload the current instance state by re-fetching describe-instances.
                Update-SgInstanceComboBox
                $match = $null
                if ($null -ne $sgInstanceComboBox.ItemsSource) {
                    $match = $sgInstanceComboBox.ItemsSource | Where-Object { $_.InstanceId -eq $instanceId } | Select-Object -First 1
                }
                if ($null -ne $match) {
                    $sgInstanceComboBox.SelectedItem = $match
                }
            }
            else {
                $statusBarText.Text = "$instanceId への SG 適用に失敗しました"
            }
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$window.ShowDialog() | Out-Null
