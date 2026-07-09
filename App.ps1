<#
.SYNOPSIS
    aws-ec2-manager WPF entry point.
.DESCRIPTION
    Loads MainWindow.xaml, wires profile selection / SSO token check.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

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
$logButton = Find-Control -Name 'LogButton'
$settingsButton = Find-Control -Name 'SettingsButton'
$statusBarText = Find-Control -Name 'StatusBarText'

$window.Dispatcher.add_UnhandledException({
        param($sender, $eventArgs)
        $message = [string]$eventArgs.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$eventArgs.Exception }
        if ([string]::IsNullOrWhiteSpace($message)) { $message = '詳細のない UI エラーが発生しました。' }
        $statusBarText.Text = "UI エラー: $message"
        Write-AppLog -Level 'ERROR' -Message "未処理 UI エラー: $message"
        $eventArgs.Handled = $true
    })

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
        <TextBlock Grid.Row="3" Text="ログ出力先フォルダ" FontWeight="Bold" Margin="0,0,0,4" />
        <TextBlock Grid.Row="4" Text="指定フォルダ配下に yyyy-MM-dd フォルダを作成して app.log / HTML レポートを出力" Foreground="Gray" Margin="0,0,0,8" />
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
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fbd.Description = 'ログ出力先フォルダを選択'
            $fbd.ShowNewFolderButton = $true
            if (-not [string]::IsNullOrWhiteSpace($logPathTextBox.Text)) {
                if (Test-Path -LiteralPath $logPathTextBox.Text) {
                    $fbd.SelectedPath = $logPathTextBox.Text
                }
            }
            if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $logPathTextBox.Text = $fbd.SelectedPath
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

$logButton.Add_Click({
        try {
            $logDir = Get-AppLogDirectory
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            Start-Process explorer.exe -ArgumentList $logDir | Out-Null
            $statusBarText.Text = "ログフォルダを開きました: $logDir"
            Write-AppLog -Level 'INFO' -Message "ログフォルダを開く: $logDir"
        }
        catch {
            $statusBarText.Text = "ログフォルダを開けません: $($_.Exception.Message)"
        }
    })

$profileComboBox.Add_SelectionChanged({
        try {
            $selected = $profileComboBox.SelectedItem
            if ($null -eq $selected) {
                $profileInfoText.Text = ''
                $statusBarText.Text = 'Ready'
                if ($null -ne (Get-Variable -Name instanceScanState -ErrorAction SilentlyContinue)) {
                    $instanceScanState.Profile = $null
                    $instanceScanState.Items = @()
                    $instanceScanState.SelectedInstanceId = $null
                    $instanceScanState.LastUpdated = $null
                    $instanceScanState.HasLoaded = $false
                    Update-DependentInstanceCombos -Items @() -PreferredInstanceId $null
                }
                return
            }
            if ($null -ne (Get-Variable -Name instanceScanState -ErrorAction SilentlyContinue) -and $instanceScanState.Profile -ne [string]$selected) {
                $instanceScanState.Profile = $null
                $instanceScanState.Items = @()
                $instanceScanState.SelectedInstanceId = $null
                $instanceScanState.LastUpdated = $null
                $instanceScanState.HasLoaded = $false
                Update-DependentInstanceCombos -Items @() -PreferredInstanceId $null
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
$lockInstanceButton = Find-Control -Name 'LockInstanceButton'
$unlockInstanceButton = Find-Control -Name 'UnlockInstanceButton'
$instancesGrid = Find-Control -Name 'InstancesGrid'

$pumpUi = {
    $window.Dispatcher.Invoke(
        [Action] {},
        [System.Windows.Threading.DispatcherPriority]::Background
    )
}

$instanceScanState = [PSCustomObject]@{
    Profile            = $null
    Items              = @()
    SelectedInstanceId = $null
    LastUpdated        = $null
    HasLoaded          = $false
}

$comboRefreshState = [PSCustomObject]@{
    SuppressSgSelection   = $false
    SuppressRoleSelection = $false
}

$lockState = [PSCustomObject]@{
    LockedInstanceIds = @()
}
if ($null -ne $appSettings.LockedInstanceIds) {
    $lockState.LockedInstanceIds = @($appSettings.LockedInstanceIds)
}

function Test-InstanceLocked {
    param([string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $false }
    return (@($lockState.LockedInstanceIds) -contains $InstanceId)
}

function Save-InstanceLockState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven local settings persistence.')]
    [CmdletBinding()]
    param()
    $current = Get-AppSettings
    Save-AppSettings -AwsConfigPath $current.AwsConfigPath -LogPath $current.LogPath -LockedInstanceIds $lockState.LockedInstanceIds
}

function Add-InstanceLockMetadata {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Adds UI-only properties to display rows.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [string]$DisplayLabel
    )
    $id = [string]$Instance.InstanceId
    $locked = Test-InstanceLocked -InstanceId $id
    $stateText = if ($locked) { 'ロック' } else { '' }
    $Instance | Add-Member -NotePropertyName IsLocked -NotePropertyValue $locked -Force
    $Instance | Add-Member -NotePropertyName LockState -NotePropertyValue $stateText -Force
    if ($PSBoundParameters.ContainsKey('DisplayLabel')) {
        $label = if ($locked) { "[ロック] $DisplayLabel" } else { $DisplayLabel }
        $Instance | Add-Member -NotePropertyName DisplayLabel -NotePropertyValue $label -Force
    }
    return $Instance
}

function Update-InstanceLockButtons {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $row = $instancesGrid.SelectedItem
    if ($null -eq $row) {
        $lockInstanceButton.IsEnabled = $false
        $unlockInstanceButton.IsEnabled = $false
        return
    }
    $locked = Test-InstanceLocked -InstanceId ([string]$row.InstanceId)
    $lockInstanceButton.IsEnabled = -not $locked
    $unlockInstanceButton.IsEnabled = $locked
}

function Test-InstanceOperationAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$OperationLabel
    )
    if (Test-InstanceLocked -InstanceId $InstanceId) {
        $statusBarText.Text = "$InstanceId はロック中のため $OperationLabel できません"
        [System.Windows.MessageBox]::Show(
            "$InstanceId はロックされています。`n$OperationLabel は実行できません。`n必要な場合は先に「ロック解除」を行ってください。",
            'aws-ec2-manager',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        Write-AppLog -Level 'WARN' -Message "ロック中のため操作ブロック: $OperationLabel $InstanceId"
        return $false
    }
    return $true
}

function Update-LockDependentControls {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    Update-InstanceLockButtons

    $sgSel = $sgInstanceComboBox.SelectedItem
    if ($null -ne $sgSel) {
        Add-InstanceLockMetadata -Instance $sgSel -DisplayLabel ([string]$sgSel.DisplayLabel).Replace('[ロック] ', '') | Out-Null
        $applySgButton.IsEnabled = -not (Test-InstanceLocked -InstanceId ([string]$sgSel.InstanceId))
        $sgInstanceComboBox.Items.Refresh()
    }

    $roleSel = $roleInstanceComboBox.SelectedItem
    if ($null -ne $roleSel) {
        Add-InstanceLockMetadata -Instance $roleSel -DisplayLabel ([string]$roleSel.DisplayLabel).Replace('[ロック] ', '') | Out-Null
        Update-RoleActionButtons
        $roleInstanceComboBox.Items.Refresh()
    }

    $ssmSel = $ssmInstanceComboBox.SelectedItem
    if ($null -ne $ssmSel) {
        Add-InstanceLockMetadata -Instance $ssmSel -DisplayLabel ([string]$ssmSel.DisplayLabel).Replace('[ロック] ', '') | Out-Null
        $runSsmButton.IsEnabled = -not (Test-InstanceLocked -InstanceId ([string]$ssmSel.InstanceId))
        $ssmInstanceComboBox.Items.Refresh()
    }
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

function Get-SharedInstanceItems {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [string]$Profile
    )
    if ([string]::IsNullOrWhiteSpace($Profile)) { return @() }
    if ($instanceScanState.Profile -ne $Profile) { return @() }
    if ($null -eq $instanceScanState.Items) { return @() }
    return ConvertTo-InstanceItemArray -Items $instanceScanState.Items
}

function ConvertTo-InstanceItemArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [object[]]$Items
    )

    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Items) { return @() }
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Array]) {
            foreach ($nested in @($item)) {
                if ($null -ne $nested) {
                    $list.Add($nested)
                }
            }
        }
        else {
            $list.Add($item)
        }
    }
    return $list.ToArray()
}

function Update-DependentInstanceCombos {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI refresh helper.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Items,
        [AllowNull()]
        [string]$PreferredInstanceId
    )

    [object[]]$Items = @(ConvertTo-InstanceItemArray -Items $Items)
    if ($null -ne (Get-Command -Name Update-SgInstanceComboBoxFromItems -ErrorAction SilentlyContinue) -and
        $null -ne (Get-Variable -Name sgInstanceComboBox -ErrorAction SilentlyContinue) -and
        $null -ne $sgInstanceComboBox) {
        try {
            Update-SgInstanceComboBoxFromItems -Items $Items -PreferredInstanceId $PreferredInstanceId | Out-Null
        }
        catch {
            Write-AppLog -Level 'WARN' -Message "SG インスタンス反映エラー: $($_.Exception.Message)"
        }
    }
    if ($null -ne (Get-Command -Name Update-SsmInstanceComboBoxFromItems -ErrorAction SilentlyContinue) -and
        $null -ne (Get-Variable -Name ssmInstanceComboBox -ErrorAction SilentlyContinue) -and
        $null -ne $ssmInstanceComboBox) {
        try {
            Update-SsmInstanceComboBoxFromItems -Items $Items -PreferredInstanceId $PreferredInstanceId | Out-Null
        }
        catch {
            Write-AppLog -Level 'WARN' -Message "SSM インスタンス反映エラー: $($_.Exception.Message)"
        }
    }
    if ($null -ne (Get-Command -Name Update-RoleInstanceComboBoxFromItems -ErrorAction SilentlyContinue) -and
        $null -ne (Get-Variable -Name roleInstanceComboBox -ErrorAction SilentlyContinue) -and
        $null -ne $roleInstanceComboBox) {
        try {
            Update-RoleInstanceComboBoxFromItems -Items $Items -PreferredInstanceId $PreferredInstanceId | Out-Null
        }
        catch {
            Write-AppLog -Level 'WARN' -Message "インスタンスロール反映エラー: $($_.Exception.Message)"
        }
    }
}

