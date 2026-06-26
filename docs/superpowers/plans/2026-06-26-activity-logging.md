# Activity Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ユーザー操作と AWS CLI 入出力をプレーンテキストファイルに記録する作業ログ機能を追加する。

**Architecture:** `Logger.psm1` にログ書き込み責務を集約し、`AppSettings.psm1` に `LogPath` フィールドを追加。`App.ps1` の起動時にロガーを初期化し、各操作ポイントで `Write-AppLog` を呼ぶ。設定ダイアログに「ログ出力先」欄を追加。

**Tech Stack:** PowerShell 5.1、Pester 5.x（テスト）

---

## ファイル一覧

| 操作 | ファイル |
|------|----------|
| 新規作成 | `Logger.psm1` |
| 新規作成 | `tests/Logger.Tests.ps1` |
| 変更 | `AppSettings.psm1`（`LogPath` フィールド追加） |
| 変更 | `App.ps1`（ロガー初期化・各操作への `Write-AppLog` 挿入・設定ダイアログ拡張） |
| 変更 | `CHANGELOG.md` |
| 変更 | `VERSION` |

---

## Task 1: Logger.psm1 のテストを書く

**Files:**
- Create: `tests/Logger.Tests.ps1`

- [ ] **Step 1: テストファイルを作成する**

`tests/Logger.Tests.ps1` を以下の内容で作成する：

```powershell
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Logger' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\Logger.psm1')).Path
        Import-Module $script:ModulePath -Force
        $script:TmpLog = [System.IO.Path]::GetTempFileName()
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TmpLog) { Remove-Item -LiteralPath $script:TmpLog -Force }
        Remove-Module Logger -ErrorAction SilentlyContinue
    }

    Context 'Initialize-AppLogger + Write-AppLog' {
        It 'writes a line to the log file' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'INFO' -Message 'test message'
            $lines = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8
            $lines | Should -Not -BeNullOrEmpty
            $lines[-1] | Should -Match '\[INFO\] test message'
        }

        It 'includes a timestamp in the line' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'INFO' -Message 'ts check'
            $lines = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8
            $lines[-1] | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }

        It 'writes WARN level correctly' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'WARN' -Message 'warn test'
            $lines = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8
            $lines[-1] | Should -Match '\[WARN\] warn test'
        }

        It 'writes ERROR level correctly' {
            Initialize-AppLogger -LogPath $script:TmpLog
            Write-AppLog -Level 'ERROR' -Message 'err test'
            $lines = Get-Content -LiteralPath $script:TmpLog -Encoding UTF8
            $lines[-1] | Should -Match '\[ERROR\] err test'
        }

        It 'does nothing when LogPath is null' {
            Initialize-AppLogger -LogPath $null
            { Write-AppLog -Level 'INFO' -Message 'no-op' } | Should -Not -Throw
        }

        It 'does nothing when LogPath is empty string' {
            Initialize-AppLogger -LogPath ''
            { Write-AppLog -Level 'INFO' -Message 'no-op' } | Should -Not -Throw
        }

        It 'appends multiple lines' {
            $appendLog = [System.IO.Path]::GetTempFileName()
            try {
                Initialize-AppLogger -LogPath $appendLog
                Write-AppLog -Level 'INFO' -Message 'line1'
                Write-AppLog -Level 'INFO' -Message 'line2'
                $lines = Get-Content -LiteralPath $appendLog -Encoding UTF8
                ($lines | Measure-Object).Count | Should -BeGreaterOrEqual 2
            } finally {
                Remove-Item -LiteralPath $appendLog -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```powershell
Invoke-Pester -Path tests/Logger.Tests.ps1
```

期待: `Logger.psm1` が存在しないため全テスト FAIL。

---

## Task 2: Logger.psm1 を実装する

**Files:**
- Create: `Logger.psm1`

- [ ] **Step 1: Logger.psm1 を作成する**

UTF-8 BOM 付きで `Logger.psm1` を作成する（`.psm1` は BOM 付き必須）：

```powershell
<#
.SYNOPSIS
    Activity logging module for aws-ec2-manager.
.DESCRIPTION
    Write-AppLog appends timestamped lines to a log file.
    Call Initialize-AppLogger at startup with the path from AppSettings.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

$script:LogFilePath = $null

function Initialize-AppLogger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets module-scope variable only; no system state change.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $script:LogFilePath = $null
        return
    }
    $script:LogFilePath = $LogPath
}

function Write-AppLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Not using Write-Host; file append only.')]
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($null -eq $script:LogFilePath) { return }

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"

    try {
        $dir = Split-Path -Parent $script:LogFilePath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # ログ書き込み失敗はアプリ動作を止めない
    }
}

