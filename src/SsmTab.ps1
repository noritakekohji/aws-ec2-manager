<#
.SYNOPSIS
    Tool execution tab: run SSM Run Command tasks defined in YAML.
.DESCRIPTION
    左ペインの選択インスタンスに追従し、Platform に応じた YAML 一覧を表示する。
    YAML の追加・改名・保存はローカル操作(同期)。実行は AsyncRunner 経由で
    進捗を OnProgress で受け取り、キャンセルボタンで中断できる。
    PowerShell 5.1 compatible. App.ps1 から dot-source される。
#>

$rescanYamlButton = Find-Control -Name 'RescanYamlButton'
$openYamlFolderButton = Find-Control -Name 'OpenYamlFolderButton'
$ssmPlatformText = Find-Control -Name 'SsmPlatformText'
$ssmLoginButton = Find-Control -Name 'SsmLoginButton'
$ssmUserTextBox = Find-Control -Name 'SsmUserTextBox'
$ssmUserHint = Find-Control -Name 'SsmUserHint'
$addYamlButton = Find-Control -Name 'AddYamlButton'
$yamlListBox = Find-Control -Name 'YamlListBox'
$yamlInfoText = Find-Control -Name 'YamlInfoText'
$yamlScriptPreviewText = Find-Control -Name 'YamlScriptPreviewText'
$saveYamlButton = Find-Control -Name 'SaveYamlButton'
$runSsmButton = Find-Control -Name 'RunSsmButton'
$ssmOutputText = Find-Control -Name 'SsmOutputText'

$ssmTabState = [PSCustomObject]@{
    LinuxYamls      = @()
    WindowsYamls    = @()
    CurrentPlatform = ''
}

function Test-SsmTabActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $tabs = Find-Control -Name 'DetailTabs'
    return ($tabs.SelectedIndex -eq 3)
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
    $dir = Join-Path $script:AppRoot (Join-Path 'ssm-tasks' $sub)
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
            $out = if ($task.ContainsKey('output')) { [string]$task['output'] } else { 'text' }
            $to = if ($task.ContainsKey('timeout')) { $task['timeout'] } else { 300 }
            $scr = if ($task.ContainsKey('script')) { [string]$task['script'] } else { '' }
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
            Set-StatusText -Message "YAML 読込エラー: $($f.Name) - $($_.Exception.Message)"
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
    $ssmTabState.LinuxYamls = $lin
    $ssmTabState.WindowsYamls = $win
}

function Get-SsmYamlDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Instance
    )

    $root = Join-Path $script:AppRoot 'ssm-tasks'
    if ($null -eq $Instance) { return $root }

    $sub = if ($Instance.Platform -eq 'Windows') { 'windows' } else { 'linux' }
    $dir = Join-Path $root $sub
    if (Test-Path -LiteralPath $dir) { return $dir }
    return $root
}

function Update-SsmRunButtonState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        $runSsmButton.IsEnabled = $false
        $ssmLoginButton.IsEnabled = $false
        return
    }
    $isLocked = Test-InstanceLocked -InstanceId ([string]$inst.InstanceId)
    $runSsmButton.IsEnabled = (-not $isLocked) -and (-not (Test-AsyncTaskRunning))
    # ログインは対話セッション(別ウィンドウ)なので AsyncRunner のビジー状態とは独立
    $ssmLoginButton.IsEnabled = -not $isLocked
}