function ConvertTo-DetailText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) { return '' }
        return (@($Value) -join ', ')
    }
    return [string]$Value
}

function New-DetailRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    return [PSCustomObject]@{
        Name  = $Name
        Value = ConvertTo-DetailText -Value $Value
    }
}

function Show-InstanceDetailWindow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param($Instance)

    if ($null -eq $Instance) { return }

    $detailXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Instance Details"
        Width="760" Height="620"
        MinWidth="640" MinHeight="480"
        WindowStartupLocation="CenterOwner"
        Background="#0F172A"
        FontFamily="Yu Gothic UI, Meiryo UI, Segoe UI"
        FontSize="13">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <TextBlock x:Name="TitleText" Grid.Row="0" FontSize="18" FontWeight="SemiBold" Foreground="#E5E7EB" Margin="0,0,0,4" />
        <TextBlock x:Name="MetaText" Grid.Row="1" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12" />
        <DataGrid x:Name="DetailGrid" Grid.Row="2"
                  AutoGenerateColumns="False"
                  IsReadOnly="True"
                  CanUserAddRows="False"
                  CanUserDeleteRows="False"
                  HeadersVisibility="Column"
                  GridLinesVisibility="None"
                  RowHeaderWidth="0"
                  Background="#0B1220"
                  Foreground="#E5E7EB"
                  BorderBrush="#263247"
                  AlternatingRowBackground="#111A2C"
                  RowBackground="#0B1220">
            <DataGrid.Resources>
                <Style TargetType="DataGridColumnHeader">
                    <Setter Property="Background" Value="#1E293B" />
                    <Setter Property="Foreground" Value="#BAE6FD" />
                    <Setter Property="Padding" Value="10,8" />
                    <Setter Property="FontWeight" Value="SemiBold" />
                </Style>
                <Style TargetType="DataGridCell">
                    <Setter Property="BorderThickness" Value="0" />
                    <Setter Property="Padding" Value="10,6" />
                    <Setter Property="Foreground" Value="#E5E7EB" />
                    <Setter Property="Background" Value="Transparent" />
                </Style>
            </DataGrid.Resources>
            <DataGrid.Columns>
                <DataGridTextColumn Header="項目" Binding="{Binding Name}" Width="190" />
                <DataGridTextColumn Header="値" Binding="{Binding Value}" Width="*" />
            </DataGrid.Columns>
        </DataGrid>
        <DockPanel Grid.Row="3" Margin="0,12,0,0">
            <TextBlock x:Name="HintText" DockPanel.Dock="Left" Text="行をダブルクリックすると値をコピーします" Foreground="#94A3B8" VerticalAlignment="Center" />
            <Button x:Name="CloseButton" DockPanel.Dock="Right" Content="閉じる" Width="96" Padding="0,5" HorizontalAlignment="Right" />
        </DockPanel>
    </Grid>
</Window>
'@

    [xml]$xamlDoc = $detailXaml
    $reader2 = New-Object System.Xml.XmlNodeReader $xamlDoc
    $dialog = [Windows.Markup.XamlReader]::Load($reader2)
    $dialog.Owner = $window

    $displayName = if ([string]::IsNullOrWhiteSpace([string]$Instance.Name)) { [string]$Instance.InstanceId } else { [string]$Instance.Name }
    $dialog.Title = "Instance Details - $($Instance.InstanceId)"
    $dialog.FindName('TitleText').Text = $displayName
    $dialog.FindName('MetaText').Text = "InstanceId: $($Instance.InstanceId) / State: $($Instance.State) / SSM: $($Instance.SsmStatus)"

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    $rows.Add((New-DetailRow -Name 'Name' -Value $Instance.Name))
    $rows.Add((New-DetailRow -Name 'InstanceId' -Value $Instance.InstanceId))
    $rows.Add((New-DetailRow -Name 'State' -Value $Instance.State))
    $rows.Add((New-DetailRow -Name 'InstanceType' -Value $Instance.InstanceType))
    $rows.Add((New-DetailRow -Name 'Platform' -Value $Instance.Platform))
    $rows.Add((New-DetailRow -Name 'AvailabilityZone' -Value $Instance.AvailabilityZone))
    $rows.Add((New-DetailRow -Name 'PrivateIpAddress' -Value $Instance.PrivateIpAddress))
    $rows.Add((New-DetailRow -Name 'PublicIpAddress' -Value $Instance.PublicIpAddress))
    $rows.Add((New-DetailRow -Name 'VpcId' -Value $Instance.VpcId))
    $rows.Add((New-DetailRow -Name 'SubnetId' -Value $Instance.SubnetId))
    $rows.Add((New-DetailRow -Name 'ImageId' -Value $Instance.ImageId))
    $rows.Add((New-DetailRow -Name 'KeyName' -Value $Instance.KeyName))
    $rows.Add((New-DetailRow -Name 'LaunchTime' -Value $Instance.LaunchTime))
    $rows.Add((New-DetailRow -Name 'RootDeviceName' -Value $Instance.RootDeviceName))
    $rows.Add((New-DetailRow -Name 'IamInstanceProfile' -Value $Instance.IamInstanceProfile))
    $rows.Add((New-DetailRow -Name 'IamInstanceProfileArn' -Value $Instance.IamInstanceProfileArn))
    $rows.Add((New-DetailRow -Name 'SecurityGroupIds' -Value $Instance.SecurityGroupIds))
    $rows.Add((New-DetailRow -Name 'SecurityGroupNames' -Value $Instance.SecurityGroupNames))
    $rows.Add((New-DetailRow -Name 'SsmStatus' -Value $Instance.SsmStatus))
    $rows.Add((New-DetailRow -Name 'SsmAgentVersion' -Value $Instance.SsmAgentVersion))
    $rows.Add((New-DetailRow -Name 'SsmPlatformName' -Value $Instance.SsmPlatformName))
    $rows.Add((New-DetailRow -Name 'SsmPlatformVersion' -Value $Instance.SsmPlatformVersion))
    $rows.Add((New-DetailRow -Name 'SsmLastPingDateTime' -Value $Instance.SsmLastPingDateTime))
    $rows.Add((New-DetailRow -Name 'LockState' -Value $Instance.LockState))

    $detailGrid = $dialog.FindName('DetailGrid')
    $detailGrid.ItemsSource = $rows.ToArray()
    $hintText = $dialog.FindName('HintText')
    $detailGrid.Add_MouseDoubleClick({
            $selectedRow = $detailGrid.SelectedItem
            if ($null -ne $selectedRow) {
                [System.Windows.Clipboard]::SetText([string]$selectedRow.Value)
                $hintText.Text = "$($selectedRow.Name) をコピーしました"
            }
        })
    $dialog.FindName('CloseButton').Add_Click({ $dialog.Close() })
    $dialog.ShowDialog() | Out-Null
}

$instancesGrid.Add_SelectionChanged({
        $row = $instancesGrid.SelectedItem
        if ($null -ne $row) {
            $instanceScanState.SelectedInstanceId = [string]$row.InstanceId
            Update-DependentInstanceCombos -Items (Get-SharedInstanceItems -Profile $instanceScanState.Profile) -PreferredInstanceId $instanceScanState.SelectedInstanceId
        }
        Update-InstanceLockButtons
    })
$instancesGrid.Add_MouseDoubleClick({
        try {
            $row = $instancesGrid.SelectedItem
            if ($null -ne $row) {
                Show-InstanceDetailWindow -Instance $row
            }
        }
        catch {
            $statusBarText.Text = "詳細表示エラー: $($_.Exception.Message)"
        }
    })
Update-InstanceLockButtons

function Update-InstancesGridFromItems {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Items
    )
    [object[]]$Items = @(ConvertTo-InstanceItemArray -Items $Items)
    foreach ($it in $Items) {
        Add-InstanceLockMetadata -Instance $it | Out-Null
    }
    $prevId = $null
    if ($null -ne $instancesGrid.SelectedItem) {
        $prevId = [string]$instancesGrid.SelectedItem.InstanceId
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$instanceScanState.SelectedInstanceId)) {
        $prevId = [string]$instanceScanState.SelectedInstanceId
    }
    $instancesGrid.ItemsSource = $Items
    if ($null -ne $prevId) {
        $match = $Items | Where-Object { $_.InstanceId -eq $prevId } | Select-Object -First 1
        if ($null -ne $match) { $instancesGrid.SelectedItem = $match }
    }
    if ($null -ne $instancesGrid.SelectedItem) {
        $instanceScanState.SelectedInstanceId = [string]$instancesGrid.SelectedItem.InstanceId
    }
    elseif ($Items.Count -eq 0) {
        $instanceScanState.SelectedInstanceId = $null
    }
    $instanceScanState.Items = @($Items)
    Update-DependentInstanceCombos -Items $Items -PreferredInstanceId $instanceScanState.SelectedInstanceId
    Update-InstanceLockButtons
}

