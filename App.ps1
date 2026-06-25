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
$profiles = @(Get-AwsProfiles)
$profileComboBox.ItemsSource = $profiles
if ($profiles.Count -gt 0) {
    $profileComboBox.SelectedIndex = 0
}

$profileComboBox.Add_SelectionChanged({
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
            $profileInfoText.Text = ("SSO URL={0} | Region={1} | Account={2}" -f $detail.SsoStartUrl, $detail.Region, $detail.SsoAccountId)
        }
        $statusBarText.Text = "Profile: $selected"
    })

$checkTokenButton.Add_Click({
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
    })

$window.ShowDialog() | Out-Null