function Start-SsmLoginSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven interactive session launch.')]
    [CmdletBinding()]
    param()

    $name = Get-SelectedProfile
    if ($null -eq $name) { return }
    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        Set-StatusText -Message 'インスタンス未選択'
        return
    }
    $instanceId = [string]$inst.InstanceId
    if (-not (Test-InstanceOperationAllowed -InstanceId $instanceId -OperationLabel 'SSM ログイン')) { return }

    $ssmStatus = [string](Get-InstancePropertyText -Instance $inst -Name 'SsmStatus')
    if ($ssmStatus -ne 'Online') {
        Set-StatusText -Message "SSM が Online ではないためログインできません(現在: $ssmStatus)。インスタンスが起動済みで SSM Agent が稼働している必要があります"
        return
    }

    # Session Manager プラグインはクライアント側の必須要件
    if ($null -eq (Get-Command -Name 'session-manager-plugin' -ErrorAction SilentlyContinue)) {
        Show-InfoDialog -Warning -Message ("SSM ログインには Session Manager プラグインが必要です。`n" +
            "インストール後に再度お試しください。`n`n" +
            "インストール例 (winget):`n  winget install Amazon.SessionManagerPlugin`n`n" +
            "参考: AWS ドキュメント『Session Manager plugin をインストールする』")
        Set-StatusText -Message 'session-manager-plugin が見つかりません(未インストール)'
        return
    }

    $runAsUser = [string]$ssmUserTextBox.Text
    $platform = [string](Get-InstancePropertyText -Instance $inst -Name 'Platform')
    if (-not [string]::IsNullOrWhiteSpace($runAsUser) -and $platform -eq 'Windows') {
        Show-InfoDialog -Warning -Message "Windows インスタンスでは対象ユーザーの指定はできません(ssm-user 固定)。`nユーザー欄を空にして再度お試しください。"
        return
    }

    try {
        $argText = Get-SsmSessionArgumentText -Profile $name -InstanceId $instanceId -RunAsUser $runAsUser
    }
    catch {
        Set-StatusText -Message $_.Exception.Message
        return
    }

    # 対話セッションのため別コンソールで起動し、GUI はブロックしない(SSO ログインと同方式)
    Start-Process -FilePath 'aws' -ArgumentList $argText | Out-Null
    $userLabel = if ([string]::IsNullOrWhiteSpace($runAsUser)) { 'ssm-user(既定)' } else { $runAsUser.Trim() }
    Set-StatusText -Message "SSM セッションを別ウィンドウで開始しました: $instanceId (ユーザー: $userLabel)"
    Write-AppLog -Level 'INFO' -Message "SSM ログイン開始: $instanceId user=$userLabel profile=$name"
}

function Update-SsmTabForSelection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        $yamlListBox.ItemsSource = $null
        $yamlInfoText.Text = ''
        $yamlScriptPreviewText.Text = ''
        $ssmPlatformText.Text = 'SSM Run Command'
        $ssmTabState.CurrentPlatform = ''
        Update-SsmRunButtonState
        return
    }

    $platform = if ($inst.Platform -eq 'Windows') { 'Windows' } else { 'Linux' }
    $ssmPlatformText.Text = "Platform: $platform / SSM Run Command"

    # 同じ Platform なら YAML 一覧と選択を維持する(インスタンス切替で選択が飛ばない)
    if ($ssmTabState.CurrentPlatform -ne $platform) {
        $ssmTabState.CurrentPlatform = $platform
        # if/else 式は単一要素配列を unroll するため、直接代入で配列形状を保つ
        if ($platform -eq 'Windows') {
            $yamlListBox.ItemsSource = $ssmTabState.WindowsYamls
        }
        else {
            $yamlListBox.ItemsSource = $ssmTabState.LinuxYamls
        }
        $yamlInfoText.Text = ''
        $yamlScriptPreviewText.Text = ''
    }

    $isLocked = Test-InstanceLocked -InstanceId ([string]$inst.InstanceId)
    if ($isLocked) {
        Set-StatusText -Message "$($inst.InstanceId) はロック中です。SSM コマンド実行はできません"
    }
    Update-SsmRunButtonState
}

function Get-ScriptPreviewText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string]$Script
    )

    # SSM 実行確認ダイアログにスクリプト名だけでなく実行内容も出し、
    # 意図しないタスクをそのまま実行してしまう事故を防ぐためのプレビュー。
    $maxPreviewLines = 12
    if ([string]::IsNullOrWhiteSpace($Script)) { return '(スクリプトが空です)' }

    $lines = $Script -split "`r?`n"
    $preview = ($lines | Select-Object -First $maxPreviewLines) -join "`n"
    if ($lines.Count -gt $maxPreviewLines) {
        $preview += "`n... (以下 $($lines.Count - $maxPreviewLines) 行省略、詳細はプレビュー欄で確認してください)"
    }
    return $preview
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

function Select-YamlListItemByPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $match = $null
    if ($null -ne $yamlListBox.ItemsSource) {
        $match = $yamlListBox.ItemsSource | Where-Object { [string]$_.Path -eq $Path } | Select-Object -First 1
    }
    if ($null -ne $match) {
        $yamlListBox.SelectedItem = $match
    }
}

function Update-YamlListForCurrentPlatform {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    # ItemsSource を差し替えて最新のディスク状態を反映する
    if ($ssmTabState.CurrentPlatform -eq 'Windows') {
        $yamlListBox.ItemsSource = $ssmTabState.WindowsYamls
    }
    elseif ($ssmTabState.CurrentPlatform -eq 'Linux') {
        $yamlListBox.ItemsSource = $ssmTabState.LinuxYamls
    }
}