function Update-CachedInstanceSecurityGroups {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates local UI cache after a confirmed AWS change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string[]]$GroupIds
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($it in @(ConvertTo-InstanceItemArray -Items $instanceScanState.Items)) {
        if ([string]$it.InstanceId -eq $InstanceId) {
            $it | Add-Member -NotePropertyName SecurityGroupIds -NotePropertyValue @($GroupIds) -Force
            $it | Add-Member -NotePropertyName SecurityGroupNames -NotePropertyValue @() -Force
        }
        $items.Add($it)
    }
    $instanceScanState.Items = $items.ToArray()
}

function Update-CachedInstanceRole {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates local UI cache after a confirmed AWS change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [AllowNull()][string]$InstanceProfileName
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($it in @(ConvertTo-InstanceItemArray -Items $instanceScanState.Items)) {
        if ([string]$it.InstanceId -eq $InstanceId) {
            $it | Add-Member -NotePropertyName IamInstanceProfile -NotePropertyValue ([string]$InstanceProfileName) -Force
            $it | Add-Member -NotePropertyName IamInstanceProfileArn -NotePropertyValue '' -Force
        }
        $items.Add($it)
    }
    $instanceScanState.Items = $items.ToArray()
}

function Update-InstanceViews {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI refresh helper.')]
    [CmdletBinding()]
    param([switch]$Force)
    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }
        if ((-not $Force) -and $instanceScanState.HasLoaded -and $instanceScanState.Profile -eq $name) {
            [object[]]$cachedItems = @(Get-SharedInstanceItems -Profile $name)
            Update-InstancesGridFromItems -Items $cachedItems
            $statusBarText.Text = "キャッシュ済みインスタンス $($cachedItems.Count) 件を表示しました（再取得は更新ボタン）"
            return
        }
        $statusBarText.Text = 'インスタンス更新中…'
        & $pumpUi
        # @() で包むと unary-comma 返り値が「1 要素 = 配列まるごと」に化けるので使わない
        [object[]]$items = Get-Ec2Instances -Profile $name
        if ($null -eq $items) { $items = @() }
        $instanceScanState.Profile = $name
        $instanceScanState.LastUpdated = Get-Date
        $instanceScanState.HasLoaded = $true
        Update-InstancesGridFromItems -Items $items
        $statusBarText.Text = "インスタンス $($items.Count) 件を更新しました"
        Write-AppLog -Level 'INFO' -Message "インスタンス一括更新: $($items.Count) 件 (Profile=$name)"
    }
    catch {
        $statusBarText.Text = "エラー: $($_.Exception.Message)"
        return
    }
}

$refreshInstancesButton.Add_Click({
        Update-InstanceViews -Force
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
        if (-not (Test-InstanceOperationAllowed -InstanceId $instanceId -OperationLabel $ActionLabel)) { return }
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
        Set-UiBusy -Busy $true
        try {
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
        finally {
            Set-UiBusy -Busy $false
        }
    }
    catch {
        $statusBarText.Text = "エラー: $($_.Exception.Message)"
        Write-AppLog -Level 'ERROR' -Message "インスタンス操作エラー: $ActionLabel - $($_.Exception.Message)"
        return
    }
}

$lockInstanceButton.Add_Click({
        try {
            $row = Get-SelectedInstance
            if ($null -eq $row) { return }
            $instanceId = [string]$row.InstanceId
            if (Test-InstanceLocked -InstanceId $instanceId) {
                $statusBarText.Text = "$instanceId はすでにロックされています"
                Update-InstanceLockButtons
                return
            }
            $lockState.LockedInstanceIds = @((@($lockState.LockedInstanceIds) + $instanceId) | Select-Object -Unique)
            Add-InstanceLockMetadata -Instance $row | Out-Null
            Save-InstanceLockState
            $instancesGrid.Items.Refresh()
            Update-LockDependentControls
            $statusBarText.Text = "$instanceId をロックしました"
            Write-AppLog -Level 'INFO' -Message "インスタンスロック: $instanceId"
        }
        catch {
            $statusBarText.Text = "ロックエラー: $($_.Exception.Message)"
        }
    })

$unlockInstanceButton.Add_Click({
        try {
            $row = Get-SelectedInstance
            if ($null -eq $row) { return }
            $instanceId = [string]$row.InstanceId
            if (-not (Test-InstanceLocked -InstanceId $instanceId)) {
                $statusBarText.Text = "$instanceId はロックされていません"
                Update-InstanceLockButtons
                return
            }
            $answer = [System.Windows.MessageBox]::Show(
                "$instanceId のロックを解除します。`n解除後は起動・停止・再起動・SG変更・SSMコマンド実行が可能になります。`n本当に解除しますか？",
                'aws-ec2-manager',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
                $statusBarText.Text = 'ロック解除をキャンセルしました'
                return
            }
            $lockState.LockedInstanceIds = @(@($lockState.LockedInstanceIds) | Where-Object { $_ -ne $instanceId })
            Add-InstanceLockMetadata -Instance $row | Out-Null
            Save-InstanceLockState
            $instancesGrid.Items.Refresh()
            Update-LockDependentControls
            $statusBarText.Text = "$instanceId のロックを解除しました"
            Write-AppLog -Level 'WARN' -Message "インスタンスロック解除: $instanceId"
        }
        catch {
            $statusBarText.Text = "ロック解除エラー: $($_.Exception.Message)"
        }
    })

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
$exportSgReportButton = Find-Control -Name 'ExportSgReportButton'
$appliedSgList = Find-Control -Name 'AppliedSgList'
$availableSgList = Find-Control -Name 'AvailableSgList'
$moveToAppliedButton = Find-Control -Name 'MoveToAppliedButton'
$moveToAvailableButton = Find-Control -Name 'MoveToAvailableButton'
$sgDiffPanel = Find-Control -Name 'SgDiffPanel'

# Module-scope state for Tab2 (avoid $script: under StrictMode pitfalls).
$tab2State = [PSCustomObject]@{
    OriginalSgIds = @()
    OriginalSgItems = @()
    CurrentInstanceId = $null
    CurrentVpcId = $null
    LastReportPath = $null
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
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
        GroupId              = $GroupId
        GroupName            = $name
        Description          = $Description
        VpcId                = $VpcId
        IpPermissions        = @($IpPermissions)
        IpPermissionsEgress  = @($IpPermissionsEgress)
        DisplayLabel         = "$GroupId ($name)"
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
    $tb.Margin = New-Object System.Windows.Thickness 0,0,0,$Bottom
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
    $expander.Margin = New-Object System.Windows.Thickness 0,4,0,6
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
    $content.Margin = New-Object System.Windows.Thickness 18,6,0,0
    $content.MinHeight = 120
    $expander.Content = $content
    $sgDiffPanel.Children.Add($expander) | Out-Null
}

function Render-SgDiffPanel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param($Diff)

    $sgDiffPanel.Children.Clear()
    if ([string]::IsNullOrEmpty($tab2State.CurrentInstanceId)) {
        Add-SgDiffText -Text 'インスタンスを選択してください。' -Color '#94A3B8' | Out-Null
        return
    }
    if ($null -eq $Diff) {
        Add-SgDiffText -Text '差分を計算できません。' -Color '#F97373' -Bold $true | Out-Null
        return
    }

    Add-SgDiffText -Text "Instance: $($tab2State.CurrentInstanceId)" -Color '#E5E7EB' -Bold $true | Out-Null
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
    Render-SgDiffPanel -Diff $diff
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
    if ($null -ne $tab2State.OriginalSgIds) { $originalIds = @($tab2State.OriginalSgIds) }
    $originalItems = @()
    if ($null -ne $tab2State.OriginalSgItems) { $originalItems = @($tab2State.OriginalSgItems) }

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

function Format-SgContentSection {
    param(
        [Parameter(Mandatory = $true)][string]$Mark,
        [Parameter(Mandatory = $true)]$SecurityGroup
    )
    $lines = @()
    $lines += "$Mark $(Get-SgLabel -Item $SecurityGroup)"
    if (-not [string]::IsNullOrWhiteSpace([string]$SecurityGroup.Description)) {
        $lines += "    Description: $($SecurityGroup.Description)"
    }
    $rules = @(Get-SgRuleRowsForItems -Items @($SecurityGroup))
    $inRules = @($rules | Where-Object { $_.Direction -eq 'Inbound' })
    $outRules = @($rules | Where-Object { $_.Direction -eq 'Outbound' })
    $lines += '    [Inbound]'
    if ($inRules.Count -eq 0) {
        $lines += '      ルールなし'
    }
    foreach ($rule in $inRules) {
        $lines += ('      ' + (Format-SgRuleLine -Rule $rule))
    }
    $lines += '    [Outbound]'
    if ($outRules.Count -eq 0) {
        $lines += '      ルールなし'
    }
    foreach ($rule in $outRules) {
        $lines += ('      ' + (Format-SgRuleLine -Rule $rule))
    }
    return ($lines -join "`r`n")
}

function Format-SgDiffText {
    param($Diff)
    if ([string]::IsNullOrEmpty($tab2State.CurrentInstanceId)) { return 'インスタンスを選択してください。' }
    if ($null -eq $Diff) { return '差分を計算できません。' }

    $lines = @()
    $lines += "Instance: $($tab2State.CurrentInstanceId)"
    $lines += "適用前SG: $($Diff.BeforeIds -join ', ')"
    $lines += "適用後SG: $($Diff.AfterIds -join ', ')"
    $lines += ''
    $lines += '[実効ルール差分（メモ欄は対象外）]'
    $netAddedRules = @($Diff.AddedRules)
    $netRemovedRules = @($Diff.RemovedRules)
    if ($netAddedRules.Count -gt 0 -or $netRemovedRules.Count -gt 0) {
        foreach ($rule in $netAddedRules) { $lines += ('  [+] ' + (Format-SgNetRuleLine -Rule $rule)) }
        foreach ($rule in $netRemovedRules) { $lines += ('  [-] ' + (Format-SgNetRuleLine -Rule $rule)) }
    }
    else {
        $lines += '  実効ルール差分なし'
    }
    $lines += ''
    if (-not $Diff.Changed) {
        $lines += 'SG差分はありません。'
        return ($lines -join "`r`n")
    }
    $lines += '[Security Groups]'
    foreach ($sg in @($Diff.AddedSgs)) { $lines += ('  [+] ' + (Get-SgLabel -Item $sg)) }
    foreach ($sg in @($Diff.RemovedSgs)) { $lines += ('  [-] ' + (Get-SgLabel -Item $sg)) }
    $lines += ''
    $lines += '[Details]'
    foreach ($sg in @($Diff.AddedSgs)) {
        $lines += (Format-SgContentSection -Mark '[+]' -SecurityGroup $sg)
        $lines += ''
    }
    foreach ($sg in @($Diff.RemovedSgs)) {
        $lines += (Format-SgContentSection -Mark '[-]' -SecurityGroup $sg)
        $lines += ''
    }
    return ($lines -join "`r`n")
}

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
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

    if ([string]::IsNullOrEmpty($tab2State.CurrentInstanceId)) {
        $statusBarText.Text = 'インスタンス未選択のためHTML出力できません'
        return $null
    }

    $diff = Get-SgDiffData
    $dir = $Directory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeInstanceId = Get-SafeFileName -Text $tab2State.CurrentInstanceId
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
<title>Security Group Change Report - $(ConvertTo-HtmlText $tab2State.CurrentInstanceId)</title>
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
<div class="meta">Instance: $(ConvertTo-HtmlText $tab2State.CurrentInstanceId) / VPC: $(ConvertTo-HtmlText $tab2State.CurrentVpcId) / Status: $(ConvertTo-HtmlText $Status) / Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
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
    $tab2State.LastReportPath = $path
    return $path
}

