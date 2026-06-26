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

Import-Module -Force (Join-Path $PSScriptRoot 'AppSettings.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'AwsConfig.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'AwsManager.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'Logger.psm1')

# 設定を読み込み、AWS CLI サブプロセスに継承させる
$appSettings = Get-AppSettings
if (-not [string]::IsNullOrWhiteSpace($appSettings.AwsConfigPath)) {
    $env:AWS_CONFIG_FILE = $appSettings.AwsConfigPath
}
Initialize-AppLogger -LogPath $appSettings.LogPath
Write-AppLog -Level 'INFO' -Message 'aws-ec2-manager 起動'

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
$ssoLoginButton = Find-Control -Name 'SsoLoginButton'
$openSsoButton = Find-Control -Name 'OpenSsoButton'
$settingsButton = Find-Control -Name 'SettingsButton'
$statusBarText = Find-Control -Name 'StatusBarText'

function Update-ProfileComboBox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    try {
        # Get-AwsProfiles は string[] を返す。@() で包むと WPF から「1 要素 = 配列まるごと」に見えるため使わない
        [string[]]$profiles = Get-AwsProfiles
        if ($null -eq $profiles) { $profiles = @() }
        $profileComboBox.ItemsSource = $profiles
        if ($profiles.Length -gt 0) {
            $profileComboBox.SelectedIndex = 0
            $statusBarText.Text = "プロファイル $($profiles.Length) 件"
            Write-AppLog -Level 'INFO' -Message "プロファイル読込: $($profiles.Length) 件"
        }
        else {
            $configPath = Get-EffectiveAwsConfigPath
            $statusBarText.Text = "プロファイルが見つかりません ($configPath を確認)"
        }
    }
    catch {
        $statusBarText.Text = "プロファイル読込エラー: $($_.Exception.Message)"
    }
}

Update-ProfileComboBox

function Show-SettingsDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="aws-ec2-manager 設定"
        Width="640" Height="300"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="AWS CLI config ファイルのパス" FontWeight="Bold" Margin="0,0,0,4" />
        <TextBlock Grid.Row="1" Text="空欄でデフォルト (~/.aws/config or $env:AWS_CONFIG_FILE)" Foreground="Gray" Margin="0,0,0,8" />
        <Grid Grid.Row="2" Margin="0,0,0,16">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBox x:Name="ConfigPathTextBox" Grid.Column="0" VerticalAlignment="Center" Padding="4,4" />
            <Button x:Name="BrowseConfigButton" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0" />
        </Grid>
        <TextBlock Grid.Row="3" Text="ログ出力先ファイルのパス" FontWeight="Bold" Margin="0,0,0,4" />
        <TextBlock Grid.Row="4" Text="空欄でログ無効" Foreground="Gray" Margin="0,0,0,8" />
        <Grid Grid.Row="5">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBox x:Name="LogPathTextBox" Grid.Column="0" VerticalAlignment="Center" Padding="4,4" />
            <Button x:Name="BrowseLogButton" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0" />
        </Grid>
        <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="OkButton" Content="OK" Width="90" Padding="0,4" Margin="0,0,8,0" IsDefault="True" />
            <Button x:Name="CancelButton" Content="キャンセル" Width="90" Padding="0,4" IsCancel="True" />
        </StackPanel>
    </Grid>
</Window>
'@

    [xml]$xamlDoc = $settingsXaml
    $reader2 = New-Object System.Xml.XmlNodeReader $xamlDoc
    $dialog = [Windows.Markup.XamlReader]::Load($reader2)
    $dialog.Owner = $window

    $configPathTextBox = $dialog.FindName('ConfigPathTextBox')
    $browseConfigButton = $dialog.FindName('BrowseConfigButton')
    $logPathTextBox     = $dialog.FindName('LogPathTextBox')
    $browseLogButton    = $dialog.FindName('BrowseLogButton')
    $okButton           = $dialog.FindName('OkButton')
    $cancelButton       = $dialog.FindName('CancelButton')

    $current = Get-AppSettings
    if (-not [string]::IsNullOrWhiteSpace($current.AwsConfigPath)) {
        $configPathTextBox.Text = $current.AwsConfigPath
    }
    if (-not [string]::IsNullOrWhiteSpace($current.LogPath)) {
        $logPathTextBox.Text = $current.LogPath
    }

    $browseConfigButton.Add_Click({
            $ofd = New-Object Microsoft.Win32.OpenFileDialog
            $ofd.Title = 'AWS config ファイルを選択'
            $ofd.Filter = 'All files (*.*)|*.*'
            if (-not [string]::IsNullOrWhiteSpace($configPathTextBox.Text)) {
                $initDir = Split-Path -Parent $configPathTextBox.Text
                if ((-not [string]::IsNullOrWhiteSpace($initDir)) -and (Test-Path -LiteralPath $initDir)) {
                    $ofd.InitialDirectory = $initDir
                }
            }
            if ($ofd.ShowDialog($dialog)) {
                $configPathTextBox.Text = $ofd.FileName
            }
        })

    $browseLogButton.Add_Click({
            $sfd = New-Object Microsoft.Win32.SaveFileDialog
            $sfd.Title = 'ログファイルの保存先を選択'
            $sfd.Filter = 'Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*'
            $sfd.DefaultExt = 'log'
            if (-not [string]::IsNullOrWhiteSpace($logPathTextBox.Text)) {
                $initDir = Split-Path -Parent $logPathTextBox.Text
                if ((-not [string]::IsNullOrWhiteSpace($initDir)) -and (Test-Path -LiteralPath $initDir)) {
                    $sfd.InitialDirectory = $initDir
                }
                $sfd.FileName = Split-Path -Leaf $logPathTextBox.Text
            }
            if ($sfd.ShowDialog($dialog)) {
                $logPathTextBox.Text = $sfd.FileName
            }
        })

    $okButton.Add_Click({
            $dialog.DialogResult = $true
            $dialog.Close()
        })

    $cancelButton.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })

    $result = $dialog.ShowDialog()
    if ($result -eq $true) {
        $newConfigPath = $configPathTextBox.Text
        $newLogPath    = $logPathTextBox.Text
        Save-AppSettings -AwsConfigPath $newConfigPath -LogPath $newLogPath

        if ([string]::IsNullOrWhiteSpace($newConfigPath)) {
            Remove-Item Env:\AWS_CONFIG_FILE -ErrorAction SilentlyContinue
        }
        else {
            $env:AWS_CONFIG_FILE = $newConfigPath
        }

        Initialize-AppLogger -LogPath $newLogPath
        Write-AppLog -Level 'INFO' -Message "設定変更: AwsConfigPath=$newConfigPath LogPath=$newLogPath"

        $statusBarText.Text = '設定を保存しました'
        Update-ProfileComboBox
    }
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
            Write-AppLog -Level 'INFO' -Message "プロファイル選択: $selected"
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
            Write-AppLog -Level 'INFO' -Message "aws sts get-caller-identity --profile $selected (result: $ok)"
            if ($ok) {
                $statusBarText.Text = 'SSO トークン有効'
                Write-AppLog -Level 'INFO' -Message "SSO トークン確認: 有効 ($selected)"
            }
            else {
                $statusBarText.Text = "要 SSO ログイン: aws sso login --profile $selected"
                Write-AppLog -Level 'WARN' -Message "SSO トークン確認: 要ログイン ($selected)"
            }
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
            return
        }
    })

