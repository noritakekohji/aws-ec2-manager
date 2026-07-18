#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CatalogPath = Join-Path $ScriptRoot 'tools\tool-catalog.yaml'
$XamlPath = Join-Path $ScriptRoot 'LocalToolsLauncher.xaml'
$SettingsXamlPath = Join-Path $ScriptRoot 'LocalToolsLauncherSettings.xaml'
$ConfigDir = Join-Path $env:LOCALAPPDATA 'aws-ec2-manager'
$ConfigPath = Join-Path $ConfigDir 'tool-launcher.json'
$DefaultToolsRoot = Join-Path $ScriptRoot 'tools'
$DefaultOutputRoot = Join-Path $ScriptRoot 'reports\local-tools'
$script:Catalog = @()
$script:CurrentTool = $null
$script:LastRunDir = ''
$script:TextParameterControls = @()
$script:CheckParameterControls = @()
$script:SelectParameterControls = @()
$script:LoadedConfig = $null
$script:CurrentProc = $null
$script:CurrentRunCtx = $null
$script:CurrentRunspace = $null
$script:CurrentPowerShell = $null
$script:CurrentHandle = $null
$script:WaitTimer = $null
$script:ToolsRoot = $DefaultToolsRoot
$script:OutputRoot = $DefaultOutputRoot
$script:AwsProfile = ''
$script:ConfigFileOverrides = @{}   # "<toolId>::<label>" -> user-selected absolute path
$script:LastPerfSessionDir = ''     # perf-monitor: 直近開始したセッションディレクトリ(専用パネルと汎用パネルで共有)

function ConvertTo-DisplayPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return $Path.Replace('\', '/')
}

function Import-LauncherConfig {
    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            [System.Windows.MessageBox]::Show("設定ファイルを読み込めませんでした。既定値で起動します。`n$($_.Exception.Message)", 'ツールランチャー') | Out-Null
        }
    }
    return [pscustomobject]@{
        ToolsRoot = $DefaultToolsRoot
        OutputRoot = $DefaultOutputRoot
        DefaultAwsProfile = ''
        OpenReportAfterRun = $true
        KeepConsoleOpen = $false
    }
}

function Get-ConfigBool {
    param(
        $Config,
        [string]$Name,
        [bool]$DefaultValue
    )
    if ($null -eq $Config) { return $DefaultValue }
    $prop = $Config.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $DefaultValue }
    return [bool]$prop.Value
}

function Get-ConfigValue {
    param(
        $Config,
        [string]$Name,
        [string]$DefaultValue
    )
    if ($null -eq $Config) { return $DefaultValue }
    $prop = $Config.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return [string]$prop.Value }
    return $DefaultValue
}

function Save-LauncherConfig {
    $openReport = Get-ConfigBool -Config $script:LoadedConfig -Name 'OpenReportAfterRun' -DefaultValue $true
    $keepConsole = Get-ConfigBool -Config $script:LoadedConfig -Name 'KeepConsoleOpen' -DefaultValue $false
    $obj = [pscustomobject]@{
        ToolsRoot = $script:ToolsRoot
        OutputRoot = $script:OutputRoot
        DefaultAwsProfile = $script:AwsProfile
        OpenReportAfterRun = $openReport
        KeepConsoleOpen = $keepConsole
        ConfigFileOverrides = $script:ConfigFileOverrides
    }
    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    $script:LoadedConfig = $obj
    Set-Status "設定を保存しました: $ConfigPath"
}

function Import-ConfigFileOverrides {
    param($Config)
    $map = @{}
    if ($null -eq $Config) { return $map }
    $prop = $Config.PSObject.Properties['ConfigFileOverrides']
    if ($null -eq $prop -or $null -eq $prop.Value) { return $map }
    foreach ($p in $prop.Value.PSObject.Properties) {
        if ($null -ne $p.Value) { $map[$p.Name] = [string]$p.Value }
    }
    return $map
}

function ConvertFrom-ToolCatalogScalar {
    param([string]$Value)
    $v = $Value.Trim()
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
        return $v.Substring(1, $v.Length - 2)
    }
    return $v
}

function Read-ToolCatalog {
    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "Catalog not found: $CatalogPath"
    }
    $result = New-Object System.Collections.Generic.List[object]
    $current = $null
    $currentParam = $null
    $currentConfig = $null
    $toolSubKeyIndent = -1
    $paramSubKeyIndent = -1
    $configSubKeyIndent = -1

    foreach ($rawLine in (Get-Content -LiteralPath $CatalogPath -Encoding UTF8)) {
        $line = $rawLine.TrimEnd()
        if (-not $line.Trim()) { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }

        if ($line -match '^(\s*)-\s+id:\s*(.+?)\s*$') {
            if ($null -ne $current) {
                if ($null -ne $currentParam) {
                    $current.Parameters += [pscustomobject]$currentParam
                    $currentParam = $null
                }
                if ($null -ne $currentConfig) {
                    $current.ConfigFiles += [pscustomobject]$currentConfig
                    $currentConfig = $null
                }
                [void]$result.Add([pscustomobject]$current)
            }
            $current = [ordered]@{
                Id = ConvertFrom-ToolCatalogScalar $Matches[2]
                Name = ''
                Description = ''
                Menu = $true
                WindowsPath = ''
                LinuxPath = ''
                DefaultArgs = ''
                Parameters = @()
                ConfigFiles = @()
            }
            $toolSubKeyIndent = $Matches[1].Length + 2
            $paramSubKeyIndent = -1
            $configSubKeyIndent = -1
            continue
        }

        if ($null -eq $current) { continue }

        if ($line -match '^(\s*)-\s+key:\s*(.+?)\s*$') {
            $listIndent = $Matches[1].Length
            if ($listIndent -lt $toolSubKeyIndent) { continue }
            if ($null -ne $currentParam) {
                $current.Parameters += [pscustomobject]$currentParam
            }
            if ($null -ne $currentConfig) {
                $current.ConfigFiles += [pscustomobject]$currentConfig
                $currentConfig = $null
                $configSubKeyIndent = -1
            }
            $currentParam = [ordered]@{
                Key = ConvertFrom-ToolCatalogScalar $Matches[2]
                Label = ''
                Type = 'text'
                Width = ''
                Argument = ''
                Default = ''
                Value = ''
                Required = $false
                Options = ''
            }
            $paramSubKeyIndent = $listIndent + 2
            continue
        }

        # ConfigFile list item — matches `- label: <value>` under `configFiles:`.
        # Distinguished from `- key:` (parameters) by the leading key name.
        if ($line -match '^(\s*)-\s+label:\s*(.+?)\s*$') {
            $listIndent = $Matches[1].Length
            if ($listIndent -lt $toolSubKeyIndent) { continue }
            if ($null -ne $currentConfig) {
                $current.ConfigFiles += [pscustomobject]$currentConfig
            }
            if ($null -ne $currentParam) {
                $current.Parameters += [pscustomobject]$currentParam
                $currentParam = $null
                $paramSubKeyIndent = -1
            }
            $currentConfig = [ordered]@{
                Label = ConvertFrom-ToolCatalogScalar $Matches[2]
                Path = ''
                EnvVar = ''
                ParamKey = ''
                ArgName = ''
            }
            $configSubKeyIndent = $listIndent + 2
            continue
        }

        if ($line -match '^(\s+)([A-Za-z0-9_]+):\s*(.*?)\s*$') {
            $lineIndent = $Matches[1].Length
            $key = $Matches[2]
            $value = ConvertFrom-ToolCatalogScalar $Matches[3]

            if ($null -ne $currentConfig -and $configSubKeyIndent -ge 0 -and $lineIndent -ge $configSubKeyIndent) {
                switch ($key) {
                    'path'     { $currentConfig.Path = $value }
                    'envVar'   { $currentConfig.EnvVar = $value }
                    'paramKey' { $currentConfig.ParamKey = $value }
                    'argName'  { $currentConfig.ArgName = $value }
                }
                continue
            }

            if ($null -ne $currentParam -and $paramSubKeyIndent -ge 0 -and $lineIndent -ge $paramSubKeyIndent) {
                switch ($key) {
                    'label' { $currentParam.Label = $value }
                    'type' { $currentParam.Type = $value }
                    'width' { $currentParam.Width = $value }
                    'argument' { $currentParam.Argument = $value }
                    'default' { $currentParam.Default = $value }
                    'value' { $currentParam.Value = $value }
                    'required' { $currentParam.Required = ($value -eq 'true') }
                    'options' { $currentParam.Options = $value }
                }
                continue
            }

            if ($null -ne $currentParam -and $lineIndent -le $toolSubKeyIndent) {
                $current.Parameters += [pscustomobject]$currentParam
                $currentParam = $null
                $paramSubKeyIndent = -1
            }
            if ($null -ne $currentConfig -and $lineIndent -le $toolSubKeyIndent) {
                $current.ConfigFiles += [pscustomobject]$currentConfig
                $currentConfig = $null
                $configSubKeyIndent = -1
            }

            if ($lineIndent -ge $toolSubKeyIndent) {
                if ($key -eq 'parameters' -or $key -eq 'configFiles') { continue }
                switch ($key) {
                    'name' { $current.Name = $value }
                    'description' { $current.Description = $value }
                    'menu' { $current.Menu = ($value -eq 'true') }
                    'windowsPath' { $current.WindowsPath = $value }
                    'linuxPath' { $current.LinuxPath = $value }
                    'defaultArgs' { $current.DefaultArgs = $value }
                }
            }
        }
    }

    if ($null -ne $current) {
        if ($null -ne $currentParam) {
            $current.Parameters += [pscustomobject]$currentParam
        }
        if ($null -ne $currentConfig) {
            $current.ConfigFiles += [pscustomobject]$currentConfig
        }
        [void]$result.Add([pscustomobject]$current)
    }
    return $result.ToArray()
}

