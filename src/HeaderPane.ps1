<#
.SYNOPSIS
    Header pane: profile selection, SSO login/token check, settings, log folder.
.DESCRIPTION
    プロファイル選択の変更で AppState を初期化し、インスタンス一覧の非同期再取得を
    トリガーする。トークン確認は AsyncRunner 経由で非同期実行する。
    PowerShell 5.1 compatible. App.ps1 から dot-source される。
#>

$profileComboBox = Find-Control -Name 'ProfileComboBox'
$profileInfoText = Find-Control -Name 'ProfileInfoText'
$checkTokenButton = Find-Control -Name 'CheckTokenButton'
$ssoLoginButton = Find-Control -Name 'SsoLoginButton'
$openSsoButton = Find-Control -Name 'OpenSsoButton'
$logButton = Find-Control -Name 'LogButton'
$settingsButton = Find-Control -Name 'SettingsButton'

function ConvertTo-PsSingleQuotedLiteral {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) { return "''" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-SafeFileNamePart {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'profile' }
    $safe = [regex]::Replace($Value, '[^A-Za-z0-9_.-]+', '_')
    $safe = $safe.Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'profile' }
    return $safe
}

function ConvertTo-ProcessArgument {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-SsoLoginWrapperScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an app-owned temporary helper script for visible SSO login diagnostics.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName
    )

    $logDir = Get-AppLogDirectory
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeProfile = Get-SafeFileNamePart -Value $ProfileName
    $logPath = Join-Path $logDir "sso-login-$safeProfile-$stamp.log"
    $scriptPath = Join-Path $logDir "sso-login-$safeProfile-$stamp.ps1"
    $profileLiteral = ConvertTo-PsSingleQuotedLiteral -Value $ProfileName
    $logLiteral = ConvertTo-PsSingleQuotedLiteral -Value $logPath

    $scriptText = @"
`$ErrorActionPreference = 'Continue'
`$profileName = $profileLiteral
`$logPath = $logLiteral
try {
    `$logDir = Split-Path -Parent `$logPath
    if (-not [string]::IsNullOrWhiteSpace(`$logDir) -and -not (Test-Path -LiteralPath `$logDir)) {
        New-Item -ItemType Directory -Path `$logDir -Force | Out-Null
    }
}
catch {
    Write-Host "ログディレクトリ作成エラー: `$(`$_.Exception.Message)" -ForegroundColor Yellow
}