function Open-HtmlFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "HTML ファイルが見つかりません: $fullPath"
    }

    $uri = (New-Object System.Uri($fullPath)).AbsoluteUri
    $errors = New-Object System.Collections.Generic.List[string]

    try {
        Start-Process -FilePath 'msedge.exe' -ArgumentList @($uri) -ErrorAction Stop | Out-Null
        return 'msedge.exe'
    }
    catch {
        $errors.Add("msedge.exe: $($_.Exception.Message)")
    }

    try {
        Start-Process -FilePath 'rundll32.exe' -ArgumentList @('url.dll,FileProtocolHandler', $uri) -ErrorAction Stop | Out-Null
        return 'default browser'
    }
    catch {
        $errors.Add("default browser: $($_.Exception.Message)")
    }

    throw "HTML をブラウザで開けません: $fullPath / $($errors.ToArray() -join ' / ')"
}

function Invoke-SgReportHtmlExport {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrEmpty($tab2State.CurrentInstanceId)) {
        $statusBarText.Text = 'インスタンス未選択のためHTML出力できません'
        return
    }

    $reportDir = Get-SgReportDirectory
    $statusBarText.Text = 'SG差分HTMLを出力中...'
    & $pumpUi
    $path = New-SgReportHtml -Status 'Preview' -Directory $reportDir
    if ($null -eq $path) { return }

    Write-AppLog -Level 'INFO' -Message "SG差分HTML出力: $path"
    $browser = Open-HtmlFile -Path $path
    $statusBarText.Text = "SG差分HTMLを出力してブラウザで開きました: $path"
    Write-AppLog -Level 'INFO' -Message "SG差分HTMLブラウザ起動: $path ($browser)"
}

function Open-TaskHtmlResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HtmlPath
    )

    $browser = Open-HtmlFile -Path $HtmlPath
    return $browser
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

function Update-SgInstanceComboBox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [switch]$Refresh
    )
    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }
        Update-InstanceViews
        [object[]]$cachedItems = @(Get-SharedInstanceItems -Profile $name)
        $count = Update-SgInstanceComboBoxFromItems -Items $cachedItems -PreferredInstanceId $instanceScanState.SelectedInstanceId -LoadDetails
        $statusBarText.Text = "スキャン済みインスタンス $count 件を SG に反映しました"
    }
    catch {
        $statusBarText.Text = "エラー: $($_.Exception.Message)"
    }
}

function Update-SgInstanceComboBoxFromItems {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Items,
        [AllowNull()]
        [string]$PreferredInstanceId,
        [switch]$LoadDetails
    )
    [object[]]$Items = @(ConvertTo-InstanceItemArray -Items $Items)
    $prevId = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredInstanceId)) {
        $prevId = $PreferredInstanceId
    }
    elseif ($null -ne $sgInstanceComboBox.SelectedItem) {
        $prevId = [string]$sgInstanceComboBox.SelectedItem.InstanceId
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$instanceScanState.SelectedInstanceId)) {
        $prevId = [string]$instanceScanState.SelectedInstanceId
    }
    $display = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($it in $Items) {
        $label = if ([string]::IsNullOrEmpty($it.Name)) { $it.InstanceId } else { "$($it.InstanceId) ($($it.Name))" }
        $item = [PSCustomObject]@{
            InstanceId       = $it.InstanceId
            Name             = $it.Name
            VpcId            = $it.VpcId
            SecurityGroupIds = $it.SecurityGroupIds
            DisplayLabel     = $label
        }
        Add-InstanceLockMetadata -Instance $item -DisplayLabel $label | Out-Null
        $display.Add($item)
    }
    $comboRefreshState.SuppressSgSelection = $true
    try {
        $sgInstanceComboBox.ItemsSource = $display.ToArray()
        if ($display.Count -gt 0) {
            $match = $null
            if (-not [string]::IsNullOrEmpty($prevId)) {
                $match = $sgInstanceComboBox.ItemsSource | Where-Object { [string]$_.InstanceId -eq $prevId } | Select-Object -First 1
            }
            if ($null -ne $match) {
                $sgInstanceComboBox.SelectedItem = $match
            }
            else {
                $sgInstanceComboBox.SelectedIndex = 0
            }
        }
        else {
            $sgInstanceComboBox.SelectedIndex = -1
        }
    }
    finally {
        $comboRefreshState.SuppressSgSelection = $false
    }
    if ($LoadDetails -and $null -ne $sgInstanceComboBox.SelectedItem) {
        Update-SgListsForInstance -Instance $sgInstanceComboBox.SelectedItem
    }
    return $display.Count
}