function Get-SelectedTool {
    $item = $ToolListBox.SelectedItem
    if ($null -eq $item) { return $null }
    return $item.Tool
}

function Get-ToolById {
    param([string]$ToolId)
    foreach ($tool in $script:Catalog) {
        if ($tool.Id -eq $ToolId) { return $tool }
    }
    return $null
}

function Get-ToolDir {
    param($Tool)
    $relativePath = [string]$Tool.WindowsPath
    if (-not $relativePath) { $relativePath = [string]$Tool.LinuxPath }
    $normalized = $relativePath.Replace('/', '\')
    $dir = Split-Path -Parent $normalized
    if (-not $dir) { return $script:ToolsRoot }
    return Join-Path $script:ToolsRoot $dir
}

function New-RunDirectory {
    param([string]$ToolId)
    $root = $script:OutputRoot
    if (-not $root) { throw 'OutputRoot is empty.' }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path (Join-Path $root $ToolId) $stamp
    $artifacts = Join-Path $dir 'artifacts'
    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    return $dir
}

function Expand-ArgumentTemplate {
    param(
        [string]$Template,
        $Tool,
        [string]$RunDir
    )
    $toolDir = Get-ToolDir -Tool $Tool
    $artifacts = Join-Path $RunDir 'artifacts'
    $value = $Template
    $value = $value.Replace('{ToolDir}', (ConvertTo-DisplayPath $toolDir))
    $value = $value.Replace('{RunDir}', (ConvertTo-DisplayPath $RunDir))
    $value = $value.Replace('{ArtifactsDir}', (ConvertTo-DisplayPath $artifacts))
    $value = $value.Replace('{AwsProfile}', $script:AwsProfile)
    return $value
}

function Split-CommandLine {
    param([string]$CommandLine)
    $tokenMatches = [regex]::Matches($CommandLine, '("[^"]*"|''[^'']*''|\S+)')
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($m in $tokenMatches) {
        $v = $m.Value
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        [void]$parts.Add($v)
    }
    return $parts.ToArray()
}

function Add-ArgumentValue {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [string]$Value
    )
    if ($Value -and $Value.Trim()) {
        [void]$Arguments.Add($Name)
        [void]$Arguments.Add($Value.Trim())
    }
}

function Add-SwitchValue {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [bool]$Enabled
    )
    if ($Enabled) { [void]$Arguments.Add($Name) }
}

function Get-ArtifactsDir {
    param([string]$RunDir)
    return Join-Path $RunDir 'artifacts'
}

function Expand-LauncherValue {
    param(
        [string]$Value,
        $Tool,
        [string]$RunDir
    )
    return Expand-ArgumentTemplate -Template $Value -Tool $Tool -RunDir $RunDir
}

function Add-ParameterToArguments {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$ArgumentName,
        [string]$Value
    )
    if ($ArgumentName -and $ArgumentName.Trim()) {
        [void]$Arguments.Add($ArgumentName.Trim())
    }
    if ($Value -and $Value.Trim()) {
        [void]$Arguments.Add($Value.Trim())
    }
}

function Get-ParameterValueByKey {
    param([string]$Key)
    foreach ($binding in $script:TextParameterControls) {
        if ($binding.Parameter.Key -eq $Key) { return $binding.Control.Text.Trim() }
    }
    foreach ($binding in $script:CheckParameterControls) {
        if ($binding.Parameter.Key -eq $Key) { return [bool]$binding.Control.IsChecked }
    }
    foreach ($binding in $script:SelectParameterControls) {
        if ($binding.Parameter.Key -eq $Key) {
            $sel = $binding.Control.SelectedItem
            if ($null -eq $sel) { return '' }
            return [string]$sel
        }
    }
    return $null
}

function Add-ConfigFileArgs {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        $Tool
    )
    if ($null -eq $Tool) { return }
    if ($null -eq (Get-Member -InputObject $Tool -Name 'ConfigFiles' -ErrorAction SilentlyContinue)) { return }
    foreach ($cf in @($Tool.ConfigFiles)) {
        $argName = [string]$cf.ArgName
        if (-not $argName) { continue }
        $path = Get-ConfigFileEffectivePath -ToolId ([string]$Tool.Id) -ConfigFile $cf
        if (-not $path) { continue }
        [void]$Arguments.Add($argName)
        [void]$Arguments.Add($path)
    }
}

function Get-ConfigFileEnvVars {
    param($Tool)
    $map = @{}
    if ($null -eq $Tool) { return $map }
    if ($null -eq (Get-Member -InputObject $Tool -Name 'ConfigFiles' -ErrorAction SilentlyContinue)) { return $map }
    foreach ($cf in @($Tool.ConfigFiles)) {
        $envVar = [string]$cf.EnvVar
        if (-not $envVar) { continue }
        $path = Get-ConfigFileEffectivePath -ToolId ([string]$Tool.Id) -ConfigFile $cf
        if ($path) { $map[$envVar] = $path }
    }
    return $map
}

function Get-ToolArguments {
    param(
        $Tool,
        [string]$RunDir
    )
    $argList = New-Object System.Collections.Generic.List[string]
    Add-ConfigFileArgs -Arguments $argList -Tool $Tool
    foreach ($paramDef in @($Tool.Parameters)) {
        $type = [string]$paramDef.Type
        $argumentName = [string]$paramDef.Argument
        $value = ''
        if ($type -eq 'hidden') {
            $value = Expand-LauncherValue -Value ([string]$paramDef.Value) -Tool $Tool -RunDir $RunDir
            Add-ParameterToArguments -Arguments $argList -ArgumentName $argumentName -Value $value
            continue
        }
        if ($type -eq 'checkbox') {
            $checked = [bool](Get-ParameterValueByKey -Key $paramDef.Key)
            if ($checked) {
                $value = Expand-LauncherValue -Value ([string]$paramDef.Value) -Tool $Tool -RunDir $RunDir
                Add-ParameterToArguments -Arguments $argList -ArgumentName $argumentName -Value $value
            }
            continue
        }
        $value = [string](Get-ParameterValueByKey -Key $paramDef.Key)
        if ($paramDef.Required -and -not $value) {
            throw "$($paramDef.Label) を指定してください。"
        }
        if ($value) {
            $value = Expand-LauncherValue -Value $value -Tool $Tool -RunDir $RunDir
            Add-ParameterToArguments -Arguments $argList -ArgumentName $argumentName -Value $value
        }
    }
    return $argList.ToArray()
}