Export-ModuleMember -Function Initialize-AppLogger, Write-AppLog
```

- [ ] **Step 2: テストを実行して全 PASS を確認する**

```powershell
Invoke-Pester -Path tests/Logger.Tests.ps1
```

期待: 7 tests passed。

- [ ] **Step 3: コミットする**

```bash
git add Logger.psm1 tests/Logger.Tests.ps1
git commit -m "feat: Add Logger.psm1 with Initialize-AppLogger and Write-AppLog"
```

---

## Task 3: AppSettings.psm1 に LogPath を追加する

**Files:**
- Modify: `AppSettings.psm1`

- [ ] **Step 1: `Get-AppSettings` のデフォルト値に `LogPath = $null` を追加する**

`$defaults` の定義を変更する：

```powershell
    $defaults = [PSCustomObject]@{
        AwsConfigPath = $null
        LogPath       = $null
    }
```

- [ ] **Step 2: `Get-AppSettings` の JSON 読み込み部分に `LogPath` を追加する**

`$configPath` を読む処理の直後に追加する：

```powershell
    $logPath = $null
    if ($obj.PSObject.Properties.Name -contains 'LogPath') {
        $val = [string]$obj.LogPath
        if (-not [string]::IsNullOrWhiteSpace($val)) { $logPath = $val }
    }

    return [PSCustomObject]@{
        AwsConfigPath = $configPath
        LogPath       = $logPath
    }
