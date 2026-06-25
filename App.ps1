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
$openSsoButton = Find-Control -Name 'OpenSsoButton'
$statusBarText = Find-Control -Name 'StatusBarText'

# Populate profiles
try {
    # Get-AwsProfiles は string[] を返す。@() で包むと WPF から「1 要素 = 配列まるごと」に見えるため使わない
    [string[]]$profiles = Get-AwsProfiles
    if ($null -eq $profiles) { $profiles = @() }
    $profileComboBox.ItemsSource = $profiles
    if ($profiles.Length -gt 0) {
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

$openSsoButton.Add_Click({
        try {
            $awsDir = Join-Path $env:USERPROFILE '.aws'
            $configPath = Join-Path $awsDir 'config'
            if (Test-Path -LiteralPath $configPath) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList @($configPath) | Out-Null
                $statusBarText.Text = "~/.aws/config を notepad で開きました"
            }
            elseif (Test-Path -LiteralPath $awsDir) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList @($awsDir) | Out-Null
                $statusBarText.Text = "~/.aws/ をエクスプローラで開きました（config が見つかりません）"
            }
            else {
                $statusBarText.Text = "~/.aws/ ディレクトリが存在しません"
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
            # @() で包むと unary-comma 返り値が「1 要素 = 配列まるごと」に化けるので使わない
            [object[]]$items = Get-Ec2Instances -Profile $name
            if ($null -eq $items) { $items = @() }
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
        [object[]]$items = Get-Ec2Instances -Profile $name
        if ($null -eq $items) { $items = @() }
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
        [object[]]$vpcSgs = Get-VpcSecurityGroups -Profile $name -VpcId $Instance.VpcId
        if ($null -eq $vpcSgs) { $vpcSgs = @() }

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

#----------------------------------------------------------------------
# Tab3: SSM Run Command
#----------------------------------------------------------------------

$ssmInstanceComboBox = Find-Control -Name 'SsmInstanceComboBox'
$loadSsmButton = Find-Control -Name 'LoadSsmButton'
$rescanYamlButton = Find-Control -Name 'RescanYamlButton'
$yamlListBox = Find-Control -Name 'YamlListBox'
$yamlInfoText = Find-Control -Name 'YamlInfoText'
$runSsmButton = Find-Control -Name 'RunSsmButton'
$ssmProgressBar = Find-Control -Name 'SsmProgressBar'
$ssmOutputText = Find-Control -Name 'SsmOutputText'

$tab3State = [PSCustomObject]@{
    LinuxYamls   = @()
    WindowsYamls = @()
}

function Get-SsmYamlList {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns multiple YAML tasks by design.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Linux', 'Windows')]
        [string]$Platform
    )
    $sub = if ($Platform -eq 'Windows') { 'windows' } else { 'linux' }
    $dir = Join-Path $PSScriptRoot (Join-Path 'ssm-tasks' $sub)
    $list = New-Object System.Collections.Generic.List[PSCustomObject]
    if (-not (Test-Path -LiteralPath $dir)) {
        return , ($list.ToArray())
    }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        try {
            $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
            $task = ConvertFrom-MinimalYaml -Text $text
            $name = if ($task.ContainsKey('name')) { [string]$task['name'] } else { $f.BaseName }
            $desc = if ($task.ContainsKey('description')) { [string]$task['description'] } else { '' }
            $out  = if ($task.ContainsKey('output')) { [string]$task['output'] } else { 'text' }
            $to   = if ($task.ContainsKey('timeout')) { $task['timeout'] } else { 300 }
            $scr  = if ($task.ContainsKey('script')) { [string]$task['script'] } else { '' }
            $list.Add([PSCustomObject]@{
                Path        = $f.FullName
                Name        = $name
                Description = $desc
                Output      = $out
                Platform    = $Platform
                Timeout     = $to
                Script      = $scr
            })
        }
        catch {
            $statusBarText.Text = "YAML 読込エラー: $($f.Name) - $($_.Exception.Message)"
        }
    }
    return , ($list.ToArray())
}

function Update-YamlListsFromDisk {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param()
    [object[]]$lin = Get-SsmYamlList -Platform 'Linux'
    [object[]]$win = Get-SsmYamlList -Platform 'Windows'
    if ($null -eq $lin) { $lin = @() }
    if ($null -eq $win) { $win = @() }
    $tab3State.LinuxYamls = $lin
    $tab3State.WindowsYamls = $win
}

function Update-YamlListBoxForInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param($Instance)
    if ($null -eq $Instance) {
        $yamlListBox.ItemsSource = $null
        return
    }
    $platform = if ($Instance.Platform -eq 'Windows') { 'Windows' } else { 'Linux' }
    $items = if ($platform -eq 'Windows') { $tab3State.WindowsYamls } else { $tab3State.LinuxYamls }
    $yamlListBox.ItemsSource = $items
    $yamlInfoText.Text = ''
}

function Get-SafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return 'task' }
    $invalid = '\\/:\*\?"<>\|'
    return ([regex]::Replace($Name, "[$invalid]", '_'))
}