function Join-PreviewCommand {
    param([string]$Exe, [string[]]$Arguments)
    $all = @($Exe) + $Arguments
    return ($all | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '
}

function Join-ProcessArguments {
    param([string[]]$Arguments)
    return ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '
}

function Build-Command {
    param(
        $Tool,
        [string]$RunDir,
        [string[]]$ToolArgsOverride = $null,
        [switch]$RequireEntry
    )
    $toolDir = Get-ToolDir -Tool $Tool
    $entry = Join-Path $script:ToolsRoot ([string]$Tool.WindowsPath).Replace('/', '\')
    if ($RequireEntry -and -not (Test-Path -LiteralPath $entry)) {
        throw "入口ファイルが見つかりません: $entry"
    }
    $toolArgs = $ToolArgsOverride
    if ($null -eq $toolArgs) {
        $toolArgs = Get-ToolArguments -Tool $Tool -RunDir $RunDir
    }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry) + $toolArgs
    return [pscustomobject]@{
        FileName = 'powershell.exe'
        Arguments = $arguments
        ArgumentString = Join-ProcessArguments -Arguments $arguments
        WorkingDirectory = $toolDir
        EntryPath = $entry
        Preview = Join-PreviewCommand -Exe 'powershell.exe' -Arguments $arguments
    }
}

function Update-Header {
    if ($null -ne $StatusText) {
        # status bar shows config location while idle
    }
}

function Set-Status {
    param([string]$Message)
    $StatusText.Text = $Message
}

function Add-LogLine {
    param([string]$Message)
    if ($LogTextBox.Text) {
        $LogTextBox.AppendText("`r`n$Message")
    } else {
        $LogTextBox.AppendText($Message)
    }
    $LogTextBox.ScrollToEnd()
}

function Get-ToolConfigDefaultPath {
    param([string]$RelativePath)
    if (-not $RelativePath) { return '' }
    $normalized = $RelativePath.Replace('/', '\')
    return Join-Path $script:ToolsRoot $normalized
}

function Get-ConfigOverrideKey {
    param([string]$ToolId, [string]$Label)
    return "$ToolId::$Label"
}

function Get-ConfigFileEffectivePath {
    param([string]$ToolId, $ConfigFile)
    $key = Get-ConfigOverrideKey -ToolId $ToolId -Label ([string]$ConfigFile.Label)
    if ($script:ConfigFileOverrides.ContainsKey($key)) {
        $ov = [string]$script:ConfigFileOverrides[$key]
        if ($ov) { return $ov }
    }
    return Get-ToolConfigDefaultPath -RelativePath ([string]$ConfigFile.Path)
}

function Set-ConfigFileOverride {
    param([string]$ToolId, [string]$Label, [string]$NewPath, [string]$DefaultPath)
    $key = Get-ConfigOverrideKey -ToolId $ToolId -Label $Label
    if (-not $NewPath -or $NewPath -eq $DefaultPath) {
        [void]$script:ConfigFileOverrides.Remove($key)
    } else {
        $script:ConfigFileOverrides[$key] = $NewPath
    }
    try { Save-LauncherConfig } catch { }
}

function Get-ParameterControlByKey {
    param([string]$Key)
    foreach ($binding in $script:TextParameterControls) {
        if ($binding.Parameter.Key -eq $Key) { return $binding.Control }
    }
    return $null
}

function Get-ParamConfigFileMap {
    # paramKey -> configFile object, for tools that route a config file into a parameter.
    param($Tool)
    $map = @{}
    if ($null -eq $Tool) { return $map }
    if ($null -ne (Get-Member -InputObject $Tool -Name 'ConfigFiles' -ErrorAction SilentlyContinue)) {
        foreach ($cf in @($Tool.ConfigFiles)) {
            $pk = [string]$cf.ParamKey
            if ($pk) { $map[$pk] = $cf }
        }
    }
    return $map
}

function Save-ConfigBoxOverride {
    param([string]$ToolId, $ConfigFile, [string]$Path)
    $default = Get-ToolConfigDefaultPath -RelativePath ([string]$ConfigFile.Path)
    Set-ConfigFileOverride -ToolId $ToolId -Label ([string]$ConfigFile.Label) -NewPath $Path -DefaultPath $default
}

function Open-ConfigFileInEditor {
    param([string]$FullPath)
    if (-not $FullPath) { return }
    if (-not (Test-Path -LiteralPath $FullPath)) {
        $answer = [System.Windows.MessageBox]::Show(
            "設定ファイルが見つかりません:`n$FullPath`n`n空ファイルとして作成して開きますか？",
            'ツールランチャー',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $parent = Split-Path -Parent $FullPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        New-Item -ItemType File -Path $FullPath -Force | Out-Null
    }
    try {
        Start-Process -FilePath $FullPath -ErrorAction Stop
    } catch {
        try {
            Start-Process -FilePath 'notepad.exe' -ArgumentList $FullPath -ErrorAction Stop
        } catch {
            [System.Windows.MessageBox]::Show(
                "エディタでの起動に失敗しました:`n$($_.Exception.Message)",
                'ツールランチャー') | Out-Null
        }
    }
}

function Invoke-SelectConfigFile {
    param(
        [string]$ToolId,
        $ConfigFile,
        [System.Windows.Controls.TextBox]$PathBox
    )
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "設定ファイルを選択: $($ConfigFile.Label)"
    $dlg.Filter = "設定ファイル (*.conf;*.lst;*.ini;*.cfg;*.txt)|*.conf;*.lst;*.ini;*.cfg;*.txt|すべてのファイル (*.*)|*.*"
    $current = [string]$PathBox.Text
    if ($current -and (Test-Path -LiteralPath $current)) {
        $dlg.InitialDirectory = Split-Path -Parent $current
        $dlg.FileName = Split-Path -Leaf $current
    } else {
        $defaultPath = Get-ToolConfigDefaultPath -RelativePath ([string]$ConfigFile.Path)
        $defaultDir = Split-Path -Parent $defaultPath
        if ($defaultDir -and (Test-Path -LiteralPath $defaultDir)) {
            $dlg.InitialDirectory = $defaultDir
        }
    }
    $result = $dlg.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $selected = $dlg.FileName
    $defaultPath = Get-ToolConfigDefaultPath -RelativePath ([string]$ConfigFile.Path)
    Set-ConfigFileOverride -ToolId $ToolId -Label ([string]$ConfigFile.Label) -NewPath $selected -DefaultPath $defaultPath
    $PathBox.Text = $selected

    # If this configFile routes via paramKey, also update the corresponding parameter textbox
    $paramKey = [string]$ConfigFile.ParamKey
    if ($paramKey) {
        $paramCtl = Get-ParameterControlByKey -Key $paramKey
        if ($null -ne $paramCtl) {
            $paramCtl.Text = $selected
        }
    }
    Update-CommandPreview
}

function Update-ConfigFilesPanel {
    param($Tool)
    $ConfigFilesItems.Children.Clear()
    $files = @()
    if ($null -ne $Tool -and $null -ne (Get-Member -InputObject $Tool -Name 'ConfigFiles' -ErrorAction SilentlyContinue)) {
        $files = @($Tool.ConfigFiles)
    }
    if ($files.Count -eq 0) {
        $ConfigFilesPanel.Visibility = 'Collapsed'
        return
    }
    $toolId = [string]$Tool.Id
    $rendered = 0
    foreach ($cf in $files) {
        # paramKey config files are merged into their parameter row (Set-ParameterDefaults),
        # so they are NOT shown again here — avoids the duplicate path field.
        if ([string]$cf.ParamKey) { continue }
        $effectivePath = Get-ConfigFileEffectivePath -ToolId $toolId -ConfigFile $cf
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,0,0,4'
        $col0 = New-Object System.Windows.Controls.ColumnDefinition; $col0.Width = '110'
        $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = '*'
        $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = 'Auto'
        $col3 = New-Object System.Windows.Controls.ColumnDefinition; $col3.Width = 'Auto'
        [void]$row.ColumnDefinitions.Add($col0)
        [void]$row.ColumnDefinitions.Add($col1)
        [void]$row.ColumnDefinitions.Add($col2)
        [void]$row.ColumnDefinitions.Add($col3)

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string]$cf.Label
        $label.Style = $window.FindResource('FieldLabel')
        $label.ToolTip = $effectivePath
        [System.Windows.Controls.Grid]::SetColumn($label, 0)
        [void]$row.Children.Add($label)

        $pathBox = New-Object System.Windows.Controls.TextBox
        $pathBox.Text = $effectivePath
        $pathBox.Margin = '0,0,4,0'
        $pathBox.ToolTip = 'パスを直接入力するか、... で選択'
        [System.Windows.Controls.Grid]::SetColumn($pathBox, 1)
        [void]$row.Children.Add($pathBox)

        # Capture per-row context in closure to survive scope changes across iterations.
        $capturedToolId = $toolId
        $capturedCf = $cf
        $capturedBox = $pathBox

        $pathBox.Add_LostFocus({ param($s,$e)
            Save-ConfigBoxOverride -ToolId $capturedToolId -ConfigFile $capturedCf -Path ([string]$capturedBox.Text)
            Update-CommandPreview
        }.GetNewClosure())

        $browseBtn = New-Object System.Windows.Controls.Button
        $browseBtn.Content = '...'
        $browseBtn.Style = $window.FindResource('SmallBrowseButton')
        $browseBtn.Margin = '0,0,4,0'
        $browseBtn.ToolTip = 'エクスプローラから設定ファイルを選択'
        $browseBtn.Add_Click({ param($s,$e)
            Invoke-SelectConfigFile -ToolId $capturedToolId -ConfigFile $capturedCf -PathBox $capturedBox
        }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($browseBtn, 2)
        [void]$row.Children.Add($browseBtn)

        $openBtn = New-Object System.Windows.Controls.Button
        $openBtn.Content = '開く'
        $openBtn.MinWidth = 52
        $openBtn.ToolTip = '関連付けエディタで開く（未存在なら作成の可否を確認）'
        $openBtn.Add_Click({ param($s,$e)
            Open-ConfigFileInEditor -FullPath ([string]$capturedBox.Text)
        }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($openBtn, 3)
        [void]$row.Children.Add($openBtn)

        [void]$ConfigFilesItems.Children.Add($row)
        $rendered++
    }
    if ($rendered -gt 0) {
        $ConfigFilesPanel.Visibility = 'Visible'
    } else {
        $ConfigFilesPanel.Visibility = 'Collapsed'
    }
}

function Update-SelectedTool {
    $tool = Get-SelectedTool
    $script:CurrentTool = $tool
    if ($null -eq $tool) {
        $ConfigFilesPanel.Visibility = 'Collapsed'
        return
    }
    $ToolTitleText.Text = "{0} ({1})" -f $tool.Name, $tool.Id
    $ToolDescriptionText.Text = $tool.Description
    Set-ParameterDefaults -Tool $tool
    Update-ConfigFilesPanel -Tool $tool
    Update-CommandPreview
}

function Set-ParameterDefaults {
    # Build the parameter panel dynamically:
    #   - text params   : full-width row (label + box); paramKey configs also get [...] [開く]
    #   - number params : compact fields packed into a WrapPanel (auto-wraps ~3/row)
    #   - checkbox      : packed into a WrapPanel
    param($Tool)
    $script:TextParameterControls = @()
    $script:CheckParameterControls = @()
    $script:SelectParameterControls = @()
    $ParametersItems.Children.Clear()
    $sampleRun = Join-Path (Join-Path $script:OutputRoot $Tool.Id) '<timestamp>'
    $toolId = [string]$Tool.Id
    $paramCfgMap = Get-ParamConfigFileMap -Tool $Tool

    # Categorize params: full-width text rows, compact fields (numbers + short text
    # packed into a WrapPanel), and checkboxes.
    $textParams = @()
    $compactFields = @()   # @{ Param; BoxWidth }
    $checkParams = @()
    foreach ($p in @($Tool.Parameters)) {
        $type = [string]$p.Type
        if ($type -eq 'hidden') { continue }
        if ($type -eq 'checkbox') { $checkParams += $p; continue }
        if ($type -eq 'number') { $compactFields += @{ Param = $p; BoxWidth = 64 }; continue }
        if ([string]$p.Width -eq 'short') { $compactFields += @{ Param = $p; BoxWidth = 150 }; continue }
        $textParams += $p
    }

    # --- text params (full-width rows) ---
    foreach ($p in $textParams) {
        $key = [string]$p.Key
        $cf = $null
        if ($paramCfgMap.ContainsKey($key)) { $cf = $paramCfgMap[$key] }
        if ($null -ne $cf) {
            $initial = Get-ConfigFileEffectivePath -ToolId $toolId -ConfigFile $cf
        } else {
            $initial = Expand-LauncherValue -Value ([string]$p.Default) -Tool $Tool -RunDir $sampleRun
        }

        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,0,0,4'
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = '110'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
        [void]$row.ColumnDefinitions.Add($c0)
        [void]$row.ColumnDefinitions.Add($c1)

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string]$p.Label
        $label.Style = $window.FindResource('FieldLabel')
        [System.Windows.Controls.Grid]::SetColumn($label, 0)
        [void]$row.Children.Add($label)

        $box = New-Object System.Windows.Controls.TextBox
        $box.Text = $initial
        [System.Windows.Controls.Grid]::SetColumn($box, 1)
        $box.Add_TextChanged({ Update-CommandPreview })
        [void]$row.Children.Add($box)

        if ($null -ne $cf) {
            $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
            $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
            [void]$row.ColumnDefinitions.Add($c2)
            [void]$row.ColumnDefinitions.Add($c3)
            $box.Margin = '0,0,4,0'
            $box.ToolTip = 'パスを直接入力するか、... で選択'
            $capToolId = $toolId
            $capCf = $cf
            $capBox = $box
            $box.Add_LostFocus({ param($s,$e)
                Save-ConfigBoxOverride -ToolId $capToolId -ConfigFile $capCf -Path ([string]$capBox.Text)
            }.GetNewClosure())

            $browseBtn = New-Object System.Windows.Controls.Button
            $browseBtn.Content = '...'
            $browseBtn.Style = $window.FindResource('SmallBrowseButton')
            $browseBtn.Margin = '0,0,4,0'
            $browseBtn.ToolTip = 'エクスプローラから設定ファイルを選択'
            $browseBtn.Add_Click({ param($s,$e)
                Invoke-SelectConfigFile -ToolId $capToolId -ConfigFile $capCf -PathBox $capBox
            }.GetNewClosure())
            [System.Windows.Controls.Grid]::SetColumn($browseBtn, 2)
            [void]$row.Children.Add($browseBtn)

            $openBtn = New-Object System.Windows.Controls.Button
            $openBtn.Content = '開く'
            $openBtn.MinWidth = 52
            $openBtn.ToolTip = '関連付けエディタで開く（未存在なら作成の可否を確認）'
            $openBtn.Add_Click({ param($s,$e)
                Open-ConfigFileInEditor -FullPath ([string]$capBox.Text)
            }.GetNewClosure())
            [System.Windows.Controls.Grid]::SetColumn($openBtn, 3)
            [void]$row.Children.Add($openBtn)
        }

        [void]$ParametersItems.Children.Add($row)
        $script:TextParameterControls += [pscustomobject]@{ Parameter = $p; Control = $box }
    }

    # --- compact fields: numbers + short text + select (WrapPanel auto-wraps) ---
    if ($compactFields.Count -gt 0) {
        $wrap = New-Object System.Windows.Controls.WrapPanel
        $wrap.Margin = '0,0,0,4'
        foreach ($cfld in $compactFields) {
            $p = $cfld.Param
            $cell = New-Object System.Windows.Controls.StackPanel
            $cell.Orientation = 'Horizontal'
            $cell.Margin = '0,0,18,4'
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = [string]$p.Label
            $lbl.Style = $window.FindResource('FieldLabel')
            $lbl.Margin = '0,0,6,0'
            [void]$cell.Children.Add($lbl)
            if ([string]$p.Type -eq 'select') {
                $box = New-Object System.Windows.Controls.ComboBox
                $box.Width = [double]$cfld.BoxWidth
                $opts = @(([string]$p.Options) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $box.ItemsSource = $opts
                $defaultVal = [string]$p.Default
                if ($opts -contains $defaultVal) {
                    $box.SelectedItem = $defaultVal
                } elseif ($opts.Count -gt 0) {
                    $box.SelectedIndex = 0
                }
                $box.Add_SelectionChanged({ Update-CommandPreview })
                [void]$cell.Children.Add($box)
                $script:SelectParameterControls += [pscustomobject]@{ Parameter = $p; Control = $box }
            } else {
                $box = New-Object System.Windows.Controls.TextBox
                $box.Width = [double]$cfld.BoxWidth
                $box.Text = Expand-LauncherValue -Value ([string]$p.Default) -Tool $Tool -RunDir $sampleRun
                $box.Add_TextChanged({ Update-CommandPreview })
                [void]$cell.Children.Add($box)
                $script:TextParameterControls += [pscustomobject]@{ Parameter = $p; Control = $box }
            }
            [void]$wrap.Children.Add($cell)
        }
        [void]$ParametersItems.Children.Add($wrap)
    }

    # --- checkboxes (WrapPanel) ---
    if ($checkParams.Count -gt 0) {
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($p in $checkParams) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = [string]$p.Label
            $cb.Margin = '0,0,18,0'
            $cb.IsChecked = (([string]$p.Default) -eq 'true')
            $cb.Add_Checked({ Update-CommandPreview })
            $cb.Add_Unchecked({ Update-CommandPreview })
            [void]$wrap.Children.Add($cb)
            $script:CheckParameterControls += [pscustomobject]@{ Parameter = $p; Control = $cb }
        }
        [void]$ParametersItems.Children.Add($wrap)
    }
}

function Update-CommandPreview {
    try {
        $tool = if ($script:CurrentTool) { $script:CurrentTool } else { Get-SelectedTool }
        if ($null -eq $tool) {
            $CommandPreviewTextBox.Text = ''
            return
        }
        $sampleRun = Join-Path (Join-Path $script:OutputRoot $tool.Id) '<timestamp>'
        $cmd = Build-Command -Tool $tool -RunDir $sampleRun
        $CommandPreviewTextBox.Text = $cmd.Preview
        Update-Header
    } catch {
        $CommandPreviewTextBox.Text = "# 入力チェック中: $($_.Exception.Message)"
    }
}

function Disable-RunButtons {
    $RunButton.IsEnabled = $false
    if ($null -ne $RunCollectSnapshotButton) { $RunCollectSnapshotButton.IsEnabled = $false }
    if ($null -ne $RunSnapshotReportButton) { $RunSnapshotReportButton.IsEnabled = $false }
    if ($null -ne $StopButton) { $StopButton.IsEnabled = $true }
    if ($null -ne $RunProgressBar) { $RunProgressBar.Visibility = 'Visible' }
}

function Enable-RunButtons {
    $RunButton.IsEnabled = $true
    if ($null -ne $RunCollectSnapshotButton) { $RunCollectSnapshotButton.IsEnabled = $true }
    if ($null -ne $RunSnapshotReportButton) { $RunSnapshotReportButton.IsEnabled = $true }
    if ($null -ne $StopButton) { $StopButton.IsEnabled = $false }
    if ($null -ne $RunProgressBar) { $RunProgressBar.Visibility = 'Collapsed' }
}

function Open-RunReportIfEnabled {
    # 成果物フォルダ内の HTML レポートを自動で開く(設定 OpenReportAfterRun)。
    # カタログ規約でツールは {ArtifactsDir} に HTML を出力するため、ツール側の対応は不要。
    # ExitCode 非 0 でも開く: ops ツールの非 0 は「チェック NG 検出」を含み、
    # そのときこそレポートを確認したいため(レポートが無ければ何もしない)。
    param([string]$RunDir, [string]$ExitCode)
    if (-not (Get-ConfigBool -Config $script:LoadedConfig -Name 'OpenReportAfterRun' -DefaultValue $true)) { return }
    $artifactsDir = Get-ArtifactsDir -RunDir $RunDir
    if (-not (Test-Path -LiteralPath $artifactsDir)) { return }
    $html = Get-ChildItem -LiteralPath $artifactsDir -Filter '*.html' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $html) { return }
    try {
        Start-Process -FilePath $html.FullName -ErrorAction Stop
        Add-LogLine "レポートを開きました: $($html.FullName)"
    } catch {
        try {
            Start-Process -FilePath 'msedge.exe' -ArgumentList $html.FullName -ErrorAction Stop
            Add-LogLine "レポートを開きました: $($html.FullName)"
        } catch {
            Add-LogLine "レポートを開けませんでした: $($html.FullName) - $($_.Exception.Message)"
        }
    }
}

function Test-Running {
    if ($null -ne $script:CurrentHandle -and -not $script:CurrentHandle.IsCompleted) { return $true }
    if ($null -ne $script:CurrentProc) {
        try { if (-not $script:CurrentProc.HasExited) { return $true } } catch { }
    }
    return $false
}

function Invoke-ToolExecution {
    param(
        $Tool,
        [string[]]$ToolArgsOverride = $null,
        [scriptblock]$ToolArgsFactory = $null
    )
    $tool = $Tool
    if ($null -eq $tool) {
        [System.Windows.MessageBox]::Show('ツールを選択してください。', 'ツールランチャー') | Out-Null
        return
    }
    if (Test-Running) {
        [System.Windows.MessageBox]::Show('既に実行中のツールがあります。停止してから再実行してください。', 'ツールランチャー') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $script:ToolsRoot)) {
        [System.Windows.MessageBox]::Show('ツールルートが存在しません。設定からパスを確認してください。', 'ツールランチャー') | Out-Null
        return
    }
    $runDir = New-RunDirectory -ToolId $tool.Id
    $script:LastRunDir = $runDir
    $stdoutPath = Join-Path $runDir 'stdout.log'
    $stderrPath = Join-Path $runDir 'stderr.log'
    $exitPath = Join-Path $runDir 'exit-code.txt'
    $commandPath = Join-Path $runDir 'command.txt'

    try {
        if ($null -ne $ToolArgsFactory) {
            $ToolArgsOverride = & $ToolArgsFactory $runDir
        }
        $cmd = Build-Command -Tool $tool -RunDir $runDir -ToolArgsOverride $ToolArgsOverride -RequireEntry
    } catch {
        $_.Exception.Message | Set-Content -LiteralPath $stderrPath -Encoding UTF8
        '999' | Set-Content -LiteralPath $exitPath -Encoding ASCII
        Add-LogLine "ERROR: $($_.Exception.Message)"
        Set-Status "エラー: $($_.Exception.Message)"
        return
    }

    $cmd.Preview | Set-Content -LiteralPath $commandPath -Encoding UTF8
    Add-LogLine "=== $($tool.Name) ==="
    Add-LogLine $cmd.Preview
    Set-Status "実行中: $($tool.Name)"
    Disable-RunButtons

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmd.FileName
        $psi.Arguments = $cmd.ArgumentString
        $psi.WorkingDirectory = $cmd.WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Console]::OutputEncoding
        $psi.StandardErrorEncoding = [Console]::OutputEncoding

        # Route configFile env-var overrides (e.g. _OPS_MW_CONF / _OPS_FILELIST_CONF)
        foreach ($kv in (Get-ConfigFileEnvVars -Tool $tool).GetEnumerator()) {
            $psi.EnvironmentVariables[$kv.Key] = $kv.Value
        }

        $proc = [System.Diagnostics.Process]::Start($psi)

        $rs = [RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('childProc', $proc)
        $rs.SessionStateProxy.SetVariable('stdoutPath', $stdoutPath)
        $rs.SessionStateProxy.SetVariable('stderrPath', $stderrPath)
        $rs.SessionStateProxy.SetVariable('exitPath', $exitPath)

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            try {
                $stdoutTask = $childProc.StandardOutput.ReadToEndAsync()
                $stderrTask = $childProc.StandardError.ReadToEndAsync()
                $childProc.WaitForExit()
                $stdout = $stdoutTask.Result
                $stderr = $stderrTask.Result
                Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding UTF8
                Set-Content -LiteralPath $stderrPath -Value $stderr -Encoding UTF8
                Set-Content -LiteralPath $exitPath -Value ([string]$childProc.ExitCode) -Encoding ASCII
            } catch {
                Set-Content -LiteralPath $stderrPath -Value $_.Exception.Message -Encoding UTF8
                Set-Content -LiteralPath $exitPath -Value '999' -Encoding ASCII
            }
        })

        $script:CurrentProc = $proc
        $script:CurrentRunspace = $rs
        $script:CurrentPowerShell = $ps
        $script:CurrentHandle = $ps.BeginInvoke()
        $script:CurrentRunCtx = [pscustomobject]@{
            ToolName = $tool.Name
            ToolId = $tool.Id
            RunDir = $runDir
            StdoutPath = $stdoutPath
            StderrPath = $stderrPath
            ExitPath = $exitPath
        }

        $script:WaitTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:WaitTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:WaitTimer.Add_Tick({ Watch-RunningProcess })
        $script:WaitTimer.Start()
    } catch {
        $_.Exception.Message | Set-Content -LiteralPath $stderrPath -Encoding UTF8
        '999' | Set-Content -LiteralPath $exitPath -Encoding ASCII
        Add-LogLine "ERROR: $($_.Exception.Message)"
        Set-Status "エラー: $($_.Exception.Message)"
        $script:CurrentProc = $null
        $script:CurrentRunCtx = $null
        $script:CurrentRunspace = $null
        $script:CurrentPowerShell = $null
        $script:CurrentHandle = $null
        Enable-RunButtons
    }
}