function Update-SgListsForInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param($Instance)
    if ($null -eq $Instance) {
        $appliedSgList.ItemsSource = $null
        $availableSgList.ItemsSource = $null
        $tab2State.OriginalSgIds = @()
        $tab2State.OriginalSgItems = @()
        $tab2State.CurrentInstanceId = $null
        $tab2State.CurrentVpcId = $null
        Update-SgDiffPreview
        return
    }
    if ([string]::IsNullOrEmpty($Instance.VpcId)) {
        $statusBarText.Text = "$($Instance.InstanceId) は VPC 情報がありません"
        $appliedSgList.ItemsSource = $null
        $availableSgList.ItemsSource = $null
        $tab2State.OriginalSgIds = @()
        $tab2State.OriginalSgItems = @()
        $tab2State.CurrentInstanceId = $null
        $tab2State.CurrentVpcId = $null
        Update-SgDiffPreview
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
            $item = Get-SgDisplayItem -GroupId $sg.GroupId -GroupName $sg.GroupName -Description $sg.Description -VpcId $sg.VpcId -IpPermissions $sg.IpPermissions -IpPermissionsEgress $sg.IpPermissionsEgress
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

        $appliedSnapshot = @($applied.ToArray())
        $tab2State.OriginalSgIds = [string[]]($appliedSnapshot | ForEach-Object { [string]$_.GroupId })
        $tab2State.OriginalSgItems = @($appliedSnapshot)
        $tab2State.CurrentInstanceId = $Instance.InstanceId
        $tab2State.CurrentVpcId = $Instance.VpcId
        Update-SgDiffPreview

        $isLocked = Test-InstanceLocked -InstanceId ([string]$Instance.InstanceId)
        $applySgButton.IsEnabled = -not $isLocked
        if ($isLocked) {
            $statusBarText.Text = "$($Instance.InstanceId) はロック中です。SG 適用はできません"
        }
        else {
            $statusBarText.Text = "$($Instance.InstanceId): 適用 $($applied.Count) / 候補 $($available.Count)"
        }
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

$exportSgReportButton.IsEnabled = $true

$loadSgButton.Add_Click({
        Update-SgInstanceComboBox
    })

$sgInstanceComboBox.Add_SelectionChanged({
        try {
            if ($comboRefreshState.SuppressSgSelection) { return }
            $sel = $sgInstanceComboBox.SelectedItem
            if ($null -eq $sel) { return }
            Update-SgListsForInstance -Instance $sel
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$moveToAppliedButton.Add_Click({
        try {
            Move-SgItem -From $availableSgList -To $appliedSgList
        }
        catch {
            $statusBarText.Text = "SG 移動エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SG 移動エラー(未適用 -> 適用済み): $($_.Exception.Message)"
        }
    })

$moveToAvailableButton.Add_Click({
        try {
            Move-SgItem -From $appliedSgList -To $availableSgList
        }
        catch {
            $statusBarText.Text = "SG 移動エラー: $($_.Exception.Message)"
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
            $statusBarText.Text = "HTML出力エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SG差分HTML出力エラー: $($_.Exception.Message)"
        }
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
            if (-not (Test-InstanceOperationAllowed -InstanceId $instanceId -OperationLabel 'SG 適用')) { return }

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
            Set-UiBusy -Busy $true
            try {
                $ok = Set-InstanceSecurityGroups -Profile $name -InstanceId $instanceId -GroupIds $newIds
                if ($ok) {
                    $reportPath = New-SgReportHtml -Status 'Applied' -Directory (Get-SgReportDirectory)
                    if ($null -ne $reportPath) {
                        $statusBarText.Text = "$instanceId に SG を適用しました。HTML: $reportPath"
                        Write-AppLog -Level 'INFO' -Message "SG適用HTML出力: $reportPath"
                    }
                    else {
                        $statusBarText.Text = "$instanceId に SG を適用しました"
                    }
                    Write-AppLog -Level 'INFO' -Message "SG 適用完了: $instanceId"
                    $instanceScanState.SelectedInstanceId = $instanceId
                    Update-CachedInstanceSecurityGroups -InstanceId $instanceId -GroupIds $newIds
                    Update-InstancesGridFromItems -Items $instanceScanState.Items
                    Update-SgInstanceComboBoxFromItems -Items $instanceScanState.Items -PreferredInstanceId $instanceId -LoadDetails | Out-Null
                }
                else {
                    $statusBarText.Text = "$instanceId への SG 適用に失敗しました"
                    Write-AppLog -Level 'ERROR' -Message "SG 適用失敗: $instanceId"
                }
            }
            finally {
                Set-UiBusy -Busy $false
            }
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SG 適用エラー: $($_.Exception.Message)"
        }
    })

#----------------------------------------------------------------------
# Tab3: IAM Instance Profile / Role
#----------------------------------------------------------------------

$roleInstanceComboBox = Find-Control -Name 'RoleInstanceComboBox'
$loadRoleButton = Find-Control -Name 'LoadRoleButton'
$applyRoleButton = Find-Control -Name 'ApplyRoleButton'
$appliedRoleList = Find-Control -Name 'AppliedRoleList'
$availableRoleList = Find-Control -Name 'AvailableRoleList'
$moveRoleToAppliedButton = Find-Control -Name 'MoveRoleToAppliedButton'
$moveRoleToAvailableButton = Find-Control -Name 'MoveRoleToAvailableButton'
$roleDiffPanel = Find-Control -Name 'RoleDiffPanel'

$roleState = [PSCustomObject]@{
    CurrentInstanceId = $null
    OriginalProfileName = ''
    OriginalAssociationId = ''
    OriginalAssociationState = ''
}

function Get-RoleProfileLabel {
    param($Item)
    if ($null -eq $Item) { return '' }
    $name = [string](Get-ObjectPropertyValue -Object $Item -Name 'InstanceProfileName')
    $roles = @((Get-ObjectPropertyValue -Object $Item -Name 'RoleNames'))
    $roleText = ($roles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', '
    if ([string]::IsNullOrWhiteSpace($roleText)) { return $name }
    return "$name / Role: $roleText"
}

function Add-RoleDiffText {
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
    $tb.Margin = New-Object System.Windows.Thickness 0,0,0,$Bottom
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $roleDiffPanel.Children.Add($tb) | Out-Null
}

function Get-RoleItemsFromList {
    param($ListBox)
    $items = @()
    if ($null -ne $ListBox.ItemsSource) {
        foreach ($x in $ListBox.ItemsSource) { $items += $x }
    }
    return $items
}

function Get-PlannedRoleItem {
    $items = @(Get-RoleItemsFromList -ListBox $appliedRoleList)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Get-PlannedRoleName {
    $item = Get-PlannedRoleItem
    if ($null -eq $item) { return '' }
    return [string]$item.InstanceProfileName
}

function Get-RoleActionForPlan {
    $originalName = [string]$roleState.OriginalProfileName
    $plannedName = Get-PlannedRoleName
    if ([string]::IsNullOrWhiteSpace($originalName) -and [string]::IsNullOrWhiteSpace($plannedName)) { return 'None' }
    if ([string]::IsNullOrWhiteSpace($originalName) -and -not [string]::IsNullOrWhiteSpace($plannedName)) { return 'Attach' }
    if (-not [string]::IsNullOrWhiteSpace($originalName) -and [string]::IsNullOrWhiteSpace($plannedName)) { return 'Detach' }
    if ($originalName -ne $plannedName) { return 'Replace' }
    return 'None'
}

function Update-RoleActionButtons {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $selectedInstance = $roleInstanceComboBox.SelectedItem
    $isReady = ($null -ne $selectedInstance)
    $isLocked = $false
    if ($isReady) { $isLocked = Test-InstanceLocked -InstanceId ([string]$selectedInstance.InstanceId) }
    $action = Get-RoleActionForPlan

    $moveRoleToAppliedButton.IsEnabled = ($isReady -and (-not $isLocked) -and $null -ne $availableRoleList.SelectedItem)
    $moveRoleToAvailableButton.IsEnabled = ($isReady -and (-not $isLocked) -and $null -ne (Get-PlannedRoleItem))
    $applyRoleButton.IsEnabled = ($isReady -and (-not $isLocked) -and $action -ne 'None')
}

function Render-RoleDiffPanel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $roleDiffPanel.Children.Clear()
    if ([string]::IsNullOrWhiteSpace([string]$roleState.CurrentInstanceId)) {
        Add-RoleDiffText -Text 'インスタンスを選択してください。' -Color '#94A3B8'
        Update-RoleActionButtons
        return
    }

    $current = if ([string]::IsNullOrWhiteSpace([string]$roleState.OriginalProfileName)) { '(なし)' } else { [string]$roleState.OriginalProfileName }
    $plannedName = Get-PlannedRoleName
    $planned = if ([string]::IsNullOrWhiteSpace($plannedName)) { '(なし)' } else { $plannedName }
    $action = Get-RoleActionForPlan
    Add-RoleDiffText -Text "Instance: $($roleState.CurrentInstanceId)" -Bold $true
    Add-RoleDiffText -Text "現在: $current" -Color '#94A3B8'
    Add-RoleDiffText -Text "適用後: $planned" -Color '#94A3B8'
    if (-not [string]::IsNullOrWhiteSpace([string]$roleState.OriginalAssociationState)) {
        Add-RoleDiffText -Text "Association: $($roleState.OriginalAssociationId) / State: $($roleState.OriginalAssociationState)" -Color '#94A3B8'
    }

    if ($action -eq 'None') {
        Add-RoleDiffText -Text 'インスタンスロール差分はありません。' -Color '#94A3B8'
        Update-RoleActionButtons
        return
    }

    if ($action -eq 'Attach') {
        Add-RoleDiffText -Text "[+] アタッチ: $plannedName" -Color '#38BDF8' -Bold $true
    }
    elseif ($action -eq 'Detach') {
        Add-RoleDiffText -Text "[-] デタッチ: $($roleState.OriginalProfileName)" -Color '#F97373' -Bold $true
    }
    else {
        Add-RoleDiffText -Text "[-] デタッチ: $($roleState.OriginalProfileName)" -Color '#F97373' -Bold $true
        Add-RoleDiffText -Text "[+] アタッチ: $plannedName" -Color '#38BDF8' -Bold $true
        Add-RoleDiffText -Text 'AWS API は replace-iam-instance-profile-association を使います。' -Color '#94A3B8'
    }
    Update-RoleActionButtons
}

function Update-RoleInstanceComboBox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param([switch]$Refresh)

    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }
        Update-InstanceViews
        [object[]]$cachedItems = @(Get-SharedInstanceItems -Profile $name)
        $count = Update-RoleInstanceComboBoxFromItems -Items $cachedItems -PreferredInstanceId $instanceScanState.SelectedInstanceId -LoadDetails
        $statusBarText.Text = "スキャン済みインスタンス $count 件をインスタンスロールに反映しました"
    }
    catch {
        $statusBarText.Text = "インスタンスロール更新エラー: $($_.Exception.Message)"
        Write-AppLog -Level 'ERROR' -Message "インスタンスロール更新エラー: $($_.Exception.Message)"
    }
}

function Update-RoleInstanceComboBoxFromItems {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Items,
        [AllowNull()][string]$PreferredInstanceId,
        [switch]$LoadDetails
    )

    [object[]]$Items = @(ConvertTo-InstanceItemArray -Items $Items)
    $prevId = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredInstanceId)) {
        $prevId = $PreferredInstanceId
    }
    elseif ($null -ne $roleInstanceComboBox.SelectedItem) {
        $prevId = [string]$roleInstanceComboBox.SelectedItem.InstanceId
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$instanceScanState.SelectedInstanceId)) {
        $prevId = [string]$instanceScanState.SelectedInstanceId
    }

    $display = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($it in $Items) {
        $label = if ([string]::IsNullOrEmpty($it.Name)) { $it.InstanceId } else { "$($it.InstanceId) ($($it.Name))" }
        $item = [PSCustomObject]@{
            InstanceId             = $it.InstanceId
            Name                   = $it.Name
            IamInstanceProfile     = $it.IamInstanceProfile
            IamInstanceProfileArn  = $it.IamInstanceProfileArn
            DisplayLabel           = $label
        }
        Add-InstanceLockMetadata -Instance $item -DisplayLabel $label | Out-Null
        $display.Add($item)
    }

    $comboRefreshState.SuppressRoleSelection = $true
    try {
        $roleInstanceComboBox.ItemsSource = $display.ToArray()
        if ($display.Count -gt 0) {
            $match = $null
            if (-not [string]::IsNullOrEmpty($prevId)) {
                $match = $roleInstanceComboBox.ItemsSource | Where-Object { [string]$_.InstanceId -eq $prevId } | Select-Object -First 1
            }
            if ($null -ne $match) {
                $roleInstanceComboBox.SelectedItem = $match
            }
            else {
                $roleInstanceComboBox.SelectedIndex = 0
            }
        }
        else {
            $roleInstanceComboBox.SelectedIndex = -1
            $appliedRoleList.ItemsSource = $null
            $availableRoleList.ItemsSource = $null
            $roleDiffPanel.Children.Clear()
            Add-RoleDiffText -Text 'インスタンスを選択してください。' -Color '#94A3B8'
        }
    }
    finally {
        $comboRefreshState.SuppressRoleSelection = $false
    }
    if ($LoadDetails -and $null -ne $roleInstanceComboBox.SelectedItem) {
        Update-RoleProfilesForInstance -Instance $roleInstanceComboBox.SelectedItem
    }
    return $display.Count
}

