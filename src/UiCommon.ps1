<#
.SYNOPSIS
    Shared UI helpers (dot-sourced by App.ps1 after XAML load).
.DESCRIPTION
    Find-Control / ステータスバー / 確認ダイアログ / ビジー状態の一括制御。
    ビジー状態は AsyncRunner の OnBusyChanged から呼ばれる。
    PowerShell 5.1 compatible.
#>

function Find-Control {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return $window.FindName($Name)
}

$statusBarText = Find-Control -Name 'StatusBarText'
$taskProgressBar = Find-Control -Name 'TaskProgressBar'
$cancelTaskButton = Find-Control -Name 'CancelTaskButton'

function Set-StatusText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    $statusBarText.Text = $Message
}

function Show-ConfirmDialog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string]$Title = 'aws-ec2-manager',
        [Parameter()][switch]$Warning
    )
    $icon = if ($Warning) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Question }
    $answer = [System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::YesNo,
        $icon
    )
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Show-InfoDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string]$Title = 'aws-ec2-manager',
        [Parameter()][switch]$Warning
    )
    $icon = if ($Warning) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Information }
    [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, $icon) | Out-Null
}

# AsyncRunner のビジー状態に連動して無効化する操作系ボタン。
# 一覧のスクロール・フィルタ・タブ切替・閲覧はビジー中も可能なまま残す。
function Set-UiBusy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Busy
    )
    $buttons = @(
        (Find-Control -Name 'RefreshInstancesButton'),
        (Find-Control -Name 'StartInstanceButton'),
        (Find-Control -Name 'StopInstanceButton'),
        (Find-Control -Name 'RestartInstanceButton'),
        (Find-Control -Name 'ReloadSgButton'),
        (Find-Control -Name 'ApplySgButton'),
        (Find-Control -Name 'ReloadRoleButton'),
        (Find-Control -Name 'ApplyRoleButton'),
        (Find-Control -Name 'RunSsmButton'),
        (Find-Control -Name 'SsoLoginButton'),
        (Find-Control -Name 'CheckTokenButton')
    )
    foreach ($b in $buttons) {
        if ($null -ne $b) { $b.IsEnabled = -not $Busy }
    }
    $profileCombo = Find-Control -Name 'ProfileComboBox'
    if ($null -ne $profileCombo) { $profileCombo.IsEnabled = -not $Busy }

    if ($Busy) {
        $taskProgressBar.Visibility = [System.Windows.Visibility]::Visible
        $cancelTaskButton.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $taskProgressBar.Visibility = [System.Windows.Visibility]::Collapsed
        $cancelTaskButton.Visibility = [System.Windows.Visibility]::Collapsed
        # 一括再有効化の後に、ロック状態に応じたボタン制御を各タブで再評価する
        foreach ($fn in @('Update-InstanceLockButtons', 'Update-SgApplyButtonState', 'Update-RoleActionButtons', 'Update-SsmRunButtonState')) {
            if ($null -ne (Get-Command -Name $fn -ErrorAction SilentlyContinue)) {
                try { & $fn } catch { }
            }
        }
    }
}

$cancelTaskButton.Add_Click({
        try {
            $taskName = Get-AsyncTaskName
            $channel = Get-AsyncChannel
            Stop-AsyncTask

            # SSM 実行中だった場合はリモート側のコマンドもベストエフォートでキャンセルする
            # (パイプライン停止後は背景側から cancel-command を送れないため UI 側で行う)
            $ssmCommandId = ''
            if ($channel.ContainsKey('SsmCommandId')) { $ssmCommandId = [string]$channel['SsmCommandId'] }
            if (-not [string]::IsNullOrWhiteSpace($ssmCommandId)) {
                $ssmProfile = [string]$channel['SsmProfile']
                $ssmInstanceId = [string]$channel['SsmInstanceId']
                Start-Process -FilePath 'aws' -WindowStyle Hidden -ArgumentList @(
                    'ssm', 'cancel-command',
                    '--profile', $ssmProfile,
                    '--command-id', $ssmCommandId,
                    '--instance-ids', $ssmInstanceId
                ) | Out-Null
                Write-AppLog -Level 'WARN' -Message "SSM リモートコマンドのキャンセルを要求: $ssmCommandId ($ssmInstanceId)"
                foreach ($k in @('SsmCommandId', 'SsmInstanceId', 'SsmProfile')) {
                    if ($channel.ContainsKey($k)) { $channel.Remove($k) }
                }
            }
            Write-AppLog -Level 'WARN' -Message "タスクをキャンセル: $taskName"
        }
        catch {
            Set-StatusText -Message "キャンセルエラー: $($_.Exception.Message)"
        }
    })

function Get-SelectedProfile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $combo = Find-Control -Name 'ProfileComboBox'
    $sel = $combo.SelectedItem
    if ($null -eq $sel) {
        Set-StatusText -Message 'プロファイル未選択'
        return $null
    }
    return [string]$sel
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-SafeFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return 'task' }
    $invalid = '\\/:\*\?"<>\|'
    $safe = ([regex]::Replace($Name.Trim(), "[$invalid]", '_'))
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'task' }
    return $safe
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

function ConvertTo-HtmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}