```

- [ ] **Step 3: `Save-AppSettings` に `LogPath` パラメータを追加する**

```powershell
function Save-AppSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simple file write; user-driven setting persistence.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Settings is a domain-standard plural noun for a config object.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AwsConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath
    )

    $dir = Get-SettingsDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $normalizedConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($AwsConfigPath)) { $normalizedConfig = $AwsConfigPath.Trim() }

    $normalizedLog = $null
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $normalizedLog = $LogPath.Trim() }

    $obj = [PSCustomObject]@{
        AwsConfigPath = $normalizedConfig
        LogPath       = $normalizedLog
    }
    $json = $obj | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath (Get-SettingsPath) -Value $json -Encoding UTF8 -ErrorAction Stop
}
```

- [ ] **Step 4: 既存テストがまだ通ることを確認する**

```powershell
Invoke-Pester -Path tests/
```

期待: 既存テストが全 PASS。

- [ ] **Step 5: コミットする**

```bash
git add AppSettings.psm1
git commit -m "feat: Add LogPath field to AppSettings"
```

---

## Task 4: App.ps1 にロガー初期化を追加する

**Files:**
- Modify: `App.ps1`

- [ ] **Step 1: モジュールロード行に Logger を追加する**

`App.ps1` の `Import-Module` 3行の直後に追加する：

```powershell
Import-Module -Force (Join-Path $PSScriptRoot 'Logger.psm1')
```

- [ ] **Step 2: 設定読み込みブロックの直後にロガー初期化を追加する**

`$env:AWS_CONFIG_FILE = $appSettings.AwsConfigPath` の直後に追加する：

```powershell
Initialize-AppLogger -LogPath $appSettings.LogPath
Write-AppLog -Level 'INFO' -Message 'aws-ec2-manager 起動'
```

- [ ] **Step 3: アプリを起動して例外が出ないことを確認する**

```powershell
powershell -File App.ps1
```

期待: GUI が起動する。

- [ ] **Step 4: コミットする**

```bash
git add App.ps1
git commit -m "feat: Initialize logger on app startup"
```

---

## Task 5: 設定ダイアログに LogPath フィールドを追加する

**Files:**
- Modify: `App.ps1`（`Show-SettingsDialog` 関数内）

- [ ] **Step 1: XAML を拡張する**

`Show-SettingsDialog` 内の `$settingsXaml` ヒアストリングを以下に置き換える（`RowDefinition` を1行追加し、LogPath 行を追加）：

```powershell
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
```

- [ ] **Step 2: ダイアログのコントロール取得・初期値設定を更新する**

`$browseButton` / `$okButton` / `$cancelButton` の取得行を以下に置き換える：

```powershell
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
```

- [ ] **Step 3: 参照ボタンのイベントを追加する**

既存の `$browseButton.Add_Click` ブロックを `$browseConfigButton.Add_Click` にリネームしたうえで、その直後に `$browseLogButton.Add_Click` を追加する：

```powershell
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
```

- [ ] **Step 4: OK ボタンの保存処理を更新する**

`$result = $dialog.ShowDialog()` 以降の保存処理を以下に置き換える：

```powershell
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
```

- [ ] **Step 5: 設定ダイアログを開いて動作確認する**

アプリを起動し「設定」ボタンを押す。ログ出力先フィールドと参照ボタンが表示され、パスを設定して OK を押すと `settings.json` に `LogPath` が保存されていることを確認する：

```powershell
Get-Content "$env:LOCALAPPDATA\aws-ec2-manager\settings.json"
```

期待: `"LogPath": "C:\\...\\aws-ec2-manager.log"` が含まれる。

- [ ] **Step 6: コミットする**

```bash
git add App.ps1
git commit -m "feat: Add LogPath field to settings dialog"
```

---

## Task 6: 各操作に Write-AppLog を挿入する

**Files:**
- Modify: `App.ps1`

以下の表の操作に対応する `Write-AppLog` 呼び出しを追加する。

| 箇所 | 挿入タイミング | Level | メッセージ例 |
|------|--------------|-------|-------------|
| `Update-ProfileComboBox` 成功後 | プロファイル読込完了 | INFO | `"プロファイル読込: $($profiles.Length) 件"` |
| `$profileComboBox.Add_SelectionChanged` | プロファイル選択時 | INFO | `"プロファイル選択: $selected"` |
| `$checkTokenButton.Add_Click` | トークン有効時 | INFO | `"SSO トークン確認: 有効 ($selected)"` |
| `$checkTokenButton.Add_Click` | トークン無効時 | WARN | `"SSO トークン確認: 要ログイン ($selected)"` |
| `$ssoLoginButton.Add_Click` | SSO ログイン開始時 | INFO | `"SSO ログイン開始: $selected"` |
| `$refreshInstancesButton.Add_Click` | 取得完了後 | INFO | `"インスタンス取得: $($items.Count) 件 (Profile=$name)"` |
| `Invoke-InstanceAction` 確認 Yes 後 | 操作開始時 | INFO | `"インスタンス操作開始: $ActionLabel $instanceId"` |
| `Invoke-InstanceAction` 成功時 | 操作完了 | INFO | `"インスタンス操作完了: $ActionLabel $instanceId"` |
| `Invoke-InstanceAction` 失敗時 | 操作失敗 | ERROR | `"インスタンス操作失敗: $ActionLabel $instanceId"` |
| `$applySgButton.Add_Click` 適用前 | SG 適用開始 | INFO | `"SG 適用開始: $instanceId 追加=$addText 削除=$delText"` |
| `$applySgButton.Add_Click` 成功時 | SG 適用完了 | INFO | `"SG 適用完了: $instanceId"` |
| `$applySgButton.Add_Click` 失敗時 | SG 適用失敗 | ERROR | `"SG 適用失敗: $instanceId"` |
| `$runSsmButton.Add_Click` 実行確認 Yes 後 | SSM 開始 | INFO | `"SSM 実行開始: $($yaml.Name) on $($inst.InstanceId)"` |
| `$runSsmButton.Add_Click` 完了後 | SSM 完了 | INFO | `"SSM 実行完了: $($yaml.Name) on $($inst.InstanceId) Status=$($result.Status) Duration=${dur}s"` |

- [ ] **Step 1: 上表の `Write-AppLog` 呼び出しを App.ps1 の各箇所に挿入する**

各ブロックの該当行の直前または直後に `Write-AppLog -Level '...' -Message "..."` を1行追加する。

- [ ] **Step 2: アプリを起動し、いくつかの操作を行いログファイルを確認する**

設定でログパスを設定してから操作し：

```powershell
Get-Content "C:\path\to\aws-ec2-manager.log" -Encoding UTF8
```

期待: 各操作に対応する `[INFO]` / `[WARN]` / `[ERROR]` 行が追記されている。

- [ ] **Step 3: コミットする**

```bash
git add App.ps1
git commit -m "feat: Insert Write-AppLog at all user operation points"
```

---

## Task 7: AWS CLI 呼び出しのログを追加する

**Files:**
- Modify: `AwsConfig.psm1`、`AwsManager.psm1`

`Invoke-AwsCli` は Logger モジュールに直接依存させない（モジュール間の結合を避けるため）。代わりに `App.ps1` 側でラッパーを通じてログを取る方針ではなく、`Invoke-AwsCli` の戻り値に `Arguments` フィールドを追加し、呼び出し側（`App.ps1` のイベントハンドラ）で必要に応じて `Write-AppLog` する。

ただし SSM・EC2 操作は `App.ps1` から `Invoke-SsmTask` / `Get-Ec2Instances` 等を呼んでおり、その内部の `Invoke-AwsCli` の入出力が `App.ps1` から見えない。そのため **`Invoke-AwsCli` にオプショナルな `-LogCallback` ScriptBlock パラメータ**を追加し、渡された場合だけコールバックでログを書く。

- [ ] **Step 1: `AwsConfig.psm1` の `Invoke-AwsCli` に `-LogCallback` を追加する**

```powershell
function Invoke-AwsCli {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments,

        [AllowNull()]
        [scriptblock]$LogCallback = $null
    )

    $combined = & aws @Arguments 2>&1
    $exitCode = [int]$LASTEXITCODE

    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $combined) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $stderrLines.Add($item.ToString())
        } else {
            $stdoutLines.Add([string]$item)
        }
    }

    $joined       = if ($stdoutLines.Count -eq 0) { '' } else { ($stdoutLines.ToArray() -join [Environment]::NewLine) }
    $stderrJoined = if ($stderrLines.Count -eq 0)  { '' } else { ($stderrLines.ToArray()  -join [Environment]::NewLine) }

    if ($null -ne $LogCallback) {
        $argStr = ($Arguments -join ' ')
        & $LogCallback "aws $argStr"
        if (-not [string]::IsNullOrWhiteSpace($stderrJoined)) {
            & $LogCallback "[STDERR] $stderrJoined"
        }
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $joined
        Stderr   = $stderrJoined
        Success  = ($exitCode -eq 0)
    }
}
```

- [ ] **Step 2: `AwsManager.psm1` の `Invoke-AwsCli` にも同様の変更を加える**

Step 1 と同じ内容を `AwsManager.psm1` の `Invoke-AwsCli` にも適用する。

- [ ] **Step 3: `App.ps1` の `$refreshInstancesButton.Add_Click` 等の AWS CLI を呼ぶ関数呼び出し箇所で LogCallback を渡す**

`Invoke-SsmTask` / `Get-Ec2Instances` 等は `-LogCallback` を持たない（内部で `Invoke-AwsCli` を呼ぶ）ため、`App.ps1` のグローバルスコープで LogCallback スクリプトブロックを定義し、各モジュール関数に渡す代わりに `$env:` 変数経由では渡せない。

したがって、`Invoke-AwsCli` を直接呼んでいる箇所（`Test-SsoToken` が呼ぶ `Invoke-AwsCli`）に限定してログを追加し、他の操作（EC2取得・SSM実行）は Task 6 で追加した操作レベルのログで十分とする。

`AwsConfig.psm1` の `Test-SsoToken` の呼び出し側 `$checkTokenButton.Add_Click` で AWS CLI 出力をログする場合は、`Test-SsoToken` が返す bool だけでなく詳細が必要なため、以下を `$checkTokenButton.Add_Click` に追加する：

```powershell
Write-AppLog -Level 'INFO' -Message "aws sts get-caller-identity --profile $selected (result: $ok)"
```

- [ ] **Step 4: テストを実行して既存テストが通ることを確認する**

```powershell
Invoke-Pester -Path tests/
```

期待: 全テスト PASS。

- [ ] **Step 5: コミットする**

```bash
git add AwsConfig.psm1 AwsManager.psm1 App.ps1
git commit -m "feat: Add LogCallback to Invoke-AwsCli for CLI input/output logging"
```

---

## Task 8: CHANGELOG・VERSION を更新して tag を打つ

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `VERSION`

- [ ] **Step 1: `VERSION` を `0.2.0` に更新する**

```
0.2.0
```

- [ ] **Step 2: `CHANGELOG.md` の `[Unreleased]` セクションに今回の変更を追記し、`[0.2.0]` セクションを追加する**

`[Unreleased]` セクションをクリアし、`[0.1.0]` の上に以下を追加する：

```markdown
## [0.2.0] - 2026-06-26

### Added
- `Logger.psm1` モジュールを新規追加（`Initialize-AppLogger` / `Write-AppLog`）。`[yyyy-MM-dd HH:mm:ss] [LEVEL] メッセージ` 形式でプレーンテキストファイルに追記
- 設定ダイアログに「ログ出力先ファイルのパス」フィールドと参照ボタンを追加。空欄でログ無効
- `AppSettings.psm1` に `LogPath` フィールドを追加（`settings.json` に永続化）
- 操作ログ: プロファイル読込・選択、SSO トークン確認、SSO ログイン、インスタンス取得・起動・停止・再起動、SG 適用、SSM タスク実行の各操作を INFO/WARN/ERROR レベルで記録
- 設定変更時にログを再初期化するため、アプリ再起動なしにログパスを変更可能
```

- [ ] **Step 3: コミットして tag を打つ**

```bash
git add CHANGELOG.md VERSION
git commit -m "chore: Bump version to 0.2.0"
git tag v0.2.0
```

- [ ] **Step 4: GitHub へ push する**

```bash
git push origin main
git push --tags
```

---