function Watch-RunningProcess {
    if ($null -eq $script:CurrentHandle) {
        if ($null -ne $script:WaitTimer) { $script:WaitTimer.Stop(); $script:WaitTimer = $null }
        return
    }
    if ($script:CurrentHandle.IsCompleted) {
        Complete-ToolExecution
    }
}

function Complete-ToolExecution {
    if ($null -ne $script:WaitTimer) {
        $script:WaitTimer.Stop()
        $script:WaitTimer = $null
    }
    $ctx = $script:CurrentRunCtx
    $ps = $script:CurrentPowerShell
    $handle = $script:CurrentHandle
    $rs = $script:CurrentRunspace
    $proc = $script:CurrentProc
    try {
        if ($null -ne $ps -and $null -ne $handle) {
            try { [void]$ps.EndInvoke($handle) } catch { }
        }
        if ($null -ne $ctx) {
            $exitCode = '?'
            if (Test-Path -LiteralPath $ctx.ExitPath) {
                $exitCode = (Get-Content -LiteralPath $ctx.ExitPath -Raw).Trim()
            }
            if (Test-Path -LiteralPath $ctx.StdoutPath) {
                $stdout = (Get-Content -LiteralPath $ctx.StdoutPath -Raw -Encoding UTF8)
                if ($stdout) { Add-LogLine $stdout.TrimEnd() }
            }
            if (Test-Path -LiteralPath $ctx.StderrPath) {
                $stderr = (Get-Content -LiteralPath $ctx.StderrPath -Raw -Encoding UTF8)
                if ($stderr) { Add-LogLine $stderr.TrimEnd() }
            }
            Add-LogLine "ExitCode: $exitCode"
            if ($exitCode -eq '0') {
                Set-Status "完了: ExitCode 0 / $($ctx.RunDir)"
            }
            else {
                # 非 0 はツールにより「チェック NG 検出」(cert-check / port-inventory 等) と
                # 実行エラーの両方があり得るため、「失敗」と断定しない表現にする
                Set-Status "終了: ExitCode $exitCode / $($ctx.RunDir)(NG 検出またはエラー。ログとレポートを確認してください)"
            }
            Open-RunReportIfEnabled -RunDir $ctx.RunDir -ExitCode $exitCode
            if ($ctx.ToolId -eq 'collect-snapshot' -and $null -ne $SnapshotZipTextBox) {
                $artifactsDir = Join-Path $ctx.RunDir 'artifacts'
                if (Test-Path -LiteralPath $artifactsDir) {
                    $producedZip = Get-ChildItem -LiteralPath $artifactsDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($null -ne $producedZip) {
                        $SnapshotZipTextBox.Text = $producedZip.FullName
                        Add-LogLine "出力対象ZIPに自動設定: $($producedZip.FullName)"
                    }
                }
            }
        }
    } catch {
        Add-LogLine "ERROR: $($_.Exception.Message)"
        Set-Status "エラー: $($_.Exception.Message)"
    } finally {
        try { if ($null -ne $proc) { $proc.Dispose() } } catch { }
        try { if ($null -ne $ps) { $ps.Dispose() } } catch { }
        try { if ($null -ne $rs) { $rs.Close(); $rs.Dispose() } } catch { }
        $script:CurrentProc = $null
        $script:CurrentRunCtx = $null
        $script:CurrentRunspace = $null
        $script:CurrentPowerShell = $null
        $script:CurrentHandle = $null
        Enable-RunButtons
    }
}