function Save-SelectedYamlText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven YAML file save.')]
    [CmdletBinding()]
    param()

    $sel = $yamlListBox.SelectedItem
    if ($null -eq $sel) {
        Set-StatusText -Message '保存する YAML を選択してください'
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$sel.Path)) {
        Set-StatusText -Message 'YAML ファイルのパスを特定できません'
        return
    }

    $text = [string]$yamlScriptPreviewText.Text
    try {
        $parsed = ConvertFrom-MinimalYaml -Text $text
        if (-not $parsed.ContainsKey('script') -or [string]::IsNullOrWhiteSpace([string]$parsed['script'])) {
            Set-StatusText -Message '保存できません: script が空です'
            return
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText([string]$sel.Path, $text, $utf8NoBom)

        $path = [string]$sel.Path
        Update-YamlListsFromDisk
        Update-YamlListForCurrentPlatform
        Select-YamlListItemByPath -Path $path

        Set-StatusText -Message "YAML を保存しました: $([System.IO.Path]::GetFileName($path))"
        Write-AppLog -Level 'INFO' -Message "YAML 保存: $path"
    }
    catch {
        Set-StatusText -Message "YAML 保存エラー: $($_.Exception.Message)"
    }
}

function New-SsmYamlTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven YAML file creation.')]
    [CmdletBinding()]
    param()

    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        Set-StatusText -Message '新規追加する前にインスタンスを選択してください'
        return
    }

    try {
        $taskName = Show-TextInputDialog -Title '新規タスク' -Label 'タスク名' -InitialValue '新規タスク'
        if ([string]::IsNullOrWhiteSpace($taskName)) {
            Set-StatusText -Message '新規追加をキャンセルしました'
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
        Update-YamlListForCurrentPlatform
        Select-YamlListItemByPath -Path $path

        Set-StatusText -Message "YAML を追加しました: $([System.IO.Path]::GetFileName($path))"
        Write-AppLog -Level 'INFO' -Message "YAML 新規追加: $path"
    }
    catch {
        Set-StatusText -Message "YAML 追加エラー: $($_.Exception.Message)"
    }
}

function Rename-SelectedYamlTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven YAML task rename.')]
    [CmdletBinding()]
    param()

    $sel = $yamlListBox.SelectedItem
    if ($null -eq $sel) {
        Set-StatusText -Message '名前を変更する YAML を選択してください'
        return
    }

    try {
        $newName = Show-TextInputDialog -Title 'タスク名の変更' -Label '新しいタスク名' -InitialValue ([string]$sel.Name)
        if ([string]::IsNullOrWhiteSpace($newName)) {
            Set-StatusText -Message '名前変更をキャンセルしました'
            return
        }

        $text = [string]$yamlScriptPreviewText.Text
        if ([string]::IsNullOrWhiteSpace($text) -and ($sel.PSObject.Properties.Name -contains 'RawText')) {
            $text = [string]$sel.RawText
        }
        $updatedText = Set-YamlNameText -Text $text -Name $newName

        $parsed = ConvertFrom-MinimalYaml -Text $updatedText
        if (-not $parsed.ContainsKey('script') -or [string]::IsNullOrWhiteSpace([string]$parsed['script'])) {
            Set-StatusText -Message '名前変更できません: script が空です'
            return
        }

        $path = [string]$sel.Path
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, $updatedText, $utf8NoBom)

        Update-YamlListsFromDisk
        Update-YamlListForCurrentPlatform
        Select-YamlListItemByPath -Path $path

        Set-StatusText -Message "タスク名を変更しました: $newName"
        Write-AppLog -Level 'INFO' -Message "YAML タスク名変更: $path -> $newName"
    }
    catch {
        Set-StatusText -Message "名前変更エラー: $($_.Exception.Message)"
    }
}

# Initial scan
try {
    Update-YamlListsFromDisk
}
catch {
    Set-StatusText -Message "YAML スキャンエラー: $($_.Exception.Message)"
}

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
            Set-StatusText -Message "エラー: $($_.Exception.Message)"
        }
    })

$yamlListBox.Add_MouseDoubleClick({
        Rename-SelectedYamlTask
    })

$ssmUserTextBox.Add_TextChanged({
        if ([string]::IsNullOrEmpty([string]$ssmUserTextBox.Text)) {
            $ssmUserHint.Visibility = [System.Windows.Visibility]::Visible
        }
        else {
            $ssmUserHint.Visibility = [System.Windows.Visibility]::Collapsed
        }
    })

$ssmLoginButton.Add_Click({
        try {
            Start-SsmLoginSession
        }
        catch {
            Set-StatusText -Message "SSM ログインエラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "SSM ログインエラー: $($_.Exception.Message)"
        }
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
            Update-YamlListForCurrentPlatform
            Set-StatusText -Message "YAML 再スキャン完了 (Linux $(@($ssmTabState.LinuxYamls).Count) / Windows $(@($ssmTabState.WindowsYamls).Count))"
        }
        catch {
            Set-StatusText -Message "エラー: $($_.Exception.Message)"
        }
    })