$openSsoButton.Add_Click({
        try {
            $configPath = Get-EffectiveAwsConfigPath
            $configDir = Split-Path -Parent $configPath
            if (Test-Path -LiteralPath $configPath) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList @($configPath) | Out-Null
                $statusBarText.Text = "$configPath を notepad で開きました"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($configDir) -and (Test-Path -LiteralPath $configDir)) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList @($configDir) | Out-Null
                $statusBarText.Text = "$configDir をエクスプローラで開きました（config ファイルが見つかりません）"
            }
            else {
                $statusBarText.Text = "config パスが存在しません: $configPath"
            }
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
            return
        }
    })

$settingsButton.Add_Click({
        try {
            Show-SettingsDialog
        }
        catch {
            $statusBarText.Text = "設定エラー: $($_.Exception.Message)"
        }
    })

$ssoLoginButton.Add_Click({
        try {
            $selected = $profileComboBox.SelectedItem
            if ($null -eq $selected) {
                $statusBarText.Text = 'プロファイル未選択'
                return
            }
            # aws sso login はブラウザを開いてユーザー入力を待つので、別コンソールで起動して GUI をブロックしない
            Start-Process -FilePath 'aws' -ArgumentList @('sso', 'login', '--profile', $selected) | Out-Null
            $statusBarText.Text = "SSO ログインを別ウィンドウで開きました: $selected （ブラウザで承認後「トークン確認」を押してください）"
            Write-AppLog -Level 'INFO' -Message "SSO ログイン開始: $selected"
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
            Write-AppLog -Level 'INFO' -Message "インスタンス取得: $($items.Count) 件 (Profile=$name)"
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
        Write-AppLog -Level 'INFO' -Message "インスタンス操作開始: $ActionLabel $instanceId"
        & $pumpUi
        $ok = & $Action $name $instanceId
        if ($ok) {
            $statusBarText.Text = "$instanceId の $ActionLabel 要求を送信しました（更新ボタンで反映）"
            Write-AppLog -Level 'INFO' -Message "インスタンス操作完了: $ActionLabel $instanceId"
        }
        else {
            $statusBarText.Text = "$instanceId の $ActionLabel に失敗しました"
            Write-AppLog -Level 'ERROR' -Message "インスタンス操作失敗: $ActionLabel $instanceId"
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
            Write-AppLog -Level 'INFO' -Message "SG 適用開始: $instanceId 追加=$addText 削除=$delText"
            & $pumpUi
            $ok = Set-InstanceSecurityGroups -Profile $name -InstanceId $instanceId -GroupIds $newIds
            if ($ok) {
                $statusBarText.Text = "$instanceId に SG を適用しました"
                Write-AppLog -Level 'INFO' -Message "SG 適用完了: $instanceId"
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
                Write-AppLog -Level 'ERROR' -Message "SG 適用失敗: $instanceId"
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
            # YAML は UTF-8 (BOM なし) 想定。PS 5.1 既定の CP932 で読むと日本語が文字化けするので明示
            $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
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
    # if/else 式は単一要素配列を unroll するため、直接代入で配列形状を保つ
    if ($platform -eq 'Windows') {
        $yamlListBox.ItemsSource = $tab3State.WindowsYamls
    }
    else {
        $yamlListBox.ItemsSource = $tab3State.LinuxYamls
    }
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
            Write-AppLog -Level 'INFO' -Message "SSM 実行開始: $($yaml.Name) on $($inst.InstanceId)"
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
            Write-AppLog -Level 'INFO' -Message "SSM 実行完了: $($yaml.Name) on $($inst.InstanceId) Status=$($result.Status) Duration=${dur}s"
        }
        catch {
            $ssmProgressBar.Visibility = [System.Windows.Visibility]::Collapsed
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$window.ShowDialog() | Out-Null