function Invoke-StopExecution {
    if (-not (Test-Running)) { return }
    try {
        $script:CurrentProc.Kill()
        Add-LogLine "[STOP] 中断要求を送信しました。"
        Set-Status "停止中..."
    } catch {
        Add-LogLine "[STOP] 失敗: $($_.Exception.Message)"
    }
}

function Invoke-SelectedTool {
    Invoke-ToolExecution -Tool (Get-SelectedTool)
}

function Get-CollectSnapshotArguments {
    param([string]$RunDir)
    $argList = New-Object System.Collections.Generic.List[string]
    $artifacts = Get-ArtifactsDir -RunDir $RunDir
    Add-ArgumentValue -Arguments $argList -Name '-Label' -Value $SnapshotLabelTextBox.Text
    Add-ArgumentValue -Arguments $argList -Name '-Output' -Value $artifacts
    return $argList.ToArray()
}

function Get-SnapshotReportArguments {
    param([string]$RunDir)
    $zipPath = $SnapshotZipTextBox.Text.Trim()
    if (-not $zipPath) { throw '「出力対象」にレポート対象の ZIP または server-snapshot JSON を指定してください。' }
    $argList = New-Object System.Collections.Generic.List[string]
    $artifacts = Get-ArtifactsDir -RunDir $RunDir
    Add-ArgumentValue -Arguments $argList -Name '-ZipPath' -Value $zipPath
    Add-ArgumentValue -Arguments $argList -Name '-CompareWith' -Value $SnapshotCompareZipTextBox.Text
    Add-ArgumentValue -Arguments $argList -Name '-OutputDir' -Value $artifacts
    Add-SwitchValue -Arguments $argList -Name '-DiffOnly' -Enabled ([bool]$SnapshotDiffOnlyCheckBox.IsChecked)
    return $argList.ToArray()
}

