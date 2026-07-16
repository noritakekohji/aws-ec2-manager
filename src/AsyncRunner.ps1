<#
.SYNOPSIS
    Event-driven async task runner for the WPF UI (PowerShell 5.1).
.DESCRIPTION
    AWS CLI などの長時間処理をバックグラウンド Runspace で実行し、
    完了・進捗を Dispatcher.BeginInvoke で UI スレッドへ push する。
    UI 側にタイマーや定期ポーリングは置かない(イベント駆動)。
    同時実行は 1 タスクのみ(直列)。
#>

Set-StrictMode -Version Latest

$script:AsyncRunnerState = [PSCustomObject]@{
    Dispatcher    = $null
    OnBusyChanged = $null
    ModulePaths   = @()
    PowerShell    = $null
    Runspace      = $null
    Handle        = $null
    Running       = $false
    TaskId        = 0
    TaskName      = ''
    OnSuccess     = $null
    OnError       = $null
    Channel       = [hashtable]::Synchronized(@{ AwsPid = 0; CancelRequested = $false })
}

function Initialize-AsyncRunner {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory initialization only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Threading.Dispatcher]$Dispatcher,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnBusyChanged = $null,

        # バックグラウンド Runspace 側で import するモジュールのフルパス
        [Parameter()]
        [AllowNull()]
        [string[]]$ModulePaths = @()
    )
    $script:AsyncRunnerState.Dispatcher = $Dispatcher
    $script:AsyncRunnerState.OnBusyChanged = $OnBusyChanged
    $script:AsyncRunnerState.ModulePaths = @($ModulePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-AsyncChannel {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:AsyncRunnerState.Channel
}

function Test-AsyncTaskRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$script:AsyncRunnerState.Running
}

function Get-AsyncTaskName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string]$script:AsyncRunnerState.TaskName
}

function Set-AsyncBusyState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI busy-state notification helper.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Busy)
    $script:AsyncRunnerState.Running = $Busy
    if ($null -ne $script:AsyncRunnerState.OnBusyChanged) {
        try { & $script:AsyncRunnerState.OnBusyChanged $Busy } catch { }
    }
}

function Clear-AsyncTaskResources {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Disposes internal runspace resources.')]
    [CmdletBinding()]
    param()
    $state = $script:AsyncRunnerState
    try { if ($null -ne $state.PowerShell) { $state.PowerShell.Dispose() } } catch { }
    try { if ($null -ne $state.Runspace) { $state.Runspace.Close(); $state.Runspace.Dispose() } } catch { }
    $state.PowerShell = $null
    $state.Runspace = $null
    $state.Handle = $null
    $state.OnSuccess = $null
    $state.OnError = $null
    $state.TaskName = ''
    $state.Channel.AwsPid = 0
    $state.Channel.CancelRequested = $false
}

function Complete-AsyncTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal completion handler.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Envelope)

    $state = $script:AsyncRunnerState
    # キャンセル等で既にクリーンアップ済みの遅延通知は無視する
    if (-not $state.Running) { return }
    if ([int]$Envelope.TaskId -ne [int]$state.TaskId) { return }

    $onSuccess = $state.OnSuccess
    $onError = $state.OnError
    Clear-AsyncTaskResources
    Set-AsyncBusyState -Busy $false

    if ($Envelope.Ok) {
        if ($null -ne $onSuccess) { & $onSuccess $Envelope.Value }
    }
    else {
        if ($null -ne $onError) { & $onError ([string]$Envelope.Error) }
    }
}