function Update-RoleProfilesForInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Instance)

    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }

        $roleState.CurrentInstanceId = [string]$Instance.InstanceId
        $roleState.OriginalProfileName = ''
        $roleState.OriginalAssociationId = ''
        $roleState.OriginalAssociationState = ''
        $appliedRoleList.ItemsSource = $null
        $availableRoleList.ItemsSource = $null
        $roleDiffPanel.Children.Clear()
        Add-RoleDiffText -Text 'Instance Profile 情報を取得中...' -Color '#94A3B8'
        & $pumpUi

        $assoc = Get-InstanceProfileAssociation -Profile $name -InstanceId ([string]$Instance.InstanceId)
        if ($null -ne $assoc) {
            $roleState.OriginalProfileName = [string]$assoc.InstanceProfileName
            $roleState.OriginalAssociationId = [string]$assoc.AssociationId
            $roleState.OriginalAssociationState = [string]$assoc.State
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$Instance.IamInstanceProfile)) {
            $roleState.OriginalProfileName = [string]$Instance.IamInstanceProfile
        }

        [object[]]$profiles = Get-IamInstanceProfiles -Profile $name
        if ($null -eq $profiles) { $profiles = @() }

        $applied = New-Object System.Collections.Generic.List[PSCustomObject]
        $items = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($profileItem in $profiles) {
            $displayLabel = Get-RoleProfileLabel -Item $profileItem
            $profileItem | Add-Member -NotePropertyName DisplayLabel -NotePropertyValue $displayLabel -Force
            if (-not [string]::IsNullOrWhiteSpace([string]$roleState.OriginalProfileName) -and
                [string]$profileItem.InstanceProfileName -eq [string]$roleState.OriginalProfileName) {
                $applied.Add($profileItem)
            }
            else {
                $items.Add($profileItem)
            }
        }
        if ($applied.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$roleState.OriginalProfileName)) {
            $fallback = [PSCustomObject]@{
                InstanceProfileName = [string]$roleState.OriginalProfileName
                Arn                 = ''
                Path                = ''
                RoleNames           = @()
                DisplayLabel        = [string]$roleState.OriginalProfileName
            }
            $applied.Add($fallback)
        }
        $appliedRoleList.ItemsSource = $applied.ToArray()
        $availableRoleList.ItemsSource = $items.ToArray()
        if ($applied.Count -gt 0) {
            $appliedRoleList.SelectedIndex = 0
        }

        $isLocked = Test-InstanceLocked -InstanceId ([string]$Instance.InstanceId)
        if ($isLocked) {
            $statusBarText.Text = "$($Instance.InstanceId) はロック中です。インスタンスロール操作はできません"
        }
        else {
            $statusBarText.Text = "$($Instance.InstanceId): Instance Profile 候補 $($items.Count) 件"
        }
        Render-RoleDiffPanel
    }
    catch {
        $statusBarText.Text = "インスタンスロール取得エラー: $($_.Exception.Message)"
        Write-AppLog -Level 'ERROR' -Message "インスタンスロール取得エラー: $($_.Exception.Message)"
    }
}

function Move-RoleToApplied {
    [CmdletBinding()]
    param()

    $selected = $availableRoleList.SelectedItem
    if ($null -eq $selected) { return }

    $available = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($x in @(Get-RoleItemsFromList -ListBox $availableRoleList)) {
        if ([string]$x.InstanceProfileName -ne [string]$selected.InstanceProfileName) {
            $available.Add($x)
        }
    }
    foreach ($x in @(Get-RoleItemsFromList -ListBox $appliedRoleList)) {
        if ([string]$x.InstanceProfileName -ne [string]$selected.InstanceProfileName) {
            $available.Add($x)
        }
    }

    $appliedRoleList.ItemsSource = @($selected)
    $appliedRoleList.SelectedIndex = 0
    $availableRoleList.ItemsSource = $available.ToArray()
    Render-RoleDiffPanel
}

function Move-RoleToAvailable {
    [CmdletBinding()]
    param()

    $planned = Get-PlannedRoleItem
    if ($null -eq $planned) { return }
    $available = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($x in @(Get-RoleItemsFromList -ListBox $availableRoleList)) {
        if ([string]$x.InstanceProfileName -ne [string]$planned.InstanceProfileName) {
            $available.Add($x)
        }
    }
    $available.Add($planned)
    $appliedRoleList.ItemsSource = @()
    $availableRoleList.ItemsSource = $available.ToArray()
    Render-RoleDiffPanel
}

function Invoke-InstanceProfileApply {
    [CmdletBinding()]
    param()

    $name = Get-SelectedProfile
    if ($null -eq $name) { return }
    $inst = $roleInstanceComboBox.SelectedItem
    if ($null -eq $inst) {
        $statusBarText.Text = 'インスタンス未選択'
        return
    }
    $instanceId = [string]$inst.InstanceId
    if (-not (Test-InstanceOperationAllowed -InstanceId $instanceId -OperationLabel 'インスタンスロール適用')) { return }

    $Action = Get-RoleActionForPlan
    if ($Action -eq 'None') {
        $statusBarText.Text = '変更はありません'
        return
    }
    $plannedName = Get-PlannedRoleName
    if (($Action -eq 'Detach' -or $Action -eq 'Replace') -and [string]::IsNullOrWhiteSpace([string]$roleState.OriginalAssociationId)) {
        $statusBarText.Text = '現在の AssociationId が取得できていません。更新してください'
        return
    }
    $actionLabel = if ($Action -eq 'Attach') { 'アタッチ' } elseif ($Action -eq 'Detach') { 'デタッチ' } else { '入れ替え' }
    $msg = "$instanceId にインスタンスロール変更を適用しますか？"
    if ($Action -eq 'Attach') { $msg += "`n追加: $plannedName" }
    elseif ($Action -eq 'Detach') { $msg += "`n削除: $($roleState.OriginalProfileName)" }
    else { $msg += "`n削除: $($roleState.OriginalProfileName)`n追加: $plannedName" }

    $answer = [System.Windows.MessageBox]::Show(
        $msg,
        'aws-ec2-manager',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        $statusBarText.Text = 'インスタンスロール適用をキャンセルしました'
        return
    }

    $statusBarText.Text = "$instanceId にインスタンスロール適用中..."
    Write-AppLog -Level 'INFO' -Message "インスタンスロール適用開始: $instanceId action=$Action current=$($roleState.OriginalProfileName) planned=$plannedName association=$($roleState.OriginalAssociationId)"
    & $pumpUi
    Set-UiBusy -Busy $true
    try {
        $actionParams = @{
            Profile       = $name
            InstanceId    = $instanceId
            Action        = $Action
            AssociationId = [string]$roleState.OriginalAssociationId
        }
        if ($Action -eq 'Attach' -or $Action -eq 'Replace') {
            $actionParams['InstanceProfileName'] = $plannedName
        }
        $ok = Set-InstanceProfileAssociation @actionParams
        if ($ok) {
            $statusBarText.Text = "$instanceId にインスタンスロール変更を適用しました"
            Write-AppLog -Level 'INFO' -Message "インスタンスロール適用完了: $instanceId action=$Action"
            $instanceScanState.SelectedInstanceId = $instanceId
            $cacheRoleName = if ($Action -eq 'Detach') { '' } else { $plannedName }
            Update-CachedInstanceRole -InstanceId $instanceId -InstanceProfileName $cacheRoleName
            Update-InstancesGridFromItems -Items $instanceScanState.Items
            Update-RoleInstanceComboBoxFromItems -Items $instanceScanState.Items -PreferredInstanceId $instanceId -LoadDetails | Out-Null
        }
        else {
            $statusBarText.Text = "$instanceId へのインスタンスロール適用に失敗しました"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール適用失敗: $instanceId action=$Action"
        }
    }
    finally {
        Set-UiBusy -Busy $false
    }
}

$applyRoleButton.IsEnabled = $false
$moveRoleToAppliedButton.IsEnabled = $false
$moveRoleToAvailableButton.IsEnabled = $false

$loadRoleButton.Add_Click({
        Update-RoleInstanceComboBox
    })

$roleInstanceComboBox.Add_SelectionChanged({
        try {
            if ($comboRefreshState.SuppressRoleSelection) { return }
            $sel = $roleInstanceComboBox.SelectedItem
            if ($null -eq $sel) { return }
            Update-RoleProfilesForInstance -Instance $sel
        }
        catch {
            $statusBarText.Text = "インスタンスロール選択エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール選択エラー: $($_.Exception.Message)"
        }
    })