function Invoke-CollectSnapshot {
    $tool = Get-ToolById -ToolId 'collect-snapshot'
    if ($null -eq $tool) {
        [System.Windows.MessageBox]::Show('collect-snapshot がカタログに見つかりません。', 'ツールランチャー') | Out-Null
        return
    }
    Invoke-ToolExecution -Tool $tool -ToolArgsFactory { param($runDir) Get-CollectSnapshotArguments -RunDir $runDir }
}

function Invoke-SnapshotReport {
    $tool = Get-ToolById -ToolId 'collect-snapshot-report'
    if ($null -eq $tool) {
        [System.Windows.MessageBox]::Show('snapshot report がカタログに見つかりません。', 'ツールランチャー') | Out-Null
        return
    }
    try {
        Invoke-ToolExecution -Tool $tool -ToolArgsFactory { param($runDir) Get-SnapshotReportArguments -RunDir $runDir }
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'ツールランチャー') | Out-Null
    }
}

function Get-PerfMonitorStartArguments {
    param([string]$RunDir, $Tool)
    $argList = New-Object System.Collections.Generic.List[string]
    [void]$argList.Add('start')
    Add-ArgumentValue -Arguments $argList -Name '-Interval' -Value $PerfIntervalTextBox.Text
    Add-ArgumentValue -Arguments $argList -Name '-Duration' -Value $PerfDurationTextBox.Text
    $artifacts = Get-ArtifactsDir -RunDir $RunDir
    Add-ArgumentValue -Arguments $argList -Name '-OutputDir' -Value $artifacts
    Add-ConfigFileArgs -Arguments $argList -Tool $Tool
    return $argList.ToArray()
}