# Initial scan
try {
    Update-YamlListsFromDisk
}
catch {
    $statusBarText.Text = "YAML スキャンエラー: $($_.Exception.Message)"
}

$loadSsmButton.Add_Click({
        try {
            $name = Get-SelectedProfile
            if ($null -eq $name) { return }
            $statusBarText.Text = 'インスタンス取得中…'
            & $pumpUi
            [object[]]$items = Get-Ec2Instances -Profile $name
            if ($null -eq $items) { $items = @() }
            $display = New-Object System.Collections.Generic.List[PSCustomObject]
            foreach ($it in $items) {
                $label = if ([string]::IsNullOrEmpty($it.Name)) { "$($it.InstanceId) [$($it.Platform)]" } else { "$($it.InstanceId) ($($it.Name)) [$($it.Platform)]" }
                $display.Add([PSCustomObject]@{
                    InstanceId   = $it.InstanceId
                    Name         = $it.Name
                    Platform     = $it.Platform
                    DisplayLabel = $label
                })
            }
            $ssmInstanceComboBox.ItemsSource = $display.ToArray()
            $statusBarText.Text = "インスタンス $($display.Count) 件"
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$ssmInstanceComboBox.Add_SelectionChanged({
        try {
            $sel = $ssmInstanceComboBox.SelectedItem
            if ($null -eq $sel) { return }
            Update-YamlListBoxForInstance -Instance $sel
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$yamlListBox.Add_SelectionChanged({
        try {
            $sel = $yamlListBox.SelectedItem
            if ($null -eq $sel) {
                $yamlInfoText.Text = ''
                return
            }
            $desc = if ([string]::IsNullOrEmpty($sel.Description)) { '(なし)' } else { $sel.Description }
            $yamlInfoText.Text = "name: $($sel.Name)`ndescription: $desc`noutput: $($sel.Output)`ntimeout: $($sel.Timeout)"
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$rescanYamlButton.Add_Click({
        try {
            Update-YamlListsFromDisk
            $sel = $ssmInstanceComboBox.SelectedItem
            if ($null -ne $sel) {
                Update-YamlListBoxForInstance -Instance $sel
            }
            $statusBarText.Text = "YAML 再スキャン完了 (Linux $($tab3State.LinuxYamls.Count) / Windows $($tab3State.WindowsYamls.Count))"
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$runSsmButton.Add_Click({
        try {
            $name = Get-SelectedProfile
            if ($null -eq $name) { return }
            $inst = $ssmInstanceComboBox.SelectedItem
            if ($null -eq $inst) {
                $statusBarText.Text = 'インスタンス未選択'
                return
            }
            $yaml = $yamlListBox.SelectedItem
            if ($null -eq $yaml) {
                $statusBarText.Text = 'YAML 未選択'
                return
            }

            $answer = [System.Windows.MessageBox]::Show(
                "$($inst.InstanceId) で『$($yaml.Name)』を実行しますか？",
                'aws-ec2-manager',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
                $statusBarText.Text = '実行をキャンセルしました'
                return
            }

            $ssmProgressBar.Visibility = [System.Windows.Visibility]::Visible
            $ssmOutputText.Text = '実行中...'
            $statusBarText.Text = "$($yaml.Name) 実行中... (GUI は完了まで応答しません)"
            & $pumpUi

            $result = Invoke-SsmTask -Profile $name -InstanceId $inst.InstanceId -YamlPath $yaml.Path

            $ssmProgressBar.Visibility = [System.Windows.Visibility]::Collapsed

            $outType = if ($null -ne $result.OutputType) { [string]$result.OutputType } else { 'text' }
            if ($outType -eq 'html') {
                $tmpDir = Join-Path $env:TEMP 'aws-ec2-manager'
                if (-not (Test-Path -LiteralPath $tmpDir)) {
                    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
                }
                $safe = Get-SafeFileName -Name $yaml.Name
                $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
                $htmlPath = Join-Path $tmpDir "$safe-$stamp.html"
                Set-Content -LiteralPath $htmlPath -Value $result.Output -Encoding UTF8
                try {
                    Start-Process -FilePath 'msedge.exe' -ArgumentList $htmlPath -ErrorAction Stop
                }
                catch {
                    Start-Process -FilePath $htmlPath
                }
                $ssmOutputText.Text = "HTML 結果を Edge で開きました: $htmlPath"
            }
            else {
                if ($result.Status -eq 'Success') {
                    $ssmOutputText.Text = [string]$result.Output
                }
                else {
                    $err = if ([string]::IsNullOrEmpty([string]$result.Error)) { '' } else { "`n--- STDERR ---`n$($result.Error)" }
                    $ssmOutputText.Text = "$([string]$result.Output)$err"
                }
            }

            $dur = if ($null -ne $result.Duration) { '{0:0.0}' -f $result.Duration.TotalSeconds } else { '?' }
            $statusBarText.Text = "Status: $($result.Status) / Duration: ${dur}s"
        }
        catch {
            $ssmProgressBar.Visibility = [System.Windows.Visibility]::Collapsed
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$window.ShowDialog() | Out-Null
