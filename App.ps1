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

$window.ShowDialog() | Out-Null