$appliedRoleList.Add_SelectionChanged({
        Render-RoleDiffPanel
    })

$availableRoleList.Add_SelectionChanged({
        Render-RoleDiffPanel
    })

$moveRoleToAppliedButton.Add_Click({
        try { Move-RoleToApplied }
        catch {
            $statusBarText.Text = "インスタンスロール移動エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール移動エラー(候補 -> 適用予定): $($_.Exception.Message)"
        }
    })

$moveRoleToAvailableButton.Add_Click({
        try { Move-RoleToAvailable }
        catch {
            $statusBarText.Text = "インスタンスロール移動エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール移動エラー(適用予定 -> 候補): $($_.Exception.Message)"
        }
    })

$applyRoleButton.Add_Click({
        try { Invoke-InstanceProfileApply }
        catch {
            $statusBarText.Text = "インスタンスロール適用エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール適用エラー: $($_.Exception.Message)"
        }
    })

#----------------------------------------------------------------------
# Tab4: SSM Run Command
#----------------------------------------------------------------------

$ssmInstanceComboBox = Find-Control -Name 'SsmInstanceComboBox'
$loadSsmButton = Find-Control -Name 'LoadSsmButton'
$rescanYamlButton = Find-Control -Name 'RescanYamlButton'
$openYamlFolderButton = Find-Control -Name 'OpenYamlFolderButton'
$addYamlButton = Find-Control -Name 'AddYamlButton'
$yamlListBox = Find-Control -Name 'YamlListBox'
$yamlInfoText = Find-Control -Name 'YamlInfoText'
$yamlScriptPreviewText = Find-Control -Name 'YamlScriptPreviewText'
$saveYamlButton = Find-Control -Name 'SaveYamlButton'
$runSsmButton = Find-Control -Name 'RunSsmButton'
$ssmProgressBar = Find-Control -Name 'SsmProgressBar'
$ssmOutputText = Find-Control -Name 'SsmOutputText'

$uiBusyState = [PSCustomObject]@{ IsBusy = $false }

function Set-UiBusy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Busy
    )
    # $pumpUi（DoEvents 相当）で長時間の AWS 操作中も UI が応答してしまうため、
    # 操作系ボタンを一括で無効化し、実行中に同じ/別の操作を再クリックして
    # ハンドラが再入するのを防ぐ。
    $uiBusyState.IsBusy = $Busy
    $buttons = @(
        $refreshInstancesButton, $startInstanceButton, $stopInstanceButton, $restartInstanceButton,
        $loadSgButton, $applySgButton, $moveToAppliedButton, $moveToAvailableButton,
        $loadRoleButton, $applyRoleButton, $moveRoleToAppliedButton, $moveRoleToAvailableButton,
        $loadSsmButton, $rescanYamlButton, $runSsmButton
    )
    foreach ($b in $buttons) {
        if ($null -ne $b) { $b.IsEnabled = -not $Busy }
    }
}

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
                RawText     = $text
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

function Get-SsmYamlDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Instance
    )

    $root = Join-Path $PSScriptRoot 'ssm-tasks'
    if ($null -eq $Instance) { return $root }

    $sub = if ($Instance.Platform -eq 'Windows') { 'windows' } else { 'linux' }
    $dir = Join-Path $root $sub
    if (Test-Path -LiteralPath $dir) { return $dir }
    return $root
}

function Update-YamlListBoxForInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param($Instance)
    if ($null -eq $Instance) {
        $yamlListBox.ItemsSource = $null
        $runSsmButton.IsEnabled = $true
        $yamlInfoText.Text = ''
        $yamlScriptPreviewText.Text = ''
        return
    }
    $isLocked = Test-InstanceLocked -InstanceId ([string]$Instance.InstanceId)
    $runSsmButton.IsEnabled = -not $isLocked
    $platform = if ($Instance.Platform -eq 'Windows') { 'Windows' } else { 'Linux' }
    # if/else 式は単一要素配列を unroll するため、直接代入で配列形状を保つ
    if ($platform -eq 'Windows') {
        $yamlListBox.ItemsSource = $tab3State.WindowsYamls
    }
    else {
        $yamlListBox.ItemsSource = $tab3State.LinuxYamls
    }
    $yamlInfoText.Text = ''
    $yamlScriptPreviewText.Text = ''
    if ($isLocked) {
        $statusBarText.Text = "$($Instance.InstanceId) はロック中です。SSM コマンド実行はできません"
    }
}

function Get-SafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return 'task' }
    $invalid = '\\/:\*\?"<>\|'
    $safe = ([regex]::Replace($Name.Trim(), "[$invalid]", '_'))
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'task' }
    return $safe
}

function ConvertTo-YamlScalarText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) { return '' }
    return (($Value -replace "`r", ' ') -replace "`n", ' ').Trim()
}

function Set-YamlNameText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $safeName = ConvertTo-YamlScalarText -Value $Name
    $line = "name: $safeName"
    if ($Text -match '(?m)^\s*name\s*:') {
        $nameRegex = New-Object System.Text.RegularExpressions.Regex '(?m)^\s*name\s*:.*$'
        return $nameRegex.Replace($Text, $line, 1)
    }
    return "$line`r`n$Text"
}

function Show-TextInputDialog {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][string]$InitialValue
    )

    $inputXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Input"
        Width="460" Height="170"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#0F172A"
        FontFamily="Yu Gothic UI, Meiryo UI, Segoe UI"
        FontSize="13">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <TextBlock x:Name="LabelText" Grid.Row="0" Foreground="#E2E8F0" FontWeight="SemiBold" Margin="0,0,0,8" />
        <TextBox x:Name="InputTextBox" Grid.Row="1" Padding="8,5" Background="#0B1220" Foreground="#F8FAFC" BorderBrush="#334155" />
        <TextBlock Grid.Row="2" Text="" />
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="OkButton" Content="OK" Width="86" Padding="0,5" Margin="0,0,8,0" IsDefault="True" />
            <Button x:Name="CancelButton" Content="キャンセル" Width="86" Padding="0,5" IsCancel="True" />
        </StackPanel>
    </Grid>
</Window>
'@

    [xml]$xamlDoc = $inputXaml
    $reader2 = New-Object System.Xml.XmlNodeReader $xamlDoc
    $dialog = [Windows.Markup.XamlReader]::Load($reader2)
    $dialog.Owner = $window
    $dialog.Title = $Title

    $labelText = $dialog.FindName('LabelText')
    $inputTextBox = $dialog.FindName('InputTextBox')
    $okButton = $dialog.FindName('OkButton')
    $cancelButton = $dialog.FindName('CancelButton')

    $labelText.Text = $Label
    $inputTextBox.Text = [string]$InitialValue
    $inputTextBox.SelectAll()
    $okButton.Add_Click({
            if ([string]::IsNullOrWhiteSpace($inputTextBox.Text)) {
                $inputTextBox.Focus() | Out-Null
                return
            }
            $dialog.DialogResult = $true
            $dialog.Close()
        })
    $cancelButton.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })
    $dialog.Add_ContentRendered({
            $inputTextBox.Focus() | Out-Null
        })

    if ($dialog.ShowDialog() -eq $true) {
        return ([string]$inputTextBox.Text).Trim()
    }
    return $null
}

function Save-SelectedYamlText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven YAML file save.')]
    [CmdletBinding()]
    param()

    $sel = $yamlListBox.SelectedItem
    if ($null -eq $sel) {
        $statusBarText.Text = '保存する YAML を選択してください'
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$sel.Path)) {
        $statusBarText.Text = 'YAML ファイルのパスを特定できません'
        return
    }

    $text = [string]$yamlScriptPreviewText.Text
    try {
        $parsed = ConvertFrom-MinimalYaml -Text $text
        if (-not $parsed.ContainsKey('script') -or [string]::IsNullOrWhiteSpace([string]$parsed['script'])) {
            $statusBarText.Text = '保存できません: script が空です'
            return
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText([string]$sel.Path, $text, $utf8NoBom)

        $path = [string]$sel.Path
        Update-YamlListsFromDisk
        $inst = $ssmInstanceComboBox.SelectedItem
        if ($null -ne $inst) {
            Update-YamlListBoxForInstance -Instance $inst
        }

        $match = $null
        if ($null -ne $yamlListBox.ItemsSource) {
            $match = $yamlListBox.ItemsSource | Where-Object { [string]$_.Path -eq $path } | Select-Object -First 1
        }
        if ($null -ne $match) {
            $yamlListBox.SelectedItem = $match
        }

        $statusBarText.Text = "YAML を保存しました: $([System.IO.Path]::GetFileName($path))"
        Write-AppLog -Level 'INFO' -Message "YAML 保存: $path"
    }
    catch {
        $statusBarText.Text = "YAML 保存エラー: $($_.Exception.Message)"
    }
}