function Get-PerfMonitorStopArguments {
    param([string]$RunDir)
    $argList = New-Object System.Collections.Generic.List[string]
    [void]$argList.Add('stop')
    [void]$argList.Add($PerfSessionDirTextBox.Text.Trim())
    return $argList.ToArray()
}

function Invoke-PerfMonitorStart {
    $tool = Get-ToolById -ToolId 'perf-monitor'
    if ($null -eq $tool) {
        [System.Windows.MessageBox]::Show('perf-monitor がカタログに見つかりません。', 'ツールランチャー') | Out-Null
        return
    }
    Invoke-ToolExecution -Tool $tool -ToolArgsFactory { param($runDir) Get-PerfMonitorStartArguments -RunDir $runDir -Tool $tool }
}

function Invoke-PerfMonitorStop {
    if (-not $PerfSessionDirTextBox.Text.Trim()) {
        [System.Windows.MessageBox]::Show('セッションディレクトリを指定してください(開始後に自動入力されます)。', 'ツールランチャー') | Out-Null
        return
    }
    $tool = Get-ToolById -ToolId 'perf-monitor'
    if ($null -eq $tool) {
        [System.Windows.MessageBox]::Show('perf-monitor がカタログに見つかりません。', 'ツールランチャー') | Out-Null
        return
    }
    Invoke-ToolExecution -Tool $tool -ToolArgsFactory { param($runDir) Get-PerfMonitorStopArguments -RunDir $runDir }
}

function Select-FolderDialog {
    param([string]$InitialPath, [string]$Description)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $folder = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($Description) { $folder.Description = $Description }
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) {
        $folder.SelectedPath = $InitialPath
    }
    $result = $folder.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folder.SelectedPath
    }
    return $null
}

function Select-FileDialog {
    param([string]$InitialPath, [string]$Filter, [string]$Title)
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    if ($Title) { $dialog.Title = $Title }
    if ($Filter) { $dialog.Filter = $Filter }
    if ($InitialPath) {
        try {
            $dir = Split-Path -Parent $InitialPath
            if ($dir -and (Test-Path -LiteralPath $dir)) { $dialog.InitialDirectory = $dir }
            if (Test-Path -LiteralPath $InitialPath) { $dialog.FileName = $InitialPath }
        } catch { }
    }
    $result = $dialog.ShowDialog()
    if ($result) { return $dialog.FileName }
    return $null
}

