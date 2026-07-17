#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# AsyncRunner はイベント駆動(Dispatcher.BeginInvoke による push)で完了を通知する。
# テストは STA スレッドの CurrentDispatcher + DispatcherFrame ポンプで検証する。

Describe 'AsyncRunner' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, WindowsBase | Out-Null
        . (Join-Path $PSScriptRoot '..\src\AsyncRunner.ps1')

        function Wait-ForCondition {
            param(
                [Parameter(Mandatory = $true)][scriptblock]$Condition,
                [int]$TimeoutSec = 15
            )
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while (-not (& $Condition)) {
                if ((Get-Date) -gt $deadline) { return $false }
                $frame = New-Object System.Windows.Threading.DispatcherFrame
                [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Background,
                    [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null },
                    $frame)
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Start-Sleep -Milliseconds 50
            }
            return $true
        }
    }

    BeforeEach {
        $script:testSink = @{
            Success   = $null
            ErrorText = $null
            Progress  = New-Object System.Collections.Generic.List[string]
            Busy      = New-Object System.Collections.Generic.List[bool]
            Done      = $false
        }
        Initialize-AsyncRunner -Dispatcher ([System.Windows.Threading.Dispatcher]::CurrentDispatcher) -OnBusyChanged {
            param($busy)
            $script:testSink.Busy.Add([bool]$busy)
        }
    }

    It 'runs Work in background and pushes the result to OnSuccess' {
        $started = Start-AsyncTask -Name 'add' -Work {
            param($Channel, $ReportProgress, $a, $b)
            return $a + $b
        } -ArgumentList @(2, 3) -OnSuccess {
            param($result)
            $script:testSink.Success = $result
            $script:testSink.Done = $true
        } -OnError {
            param($err)
            $script:testSink.ErrorText = [string]$err
            $script:testSink.Done = $true
        }

        $started | Should -BeTrue
        (Wait-ForCondition { $script:testSink.Done }) | Should -BeTrue
        $script:testSink.ErrorText | Should -BeNullOrEmpty
        $script:testSink.Success | Should -Be 5
    }

    It 'pushes Work failure to OnError' {
        $null = Start-AsyncTask -Name 'boom' -Work {
            param($Channel, $ReportProgress)
            throw 'boom-error'
        } -OnSuccess {
            param($result)
            $script:testSink.Success = 'unexpected'
            $script:testSink.Done = $true
        } -OnError {
            param($err)
            $script:testSink.ErrorText = [string]$err
            $script:testSink.Done = $true
        }

        (Wait-ForCondition { $script:testSink.Done }) | Should -BeTrue
        $script:testSink.Success | Should -BeNullOrEmpty
        $script:testSink.ErrorText | Should -Match 'boom-error'
    }

    It 'rejects a second task while one is running' {
        $null = Start-AsyncTask -Name 'slow' -Work {
            param($Channel, $ReportProgress)
            Start-Sleep -Seconds 3
            return 'slow-done'
        } -OnSuccess {
            param($result)
            $script:testSink.Success = $result
            $script:testSink.Done = $true
        }

        Test-AsyncTaskRunning | Should -BeTrue
        $second = Start-AsyncTask -Name 'second' -Work { param($c, $r) 1 } -OnSuccess { param($result) }
        $second | Should -BeFalse

        (Wait-ForCondition { $script:testSink.Done }) | Should -BeTrue
        $script:testSink.Success | Should -Be 'slow-done'
        Test-AsyncTaskRunning | Should -BeFalse
    }

    It 'pushes progress messages to OnProgress in order' {
        $null = Start-AsyncTask -Name 'progress' -Work {
            param($Channel, $ReportProgress)
            & $ReportProgress 'step1'
            & $ReportProgress 'step2'
            return 'ok'
        } -OnSuccess {
            param($result)
            $script:testSink.Done = $true
        } -OnProgress {
            param($message)
            $script:testSink.Progress.Add([string]$message)
        }

        (Wait-ForCondition { $script:testSink.Done }) | Should -BeTrue
        @($script:testSink.Progress) -join ',' | Should -Be 'step1,step2'
    }

    It 'notifies OnBusyChanged true then false' {
        $null = Start-AsyncTask -Name 'busy' -Work { param($c, $r) 'x' } -OnSuccess {
            param($result)
            $script:testSink.Done = $true
        }
        (Wait-ForCondition { $script:testSink.Done }) | Should -BeTrue
        (Wait-ForCondition { -not (Test-AsyncTaskRunning) }) | Should -BeTrue
        @($script:testSink.Busy)[0] | Should -BeTrue
        @($script:testSink.Busy)[-1] | Should -BeFalse
    }

    It 'Stop-AsyncTask cancels a running task and reports via OnError' {
        $null = Start-AsyncTask -Name 'cancelme' -Work {
            param($Channel, $ReportProgress)
            Start-Sleep -Seconds 60
            return 'never'
        } -OnSuccess {
            param($result)
            $script:testSink.Success = 'unexpected'
            $script:testSink.Done = $true
        } -OnError {
            param($err)
            $script:testSink.ErrorText = [string]$err
            $script:testSink.Done = $true
        }

        Test-AsyncTaskRunning | Should -BeTrue
        Start-Sleep -Milliseconds 300
        Stop-AsyncTask

        (Wait-ForCondition { $script:testSink.Done }) | Should -BeTrue
        $script:testSink.Success | Should -BeNullOrEmpty
        $script:testSink.ErrorText | Should -Match 'キャンセル'
        Test-AsyncTaskRunning | Should -BeFalse
    }

    It 'exposes a synchronized channel with AwsPid and CancelRequested' {
        $channel = Get-AsyncChannel
        $channel.ContainsKey('AwsPid') | Should -BeTrue
        $channel.ContainsKey('CancelRequested') | Should -BeTrue
    }

    It 'can run tasks repeatedly after completion' {
        foreach ($i in 1..2) {
            $script:testSink.Done = $false
            $null = Start-AsyncTask -Name "run$i" -Work { param($c, $r, $v) $v * 10 } -ArgumentList @($i) -OnSuccess {
                param($result)
                $script:testSink.Success = $result
                $script:testSink.Done = $true
            }
            (Wait-ForCondition { $script:testSink.Done }) | Should -BeTrue
        }
        $script:testSink.Success | Should -Be 20
    }
}
