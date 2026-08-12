#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ReportSnapshot.ps1 の compare モードが python3 なしでも動くことの担保。
# 以前は compare_server_info.py 専用のラッパーで、python3 が無いと exit 10 で
# 止まっていた。現在は ServerSnapshot.ps1 の PS ネイティブ比較エンジンへ
# フォールバックする。python3 が入っていない業務端末でも差分レポートを
# 作れることが要件なので、PATH から python を隠した状態で検証する。

# python3 の有無は discovery フェーズで判定する。-Skip: の条件は discovery 時に
# 評価されるため、BeforeAll(run フェーズ)で設定した変数では効かない。
$PythonAvailable = $false
foreach ($pyCandidate in @('python3', 'python', 'py')) {
    if (Get-Command $pyCandidate -ErrorAction SilentlyContinue) { $PythonAvailable = $true; break }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ReportSnapshot = Join-Path $repoRoot 'tools\collect-snapshot\ReportSnapshot.ps1'
    $script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "rs-compare-$PID"
    if (Test-Path -LiteralPath $script:WorkDir) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # server-snapshot 形式の最小スナップショットを 2 つ用意する。
    # 差分は「サービス 1 件追加」と「パッケージのバージョン変更」の 2 点。
    function New-TestSnapshot {
        param([string]$Path, [string]$CollectedAt, [bool]$WithNewService, [string]$PkgVersion)
        $services = @(
            [ordered]@{ name = 'Spooler'; display_name = 'Print Spooler'; status = 'Running'; start_type = 'Auto' }
        )
        if ($WithNewService) {
            $services += [ordered]@{ name = 'NewSvc'; display_name = 'New Service'; status = 'Running'; start_type = 'Auto' }
        }
        $snapshot = [ordered]@{
            meta = [ordered]@{
                os_type      = 'windows'
                collected_at = $CollectedAt
                categories   = @('os', 'services', 'packages')
                hostname     = 'TESTHOST'
            }
            os = [ordered]@{
                os_name          = 'Microsoft Windows 11 Pro'
                os_build         = '22631'
                total_memory_gb  = 16.0
                reboot_pending   = $false
            }
            services = $services
            packages = @(
                [ordered]@{ name = 'SampleApp';  version = $PkgVersion; vendor = 'Contoso' }
                [ordered]@{ name = 'CommonTool'; version = '1.0.0';     vendor = 'Contoso' }
            )
        }
        $json = $snapshot | ConvertTo-Json -Depth 6
        # BOM なし UTF-8（コレクタの出力と同じ形式）
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    $script:BeforeJson = Join-Path $script:WorkDir 'before.json'
    $script:AfterJson  = Join-Path $script:WorkDir 'after.json'
    New-TestSnapshot -Path $script:BeforeJson -CollectedAt '2026-08-01T10:00:00+09:00' -WithNewService $false -PkgVersion '1.2.3'
    New-TestSnapshot -Path $script:AfterJson  -CollectedAt '2026-08-06T10:00:00+09:00' -WithNewService $true  -PkgVersion '1.3.0'

    # compare を実行して「終了コード」と「生成された HTML の中身」を返す。
    # HidePython 指定時は PATH を Windows 標準ディレクトリだけに絞り、
    # python3 / python / py が見つからない状況を再現する。
    function Invoke-CompareRun {
        param([string]$OutputDir, [switch]$HidePython, [switch]$IncludeSame)
        $savedPath = $env:PATH
        if ($HidePython) {
            $env:PATH = @(
                (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0'),
                (Join-Path $env:SystemRoot 'System32'),
                $env:SystemRoot
            ) -join ';'
        }
        try {
            $invokeArgs = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ReportSnapshot,
                '-ZipPath', $script:BeforeJson, '-CompareWith', $script:AfterJson,
                '-OutputDir', $OutputDir
            )
            if ($IncludeSame) { $invokeArgs += '-IncludeSame' }
            $stdout = & $script:PowerShellExe @invokeArgs 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally {
            $env:PATH = $savedPath
        }
        $html = Get-ChildItem -LiteralPath $OutputDir -Filter '*.html' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        return [pscustomobject]@{
            ExitCode = $exitCode
            Stdout   = $stdout
            HtmlPath = if ($html) { $html.FullName } else { '' }
            Html     = if ($html) { [System.IO.File]::ReadAllText($html.FullName) } else { '' }
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ReportSnapshot compare (python3 なし)' {
    BeforeAll {
        $script:NoPy = Invoke-CompareRun -OutputDir (Join-Path $script:WorkDir 'out-nopy') -HidePython
        $script:NoPyIncludeSame = Invoke-CompareRun -OutputDir (Join-Path $script:WorkDir 'out-nopy-all') -HidePython -IncludeSame
    }

    It 'PS ネイティブ比較エンジンへフォールバックする' {
        $script:NoPy.Stdout | Should -Match 'PowerShell (native|comparator)'
    }

    It '終了コード 0 で完了する' {
        $script:NoPy.ExitCode | Should -Be 0
    }

    It 'HTML 差分レポートを生成する' {
        $script:NoPy.HtmlPath | Should -Not -BeNullOrEmpty
        $script:NoPy.Html.Length | Should -BeGreaterThan 1000
    }

    It '追加されたサービスを差分として検出する' {
        $script:NoPy.Html | Should -Match 'NewSvc'
    }

    It '変更されたパッケージバージョンを差分として検出する' {
        $script:NoPy.Html | Should -Match '1\.3\.0'
    }

    It 'IncludeSame 指定時は一致行も HTML に含める' {
        $script:NoPyIncludeSame.Html | Should -Match "<tr class='same'>"
    }
}

Describe 'ReportSnapshot compare (python3 あり)' -Skip:(-not $PythonAvailable) {
    BeforeAll {
        $script:WithPy = Invoke-CompareRun -OutputDir (Join-Path $script:WorkDir 'out-py')
        $script:WithPyIncludeSame = Invoke-CompareRun -OutputDir (Join-Path $script:WorkDir 'out-py-all') -IncludeSame
    }

    It 'compare_server_info.py を使う' {
        $script:WithPy.Stdout | Should -Match 'compare_server_info\.py'
    }

    It 'python3 なしのときと同じ差分を検出する' {
        $script:WithPy.ExitCode | Should -Be 0
        $script:WithPy.Html | Should -Match 'NewSvc'
        $script:WithPy.Html | Should -Match '1\.3\.0'
    }

    It '既定では一致行を含めず、IncludeSame 指定時だけ含める' {
        $script:WithPy.Html | Should -Not -Match "<tr class='r-same'>"
        $script:WithPyIncludeSame.Html | Should -Match "<tr class='r-same'>"
    }
}