$openYamlFolderButton.Add_Click({
        try {
            $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
            $dir = Get-SsmYamlDirectory -Instance $inst
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Start-Process explorer.exe -ArgumentList $dir | Out-Null
            Set-StatusText -Message "YAML フォルダを開きました: $dir"
            Write-AppLog -Level 'INFO' -Message "YAML フォルダを開く: $dir"
        }
        catch {
            Set-StatusText -Message "YAML フォルダを開けません: $($_.Exception.Message)"
        }
    })

$runSsmButton.Add_Click({
        try {
            $name = Get-SelectedProfile
            if ($null -eq $name) { return }
            $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
            if ($null -eq $inst) {
                Set-StatusText -Message 'インスタンス未選択'
                return
            }
            if (-not (Test-InstanceOperationAllowed -InstanceId ([string]$inst.InstanceId) -OperationLabel 'SSM コマンド実行')) { return }
            $yaml = $yamlListBox.SelectedItem
            if ($null -eq $yaml) {
                Set-StatusText -Message 'YAML 未選択'
                return
            }

            $scriptPreview = Get-ScriptPreviewText -Script $yaml.Script
            $confirmMessage = "$($inst.InstanceId) で『$($yaml.Name)』を実行しますか？`n`n--- 実行内容 ($($yaml.Platform)) ---`n$scriptPreview"
            if (-not (Show-ConfirmDialog -Message $confirmMessage)) {
                Set-StatusText -Message '実行をキャンセルしました'
                return
            }

            $ssmOutputText.Text = '実行中...'
            Set-StatusText -Message "$($yaml.Name) 実行中…"
            Write-AppLog -Level 'INFO' -Message "SSM 実行開始: $($yaml.Name) on $($inst.InstanceId)"

            $started = Start-AsyncTask -Name "SSM 実行: $($yaml.Name)" -Work {
                param($Channel, $ReportProgress, $profileName, $targetId, $yamlPath, $platform)
                $statusCallback = {
                    param([string]$Message)
                    & $ReportProgress $Message
                }
                return (Invoke-SsmTask -Profile $profileName -InstanceId $targetId -YamlPath $yamlPath -Platform $platform -StatusCallback $statusCallback)
            } -ArgumentList @([string]$name, [string]$inst.InstanceId, [string]$yaml.Path, [string]$yaml.Platform) -Context @{
                TaskName   = [string]$yaml.Name
                InstanceId = [string]$inst.InstanceId
            } -OnProgress {
                param($message)
                $ssmOutputText.Text = [string]$message
                $firstLine = ([string]$message -split "`n" | Select-Object -First 1)
                if ([string]::IsNullOrWhiteSpace($firstLine)) {
                    Set-StatusText -Message 'SSM 実行中…'
                }
                else {
                    Set-StatusText -Message "SSM 実行中… $firstLine"
                }
            } -OnSuccess {
                param($result, $ctx)
                $outType = if ($null -ne $result.OutputType) { [string]$result.OutputType } else { 'text' }
                if ($outType -eq 'html') {
                    $tmpDir = Join-Path $env:TEMP 'aws-ec2-manager'
                    if (-not (Test-Path -LiteralPath $tmpDir)) {
                        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
                    }
                    $safe = Get-SafeFileName -Name $ctx.TaskName
                    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
                    $htmlPath = Join-Path $tmpDir "$safe-$stamp.html"
                    Set-Content -LiteralPath $htmlPath -Value $result.Output -Encoding UTF8
                    $browser = Open-HtmlFile -Path $htmlPath
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
                Set-StatusText -Message "Status: $($result.Status) / Duration: ${dur}s"
                Write-AppLog -Level 'INFO' -Message "SSM 実行完了: $($ctx.TaskName) on $($ctx.InstanceId) Status=$($result.Status) Duration=${dur}s"
            } -OnError {
                param($err, $ctx)
                Set-StatusText -Message "SSM 実行エラー: $err"
                $ssmOutputText.Text = "エラー:`n$err"
                Write-AppLog -Level 'ERROR' -Message "SSM 実行エラー: $($ctx.TaskName) on $($ctx.InstanceId) - $err"
            }
            if (-not $started) {
                Set-StatusText -Message '他のタスクを実行中です。完了後に再度お試しください。'
            }
        }
        catch {
            $errText = [string]$_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($errText)) {
                $errText = [string]$_
            }
            if ([string]::IsNullOrWhiteSpace($errText)) {
                $errText = '詳細のないエラーが発生しました。操作ログまたは AWS CLI の状態を確認してください。'
            }
            Set-StatusText -Message "エラー: $errText"
            $ssmOutputText.Text = "エラー:`n$errText"
        }
    })