try {
    Start-Transcript -Path `$logPath -Append | Out-Null
}
catch {
    Write-Host "Transcript 開始エラー: `$(`$_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "AWS SSO Login" -ForegroundColor Cyan
Write-Host "Profile : `$profileName"
Write-Host "Log     : `$logPath"
Write-Host ""
Write-Host "このサーバ上ではブラウザを自動起動せず、手元のブラウザで認証する方式で進めます。" -ForegroundColor Yellow
Write-Host "次に表示される URL とコードを使って SSO 認証してください。" -ForegroundColor Yellow
Write-Host ""
Write-Host "Running : aws sso login --no-browser --profile `$profileName"
Write-Host ""

& aws sso login --no-browser --profile `$profileName
`$exitCode = `$LASTEXITCODE
Write-Host ""
if (`$exitCode -eq 0) {
    Write-Host "SSO login completed successfully. ExitCode=`$exitCode" -ForegroundColor Green
}
else {
    Write-Host "SSO login failed. ExitCode=`$exitCode" -ForegroundColor Red
    Write-Host "上のエラー内容とログファイルを確認してください。" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Log: `$logPath"
try {
    Stop-Transcript | Out-Null
}
catch {
}
Write-Host ""
Write-Host "確認が終わったら、このウィンドウを閉じてください。"
"@

    Set-Content -LiteralPath $scriptPath -Value $scriptText -Encoding UTF8
    return [PSCustomObject]@{
        ScriptPath = $scriptPath
        LogPath    = $logPath
    }
}

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
            Set-StatusText -Message "プロファイル $($profiles.Length) 件"
            Write-AppLog -Level 'INFO' -Message "プロファイル読込: $($profiles.Length) 件"
        }
        else {
            $configPath = Get-EffectiveAwsConfigPath
            Set-StatusText -Message "プロファイルが見つかりません ($configPath を確認)"
        }
    }
    catch {
        Set-StatusText -Message "プロファイル読込エラー: $($_.Exception.Message)"
    }
}

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
    $logPathTextBox = $dialog.FindName('LogPathTextBox')
    $browseLogButton = $dialog.FindName('BrowseLogButton')
    $okButton = $dialog.FindName('OkButton')
    $cancelButton = $dialog.FindName('CancelButton')

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
        $newLogPath = $logPathTextBox.Text
        $currentAfter = Get-AppSettings
        Save-AppSettings -AwsConfigPath $newConfigPath -LogPath $newLogPath -LockedInstanceIds $currentAfter.LockedInstanceIds

        if ([string]::IsNullOrWhiteSpace($newConfigPath)) {
            Remove-Item Env:\AWS_CONFIG_FILE -ErrorAction SilentlyContinue
        }
        else {
            $env:AWS_CONFIG_FILE = $newConfigPath
        }

        Initialize-AppLogger -LogPath $newLogPath
        Write-AppLog -Level 'INFO' -Message "設定変更: AwsConfigPath=$newConfigPath LogPath=$newLogPath"

        Set-StatusText -Message '設定を保存しました'
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
            Set-StatusText -Message "ログフォルダを開きました: $logDir"
            Write-AppLog -Level 'INFO' -Message "ログフォルダを開く: $logDir"
        }
        catch {
            Set-StatusText -Message "ログフォルダを開けません: $($_.Exception.Message)"
        }
    })

$profileComboBox.Add_SelectionChanged({
        try {
            $selected = $profileComboBox.SelectedItem

            # プロファイルが変わったら一覧・キャッシュ・選択をすべて破棄する
            $script:AppState.Profile = $null
            $script:AppState.Items = @()
            $script:AppState.SelectedInstanceId = $null
            $script:AppState.HasLoaded = $false
            $script:AppState.LastUpdated = $null
            Clear-InstanceScopedCaches

            if ($null -eq $selected) {
                $profileInfoText.Text = ''
                Set-StatusText -Message 'Ready'
                if ($null -ne (Get-Command -Name Update-InstanceListView -ErrorAction SilentlyContinue)) {
                    Update-InstanceListView
                }
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
            Set-StatusText -Message "Profile: $selected"
            Write-AppLog -Level 'INFO' -Message "プロファイル選択: $selected"

            # 初回表示前(ContentRendered 前)は自動取得しない。表示後の切替では非同期で再取得する。
            if ($script:AppInitialized -and $null -ne (Get-Command -Name Update-InstanceListAsync -ErrorAction SilentlyContinue)) {
                Update-InstanceListAsync -Force
            }
            elseif ($null -ne (Get-Command -Name Update-InstanceListView -ErrorAction SilentlyContinue)) {
                Update-InstanceListView
            }
        }
        catch {
            Set-StatusText -Message "エラー: $($_.Exception.Message)"
            return
        }
    })

$checkTokenButton.Add_Click({
        try {
            $selected = Get-SelectedProfile
            if ($null -eq $selected) { return }
            Set-StatusText -Message "SSO トークン確認中: $selected ..."
            $started = Start-AsyncTask -Name 'トークン確認' -Work {
                param($Channel, $ReportProgress, $profileName)
                return (Test-SsoToken -Name $profileName)
            } -ArgumentList @([string]$selected) -Context @{ Profile = [string]$selected } -OnSuccess {
                param($result, $ctx)
                $sel = [string]$ctx.Profile
                Write-AppLog -Level 'INFO' -Message "aws sts get-caller-identity --profile $sel (result: $result)"
                if ($result) {
                    Set-StatusText -Message 'SSO トークン有効'
                }
                else {
                    Set-StatusText -Message "要 SSO ログイン: aws sso login --profile $sel"
                }
            } -OnError {
                param($err, $ctx)
                Set-StatusText -Message "トークン確認エラー: $err"
            }
            if (-not $started) {
                Set-StatusText -Message '他のタスクを実行中です。完了後に再度お試しください。'
            }
        }
        catch {
            Set-StatusText -Message "エラー: $($_.Exception.Message)"
        }
    })

$openSsoButton.Add_Click({
        try {
            $configPath = Get-EffectiveAwsConfigPath
            $configDir = Split-Path -Parent $configPath
            if (Test-Path -LiteralPath $configPath) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList @($configPath) | Out-Null
                Set-StatusText -Message "$configPath を notepad で開きました"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($configDir) -and (Test-Path -LiteralPath $configDir)) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList @($configDir) | Out-Null
                Set-StatusText -Message "$configDir をエクスプローラで開きました（config ファイルが見つかりません）"
            }
            else {
                Set-StatusText -Message "config パスが存在しません: $configPath"
            }
        }
        catch {
            Set-StatusText -Message "エラー: $($_.Exception.Message)"
            return
        }
    })

$settingsButton.Add_Click({
        try {
            Show-SettingsDialog
        }
        catch {
            Set-StatusText -Message "設定エラー: $($_.Exception.Message)"
        }
    })

$ssoLoginButton.Add_Click({
        try {
            $selected = $profileComboBox.SelectedItem
            if ($null -eq $selected) {
                Set-StatusText -Message 'プロファイル未選択'
                return
            }
            $login = New-SsoLoginWrapperScript -ProfileName ([string]$selected)
            $scriptFileArgument = ConvertTo-ProcessArgument -Value $login.ScriptPath
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoExit',
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $scriptFileArgument
            ) | Out-Null
            Set-StatusText -Message "SSO ログインを別ウィンドウで開きました: $selected （ログ: $($login.LogPath)）"
            Write-AppLog -Level 'INFO' -Message "SSO ログイン開始: $selected Log=$($login.LogPath)"
        }
        catch {
            Set-StatusText -Message "エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SSO ログイン起動エラー: $($_.Exception.Message)"
            return
        }
    })
