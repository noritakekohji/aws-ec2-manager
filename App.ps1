<#
.SYNOPSIS
    aws-ec2-manager WPF entry point (v2: master/detail + async).
.DESCRIPTION
    モジュールと XAML を読み込み、src/*.ps1 を dot-source して各ペインを配線する。
    AWS CLI 呼び出しはすべて AsyncRunner(src/AsyncRunner.ps1)経由で
    バックグラウンド実行され、UI はブロックされない。
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

$script:AppRoot = $PSScriptRoot

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
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# ContentRendered 前はプロファイル選択イベントからの自動取得を抑止する
$script:AppInitialized = $false

#----------------------------------------------------------------------
# 各パートの読み込み(順序依存: 基盤 → 共通 UI → ペイン)
#----------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'src\AsyncRunner.ps1')
. (Join-Path $PSScriptRoot 'src\AppState.ps1')
. (Join-Path $PSScriptRoot 'src\UiCommon.ps1')

$window.Dispatcher.add_UnhandledException({
        param($sender, $eventArgs)
        $message = [string]$eventArgs.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$eventArgs.Exception }
        if ([string]::IsNullOrWhiteSpace($message)) { $message = '詳細のない UI エラーが発生しました。' }
        Set-StatusText -Message "UI エラー: $message"
        Write-AppLog -Level 'ERROR' -Message "未処理 UI エラー: $message"
        $eventArgs.Handled = $true
    })

# AppState: ロック永続化は AppSettings 経由
Initialize-AppState -LockedInstanceIds $appSettings.LockedInstanceIds -PersistLocks {
    param($ids)
    $current = Get-AppSettings
    Save-AppSettings -AwsConfigPath $current.AwsConfigPath -LogPath $current.LogPath -LockedInstanceIds $ids
}

# AsyncRunner: 完了/進捗はイベント駆動で UI へ push される(UI 側タイマーなし)
Initialize-AsyncRunner -Dispatcher $window.Dispatcher -OnBusyChanged {
    param($busy)
    Set-UiBusy -Busy ([bool]$busy)
} -ModulePaths @(
    (Join-Path $PSScriptRoot 'AwsManager.psm1'),
    (Join-Path $PSScriptRoot 'AwsConfig.psm1')
)

. (Join-Path $PSScriptRoot 'src\HeaderPane.ps1')
. (Join-Path $PSScriptRoot 'src\InstanceListPane.ps1')
. (Join-Path $PSScriptRoot 'src\DetailTab.ps1')
. (Join-Path $PSScriptRoot 'src\SgTab.ps1')
. (Join-Path $PSScriptRoot 'src\RoleTab.ps1')
. (Join-Path $PSScriptRoot 'src\SsmTab.ps1')

#----------------------------------------------------------------------
# 右ペインのタブ切替: アクティブになったタブを選択インスタンスに追従させる
#----------------------------------------------------------------------
$detailTabsControl = Find-Control -Name 'DetailTabs'
$detailTabsControl.Add_SelectionChanged({
        param($sender, $eventArgs)
        # ListBox 等の子コントロールから SelectionChanged がバブルしてくるため発生元を確認する
        if (-not [object]::ReferenceEquals($eventArgs.Source, $detailTabsControl)) { return }
        try {
            switch ($detailTabsControl.SelectedIndex) {
                1 { Update-SgTabForSelection }
                2 { Update-RoleTabForSelection }
                3 { Update-SsmTabForSelection }
            }
        }
        catch {
            Set-StatusText -Message "タブ切替エラー: $($_.Exception.Message)"
        }
    })

#----------------------------------------------------------------------
# 起動処理
#----------------------------------------------------------------------
Update-ProfileComboBox

$window.Add_ContentRendered({
        try {
            $script:AppInitialized = $true
            if (-not $script:AppState.HasLoaded) {
                Update-InstanceListAsync
            }
        }
        catch {
            Set-StatusText -Message "初回インスタンス取得エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "初回インスタンス取得エラー: $($_.Exception.Message)"
        }
    })

$window.ShowDialog() | Out-Null