function New-SsmYamlTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven YAML file creation.')]
    [CmdletBinding()]
    param()

    $inst = $ssmInstanceComboBox.SelectedItem
    if ($null -eq $inst) {
        $statusBarText.Text = '新規追加する前にインスタンスを選択してください'
        return
    }

    try {
        $taskName = Show-TextInputDialog -Title '新規タスク' -Label 'タスク名' -InitialValue '新規タスク'
        if ([string]::IsNullOrWhiteSpace($taskName)) {
            $statusBarText.Text = '新規追加をキャンセルしました'
            return
        }

        $dir = Get-SsmYamlDirectory -Instance $inst
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $baseName = Get-SafeFileName -Name $taskName
        $path = Join-Path $dir "$baseName.yaml"
        $index = 2
        while (Test-Path -LiteralPath $path) {
            $path = Join-Path $dir "$baseName-$index.yaml"
            $index++
        }

        $yamlName = ConvertTo-YamlScalarText -Value $taskName
        $template = @"
name: $yamlName
description:
output: text
timeout: 300
script: |
  echo hello
"@
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, $template, $utf8NoBom)

        Update-YamlListsFromDisk
        Update-YamlListBoxForInstance -Instance $inst
        $match = $null
        if ($null -ne $yamlListBox.ItemsSource) {
            $match = $yamlListBox.ItemsSource | Where-Object { [string]$_.Path -eq $path } | Select-Object -First 1
        }
        if ($null -ne $match) {
            $yamlListBox.SelectedItem = $match
        }

        $statusBarText.Text = "YAML を追加しました: $([System.IO.Path]::GetFileName($path))"
        Write-AppLog -Level 'INFO' -Message "YAML 新規追加: $path"
    }
    catch {
        $statusBarText.Text = "YAML 追加エラー: $($_.Exception.Message)"
    }
}

function Update-SsmInstanceComboBox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param()

    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }

        Update-InstanceViews
        [object[]]$cachedItems = @(Get-SharedInstanceItems -Profile $name)
        $count = Update-SsmInstanceComboBoxFromItems -Items $cachedItems -PreferredInstanceId $instanceScanState.SelectedInstanceId
        $statusBarText.Text = "スキャン済みインスタンス $count 件を SSM に反映しました"
    }
    catch {
        $statusBarText.Text = "SSM インスタンス更新エラー: $($_.Exception.Message)"
        Write-AppLog -Level 'ERROR' -Message "SSM インスタンス更新エラー: $($_.Exception.Message)"
    }
}

function Rename-SelectedYamlTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven YAML task rename.')]
    [CmdletBinding()]
    param()

    $sel = $yamlListBox.SelectedItem
    if ($null -eq $sel) {
        $statusBarText.Text = '名前を変更する YAML を選択してください'
        return
    }

    try {
        $newName = Show-TextInputDialog -Title 'タスク名の変更' -Label '新しいタスク名' -InitialValue ([string]$sel.Name)
        if ([string]::IsNullOrWhiteSpace($newName)) {
            $statusBarText.Text = '名前変更をキャンセルしました'
            return
        }

        $text = [string]$yamlScriptPreviewText.Text
        if ([string]::IsNullOrWhiteSpace($text) -and ($sel.PSObject.Properties.Name -contains 'RawText')) {
            $text = [string]$sel.RawText
        }
        $updatedText = Set-YamlNameText -Text $text -Name $newName

        $parsed = ConvertFrom-MinimalYaml -Text $updatedText
        if (-not $parsed.ContainsKey('script') -or [string]::IsNullOrWhiteSpace([string]$parsed['script'])) {
            $statusBarText.Text = '名前変更できません: script が空です'
            return
        }

        $path = [string]$sel.Path
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, $updatedText, $utf8NoBom)

        Update-YamlListsFromDisk
        $inst = $ssmInstanceComboBox.SelectedItem
        if ($null -ne $inst) {
            Update-YamlListBoxForInstance -Instance $inst
        }

        $match = $null
        if ($null -ne $yamlListBox.ItemsSource) {
            $match = $yamlListBox.ItemsSource | Where-Object { [string]$_.Path -eq $path } | Select-Object -First 1
        }
        if ($null -ne $match) {
            $yamlListBox.SelectedItem = $match
        }

        $statusBarText.Text = "タスク名を変更しました: $newName"
        Write-AppLog -Level 'INFO' -Message "YAML タスク名変更: $path -> $newName"
    }
    catch {
        $statusBarText.Text = "名前変更エラー: $($_.Exception.Message)"
    }
}

function Update-SsmInstanceComboBoxFromItems {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Items,
        [AllowNull()]
        [string]$PreferredInstanceId
    )
    [object[]]$Items = @(ConvertTo-InstanceItemArray -Items $Items)
    $prevId = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredInstanceId)) {
        $prevId = $PreferredInstanceId
    }
    elseif ($null -ne $ssmInstanceComboBox.SelectedItem) {
        $prevId = [string]$ssmInstanceComboBox.SelectedItem.InstanceId
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$instanceScanState.SelectedInstanceId)) {
        $prevId = [string]$instanceScanState.SelectedInstanceId
    }
    $display = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($it in $Items) {
        $label = if ([string]::IsNullOrEmpty($it.Name)) { "$($it.InstanceId) [$($it.Platform)]" } else { "$($it.InstanceId) ($($it.Name)) [$($it.Platform)]" }
        $item = [PSCustomObject]@{
            InstanceId   = $it.InstanceId
            Name         = $it.Name
            Platform     = $it.Platform
            DisplayLabel = $label
        }
        Add-InstanceLockMetadata -Instance $item -DisplayLabel $label | Out-Null
        $display.Add($item)
    }
    $ssmInstanceComboBox.ItemsSource = $display.ToArray()
    if ($display.Count -gt 0) {
        $match = $null
        if (-not [string]::IsNullOrEmpty($prevId)) {
            $match = $ssmInstanceComboBox.ItemsSource | Where-Object { [string]$_.InstanceId -eq $prevId } | Select-Object -First 1
        }
        if ($null -ne $match) {
            $ssmInstanceComboBox.SelectedItem = $match
        }
        else {
            $ssmInstanceComboBox.SelectedIndex = 0
        }
    }
    else {
        $ssmInstanceComboBox.SelectedIndex = -1
    }
    return $display.Count
}

# Initial scan
try {
    Update-YamlListsFromDisk
}
catch {
    $statusBarText.Text = "YAML スキャンエラー: $($_.Exception.Message)"
}

$loadSsmButton.Add_Click({
        Update-SsmInstanceComboBox
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
                $yamlScriptPreviewText.Text = ''
                return
            }
            $desc = if ([string]::IsNullOrEmpty($sel.Description)) { '(なし)' } else { $sel.Description }
            $yamlInfoText.Text = "name: $($sel.Name)`ndescription: $desc`noutput: $($sel.Output)`ntimeout: $($sel.Timeout)"
            if ($sel.PSObject.Properties.Name -contains 'RawText') {
                $yamlScriptPreviewText.Text = [string]$sel.RawText
            }
            else {
                $yamlScriptPreviewText.Text = [string]$sel.Script
            }
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$yamlListBox.Add_MouseDoubleClick({
        Rename-SelectedYamlTask
    })

$saveYamlButton.Add_Click({
        Save-SelectedYamlText
    })

$addYamlButton.Add_Click({
        New-SsmYamlTask
    })

$rescanYamlButton.Add_Click({
        try {
            Update-YamlListsFromDisk
            $sel = $ssmInstanceComboBox.SelectedItem
            if ($null -ne $sel) {
                Update-YamlListBoxForInstance -Instance $sel
            }
            $statusBarText.Text = "YAML 再スキャン完了 (Linux $(@($tab3State.LinuxYamls).Count) / Windows $(@($tab3State.WindowsYamls).Count))"
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
    })

$openYamlFolderButton.Add_Click({
        try {
            $dir = Get-SsmYamlDirectory -Instance $ssmInstanceComboBox.SelectedItem
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Start-Process explorer.exe -ArgumentList $dir | Out-Null
            $statusBarText.Text = "YAML フォルダを開きました: $dir"
            Write-AppLog -Level 'INFO' -Message "YAML フォルダを開く: $dir"
        }
        catch {
            $statusBarText.Text = "YAML フォルダを開けません: $($_.Exception.Message)"
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
            if (-not (Test-InstanceOperationAllowed -InstanceId ([string]$inst.InstanceId) -OperationLabel 'SSM コマンド実行')) { return }
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
            Set-UiBusy -Busy $true
            try {
                $ssmStatusCallback = {
                    param([string]$Message)
                    $ssmOutputText.Text = $Message
                    $firstLine = ($Message -split "`n" | Select-Object -First 1)
                    if ([string]::IsNullOrWhiteSpace($firstLine)) {
                        $statusBarText.Text = "$($yaml.Name) 実行中..."
                    }
                    else {
                        $statusBarText.Text = "$($yaml.Name) 実行中... $firstLine"
                    }
                    & $pumpUi
                }

                $result = Invoke-SsmTask -Profile $name -InstanceId $inst.InstanceId -YamlPath $yaml.Path -Platform $yaml.Platform -StatusCallback $ssmStatusCallback

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
                    $browser = Open-TaskHtmlResult -HtmlPath $htmlPath
                    $ssmOutputText.Text = "HTML 結果をブラウザで開きました: $htmlPath ($browser)"
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
            finally {
                Set-UiBusy -Busy $false
            }
        }
        catch {
            $ssmProgressBar.Visibility = [System.Windows.Visibility]::Collapsed
            $errText = [string]$_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($errText)) {
                $errText = [string]$_
            }
            if ([string]::IsNullOrWhiteSpace($errText)) {
                $errText = '詳細のないエラーが発生しました。操作ログまたは AWS CLI の状態を確認してください。'
            }
            $statusBarText.Text = "エラー: $errText"
            $ssmOutputText.Text = "エラー:`n$errText"
        }
    })

$window.Add_ContentRendered({
        try {
            if (-not $instanceScanState.HasLoaded) {
                Update-InstanceViews
            }
        }
        catch {
            $statusBarText.Text = "初回インスタンス取得エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "初回インスタンス取得エラー: $($_.Exception.Message)"
        }
    })

$window.ShowDialog() | Out-Null