function Start-AsyncTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a background task by design.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,

        # param($Channel, $ReportProgress, ...ArgumentList) を受け取る scriptblock。
        # 背景 Runspace で実行されるため、呼び出し元スコープの変数は参照できない。
        [Parameter(Mandatory = $true)][scriptblock]$Work,

        [Parameter()][AllowNull()][object[]]$ArgumentList = @(),

        [Parameter(Mandatory = $true)][scriptblock]$OnSuccess,
        [Parameter()][AllowNull()][scriptblock]$OnError = $null,
        [Parameter()][AllowNull()][scriptblock]$OnProgress = $null
    )

    $state = $script:AsyncRunnerState
    if ($null -eq $state.Dispatcher) {
        throw 'AsyncRunner が初期化されていません。Initialize-AsyncRunner を先に呼んでください。'
    }
    if ($state.Running) { return $false }

    $state.TaskId = [int]$state.TaskId + 1
    $state.TaskName = $Name
    $state.OnSuccess = $OnSuccess
    $state.OnError = $OnError
    $state.Channel.AwsPid = 0
    $state.Channel.CancelRequested = $false

    # UI Runspace 側で delegate 化しておく(UI スレッド上で Dispatcher が実行するため、
    # Add_Click ハンドラと同じ実行機構で安全に動く)
    $completeDelegate = [System.Windows.Threading.DispatcherOperationCallback] {
        param($envelope)
        Complete-AsyncTask -Envelope $envelope
        return $null
    }
    $progressDelegate = $null
    if ($null -ne $OnProgress) {
        $progressDelegate = [System.Windows.Threading.DispatcherOperationCallback] {
            param($message)
            try { & $OnProgress $message } catch { }
            return $null
        }.GetNewClosure()
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('AsyncDispatcher', $state.Dispatcher)
    $runspace.SessionStateProxy.SetVariable('AsyncCompleteDelegate', $completeDelegate)
    $runspace.SessionStateProxy.SetVariable('AsyncProgressDelegate', $progressDelegate)
    $runspace.SessionStateProxy.SetVariable('AsyncChannel', $state.Channel)
    $runspace.SessionStateProxy.SetVariable('AsyncWorkText', $Work.ToString())
    $runspace.SessionStateProxy.SetVariable('AsyncArgumentList', @($ArgumentList))
    $runspace.SessionStateProxy.SetVariable('AsyncTaskId', $state.TaskId)
    $runspace.SessionStateProxy.SetVariable('AsyncModulePaths', @($state.ModulePaths))

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript(@'
$envelope = [PSCustomObject]@{ TaskId = $AsyncTaskId; Ok = $false; Value = $null; Error = '' }
try {
    foreach ($modulePath in @($AsyncModulePaths)) {
        Import-Module -Force $modulePath
    }
    if ((Get-Command -Name Set-AwsCliChannel -ErrorAction SilentlyContinue)) {
        Set-AwsCliChannel -Channel $AsyncChannel
    }
    $reportProgress = {
        param($message)
        if ($null -ne $AsyncProgressDelegate) {
            [void]$AsyncDispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Normal,
                $AsyncProgressDelegate,
                $message)
        }
    }
    $work = [scriptblock]::Create($AsyncWorkText)
    $workArgs = @($AsyncChannel, $reportProgress) + @($AsyncArgumentList)
    $envelope.Value = & $work @workArgs
    $envelope.Ok = $true
}
catch {
    $envelope.Ok = $false
    $errorText = ''
    if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$_.ErrorDetails.Message)) {
        $errorText = [string]$_.ErrorDetails.Message
    }
    elseif ($null -ne $_.Exception) {
        $errorText = [string]$_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = [string]$_ }
    $envelope.Error = $errorText
}
[void]$AsyncDispatcher.BeginInvoke(
    [System.Windows.Threading.DispatcherPriority]::Normal,
    $AsyncCompleteDelegate,
    $envelope)
'@)

    $state.PowerShell = $ps
    $state.Runspace = $runspace
    Set-AsyncBusyState -Busy $true
    $state.Handle = $ps.BeginInvoke()
    return $true
}

function Stop-AsyncTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-invoked cancellation.')]
    [CmdletBinding()]
    param()

    $state = $script:AsyncRunnerState
    if (-not $state.Running) { return }

    $taskName = $state.TaskName
    $state.Channel.CancelRequested = $true

    # 実行中の aws CLI 子プロセスがあれば先に落とす(WaitForExit のブロック解除)
    $awsPid = 0
    try { $awsPid = [int]$state.Channel.AwsPid } catch { $awsPid = 0 }
    if ($awsPid -gt 0) {
        try { Stop-Process -Id $awsPid -Force -ErrorAction Stop } catch { }
    }

    # パイプライン停止後は背景側から完了通知が来ないため、UI 側でクリーンアップする
    $onError = $state.OnError
    try { if ($null -ne $state.PowerShell) { $state.PowerShell.Stop() } } catch { }
    Clear-AsyncTaskResources
    Set-AsyncBusyState -Busy $false
    if ($null -ne $onError) {
        & $onError "タスク『$taskName』をキャンセルしました"
    }
}