function Show-SettingsDialog {
    [xml]$settingsXaml = Get-Content -LiteralPath $SettingsXamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $settingsXaml
    $dlg = [Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $window

    $tbTools = $dlg.FindName('ToolsRootTextBox')
    $tbOut = $dlg.FindName('OutputRootTextBox')
    $tbAws = $dlg.FindName('AwsProfileTextBox')
    $cbOpen = $dlg.FindName('OpenReportAfterRunCheckBox')
    $cbKeep = $dlg.FindName('KeepConsoleOpenCheckBox')
    $cfgText = $dlg.FindName('ConfigPathText')
    $btnTools = $dlg.FindName('BrowseToolsRootButton')
    $btnOut = $dlg.FindName('BrowseOutputRootButton')
    $btnCfg = $dlg.FindName('OpenConfigDirButton')
    $btnCancel = $dlg.FindName('CancelButton')
    $btnOk = $dlg.FindName('OkButton')

    $tbTools.Text = $script:ToolsRoot
    $tbOut.Text = $script:OutputRoot
    $tbAws.Text = $script:AwsProfile
    $cbOpen.IsChecked = (Get-ConfigBool -Config $script:LoadedConfig -Name 'OpenReportAfterRun' -DefaultValue $true)
    $cbKeep.IsChecked = (Get-ConfigBool -Config $script:LoadedConfig -Name 'KeepConsoleOpen' -DefaultValue $false)
    $cfgText.Text = "設定ファイル: $ConfigPath"

    $btnTools.Add_Click({
        $sel = Select-FolderDialog -InitialPath $tbTools.Text -Description 'ツールルートを選択'
        if ($sel) { $tbTools.Text = $sel }
    }.GetNewClosure())
    $btnOut.Add_Click({
        $sel = Select-FolderDialog -InitialPath $tbOut.Text -Description '出力保存先を選択'
        if ($sel) { $tbOut.Text = $sel }
    }.GetNewClosure())
    $btnCfg.Add_Click({
        if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList $ConfigDir
    })
    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())
    $btnOk.Add_Click({
        $script:ToolsRoot = $tbTools.Text.Trim()
        $script:OutputRoot = $tbOut.Text.Trim()
        $script:AwsProfile = $tbAws.Text.Trim()
        $obj = [pscustomobject]@{
            ToolsRoot = $script:ToolsRoot
            OutputRoot = $script:OutputRoot
            DefaultAwsProfile = $script:AwsProfile
            OpenReportAfterRun = [bool]$cbOpen.IsChecked
            KeepConsoleOpen = [bool]$cbKeep.IsChecked
        }
        if (-not (Test-Path -LiteralPath $ConfigDir)) {
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        }
        $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        $script:LoadedConfig = $obj
        if ($script:AwsProfile -and ([string]$HeaderAwsProfileComboBox.SelectedItem) -ne $script:AwsProfile) {
            $items = @($HeaderAwsProfileComboBox.ItemsSource)
            if ($items -notcontains $script:AwsProfile) {
                $HeaderAwsProfileComboBox.ItemsSource = @(@($script:AwsProfile) + $items)
            }
            $HeaderAwsProfileComboBox.SelectedItem = $script:AwsProfile
        }
        Set-Status "設定を保存しました: $ConfigPath"
        Update-CommandPreview
        $dlg.Close()
    }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml]$xaml = Get-Content -LiteralPath $XamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$HeaderAwsProfileComboBox = $window.FindName('HeaderAwsProfileComboBox')
$OpenOutputButton = $window.FindName('OpenOutputButton')
$OpenLogButton = $window.FindName('OpenLogButton')
$OpenSettingsButton = $window.FindName('OpenSettingsButton')
$ToolListBox = $window.FindName('ToolListBox')
$ToolTitleText = $window.FindName('ToolTitleText')
$ToolDescriptionText = $window.FindName('ToolDescriptionText')
$CommandPreviewTextBox = $window.FindName('CommandPreviewTextBox')
$LogTextBox = $window.FindName('LogTextBox')
$StatusText = $window.FindName('StatusText')
$RunButton = $window.FindName('RunButton')
$StopButton = $window.FindName('StopButton')
$RunProgressBar = $window.FindName('RunProgressBar')
$OpenLastRunButton = $window.FindName('OpenLastRunButton')
$ClearLogButton = $window.FindName('ClearLogButton')
$SnapshotLabelTextBox = $window.FindName('SnapshotLabelTextBox')
$SnapshotZipTextBox = $window.FindName('SnapshotZipTextBox')
$SnapshotCompareZipTextBox = $window.FindName('SnapshotCompareZipTextBox')
$SnapshotDiffOnlyCheckBox = $window.FindName('SnapshotDiffOnlyCheckBox')
$RunCollectSnapshotButton = $window.FindName('RunCollectSnapshotButton')
$RunSnapshotReportButton = $window.FindName('RunSnapshotReportButton')
$BrowseSnapshotZipButton = $window.FindName('BrowseSnapshotZipButton')
$BrowseSnapshotCompareZipButton = $window.FindName('BrowseSnapshotCompareZipButton')
$ConfigFilesPanel = $window.FindName('ConfigFilesPanel')
$ConfigFilesItems = $window.FindName('ConfigFilesItems')
$ParametersItems = $window.FindName('ParametersItems')
$PerfIntervalTextBox = $window.FindName('PerfIntervalTextBox')
$PerfDurationTextBox = $window.FindName('PerfDurationTextBox')
$PerfStartButton = $window.FindName('PerfStartButton')
$PerfSessionDirTextBox = $window.FindName('PerfSessionDirTextBox')
$BrowsePerfSessionDirButton = $window.FindName('BrowsePerfSessionDirButton')
$OpenPerfSessionDirButton = $window.FindName('OpenPerfSessionDirButton')
$PerfStopButton = $window.FindName('PerfStopButton')

$config = Import-LauncherConfig
$script:LoadedConfig = $config
$script:ToolsRoot = Get-ConfigValue -Config $config -Name 'ToolsRoot' -DefaultValue $DefaultToolsRoot
$script:OutputRoot = Get-ConfigValue -Config $config -Name 'OutputRoot' -DefaultValue $DefaultOutputRoot
$script:AwsProfile = Get-ConfigValue -Config $config -Name 'DefaultAwsProfile' -DefaultValue ''
$script:ConfigFileOverrides = Import-ConfigFileOverrides -Config $config

# AWS Profile は手入力ではなく ~/.aws/config のプロファイル一覧から選ぶ
# (aws-ec2-manager 本体と同じ AwsConfig.psm1 を利用。読めない場合は空リストで続行)
$profileItems = New-Object System.Collections.Generic.List[string]
try {
    Import-Module -Force (Join-Path $ScriptRoot 'AwsConfig.psm1')
    # Get-AwsProfiles は unary-comma 返しのため @() で包むと「1 要素 = 配列まるごと」になる。
    # [string[]] への代入で 1 段アンラップさせる(本体 App と同じ扱い)
    [string[]]$awsProfiles = Get-AwsProfiles
    if ($null -eq $awsProfiles) { $awsProfiles = @() }
    foreach ($p in $awsProfiles) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$profileItems.Add([string]$p) }
    }
} catch { }
if ($script:AwsProfile -and ($profileItems -notcontains $script:AwsProfile)) {
    [void]$profileItems.Insert(0, $script:AwsProfile)
}
$HeaderAwsProfileComboBox.ItemsSource = $profileItems.ToArray()
if ($script:AwsProfile) {
    $HeaderAwsProfileComboBox.SelectedItem = $script:AwsProfile
} elseif ($profileItems.Count -gt 0) {
    $HeaderAwsProfileComboBox.SelectedIndex = 0
    $script:AwsProfile = [string]$HeaderAwsProfileComboBox.SelectedItem
}

$script:Catalog = Read-ToolCatalog
$toolItems = New-Object System.Collections.Generic.List[object]
foreach ($tool in $script:Catalog) {
    if ([bool]$tool.Menu) {
        [void]$toolItems.Add([pscustomobject]@{
            Name        = [string]$tool.Name
            Id          = [string]$tool.Id
            Description = [string]$tool.Description
            Tool        = $tool
        })
    }
}
$ToolListBox.ItemsSource = $toolItems.ToArray()
if ($toolItems.Count -gt 0) { $ToolListBox.SelectedIndex = 0 }

$ToolListBox.Add_SelectionChanged({ Update-SelectedTool })
$HeaderAwsProfileComboBox.Add_SelectionChanged({
    $sel = $HeaderAwsProfileComboBox.SelectedItem
    $script:AwsProfile = if ($null -eq $sel) { '' } else { ([string]$sel).Trim() }
    Update-CommandPreview
})
$RunButton.Add_Click({ Invoke-SelectedTool })
$OpenLastRunButton.Add_Click({
    $dir = $script:LastRunDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        Set-Status 'まだ実行結果がありません(実行後に有効になります)'
        return
    }
    Start-Process explorer.exe -ArgumentList $dir
})
$ClearLogButton.Add_Click({ $LogTextBox.Clear() })
$StopButton.Add_Click({ Invoke-StopExecution })
$RunCollectSnapshotButton.Add_Click({ Invoke-CollectSnapshot })
$RunSnapshotReportButton.Add_Click({ Invoke-SnapshotReport })
$PerfStartButton.Add_Click({ Invoke-PerfMonitorStart })
$PerfStopButton.Add_Click({ Invoke-PerfMonitorStop })
$BrowsePerfSessionDirButton.Add_Click({
    $sel = Select-FolderDialog -InitialPath $PerfSessionDirTextBox.Text -Description 'セッションディレクトリを選択'
    if ($sel) {
        $PerfSessionDirTextBox.Text = $sel
        $script:LastPerfSessionDir = $sel
    }
})
$OpenPerfSessionDirButton.Add_Click({
    $dir = $PerfSessionDirTextBox.Text.Trim()
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        Set-Status 'セッションディレクトリがありません(開始後に自動入力されます)'
        return
    }
    Start-Process explorer.exe -ArgumentList $dir
})
$BrowseSnapshotZipButton.Add_Click({
    $sel = Select-FileDialog -InitialPath $SnapshotZipTextBox.Text -Filter 'Snapshot inputs|*.zip;*.json|ZIP files|*.zip|JSON files|*.json|All files|*.*' -Title 'ZIP / JSON を選択'
    if ($sel) { $SnapshotZipTextBox.Text = $sel }
})
$BrowseSnapshotCompareZipButton.Add_Click({
    $sel = Select-FileDialog -InitialPath $SnapshotCompareZipTextBox.Text -Filter 'Snapshot inputs|*.zip;*.json|ZIP files|*.zip|JSON files|*.json|All files|*.*' -Title '比較 ZIP / JSON を選択'
    if ($sel) { $SnapshotCompareZipTextBox.Text = $sel }
})
$OpenSettingsButton.Add_Click({ Show-SettingsDialog })
# ツール保存先: tools ルート (ToolsRoot) をエクスプローラで開く
$OpenOutputButton.Add_Click({
    $path = $script:ToolsRoot
    if (-not (Test-Path -LiteralPath $path)) {
        [System.Windows.MessageBox]::Show("ツール保存先が存在しません:`n$path", 'ツールランチャー') | Out-Null
        return
    }
    Start-Process explorer.exe -ArgumentList $path
})
# 出力先: 出力ルート (OutputRoot) をエクスプローラで開く
$OpenLogButton.Add_Click({
    $path = $script:OutputRoot
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList $path
})
$window.Add_Closing({
    if (Test-Running) {
        try { $script:CurrentProc.Kill() } catch {}
    }
})

Update-Header
Update-SelectedTool
Set-Status "設定ファイル: $ConfigPath"
[void]$window.ShowDialog()
