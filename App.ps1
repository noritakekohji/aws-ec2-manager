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
            $instancesGrid.ItemsSource = $items
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

$window.ShowDialog() | Out-Null
