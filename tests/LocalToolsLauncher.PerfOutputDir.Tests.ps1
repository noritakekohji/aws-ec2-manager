#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# perf-monitor の出力先(-OutputDir)解決ロジックのテスト。
# ランチャーは「セッション」欄の指定に応じて出力先を切り替える:
#   - 空欄            → 実行ごとの {ArtifactsDir}(従来動作)
#   - セッション自体   → その親(新しいセッションが既存セッションの隣に並ぶ)
#   - 束ねフォルダ     → そのフォルダ自体
# ここを誤ると start のたびにセッションが別の場所へ散らばるため、回帰を検知する。

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $launcherPath = Join-Path $repoRoot 'LocalToolsLauncher.ps1'

    # LocalToolsLauncher.ps1 は末尾で WPF ウィンドウを起動するため、そのまま
    # dot-source するとテストが GUI を開いてしまう。GUI 起動部の直前までを
    # 一時ファイルへ切り出して関数定義だけを読み込む。
    $lines = Get-Content -LiteralPath $launcherPath -Encoding UTF8
    $cutLine = ($lines | Select-String -Pattern '^Add-Type -AssemblyName PresentationFramework' |
        Select-Object -First 1).LineNumber
    if (-not $cutLine) { throw "GUI 起動部の目印が見つかりません: $launcherPath" }
    $script:FunctionsOnlyPath = Join-Path ([System.IO.Path]::GetTempPath()) "lt-funcs-$PID.ps1"
    # .ps1 は UTF-8 BOM 付きで書く(CP932 環境で日本語コメントが壊れるのを防ぐ)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($script:FunctionsOnlyPath, $lines[0..($cutLine - 2)], $utf8Bom)
    . $script:FunctionsOnlyPath

    $CatalogPath = Join-Path $repoRoot 'tools\tool-catalog.yaml'
    $script:ToolsRoot = Join-Path $repoRoot 'tools'
    $script:OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) "lt-out-$PID"
    $script:AwsProfile = ''
    $script:ConfigFileOverrides = @{}
    $script:PerfTool = @(Read-ToolCatalog) | Where-Object { $_.Id -eq 'perf-monitor' }

    # フィクスチャ: セッション / 束ねフォルダ / 存在しないパス
    $script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "lt-fixtures-$PID"
    if (Test-Path -LiteralPath $script:FixtureRoot) {
        Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force
    }
    $script:SessionsRoot = Join-Path $script:FixtureRoot 'sessions'
    $script:SessionWithConf = Join-Path $script:SessionsRoot 'perf_20260806-100000'
    $script:SessionWithData = Join-Path $script:SessionsRoot 'perf_20260806-110000'
    $script:PlainDir = Join-Path $script:FixtureRoot 'plain'
    $script:MissingDir = Join-Path $script:FixtureRoot 'does-not-exist'
    New-Item -ItemType Directory -Path $script:SessionWithConf -Force | Out-Null
    New-Item -ItemType Directory -Path $script:SessionWithData -Force | Out-Null
    New-Item -ItemType Directory -Path $script:PlainDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:SessionWithConf 'session.conf') -Value 'Interval = 5' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:SessionWithData 'data.jsonl') -Value '{}' -Encoding UTF8

    # 「セッション」欄の入力を差し替えるヘルパー(WPF コントロールの代わりに
    # Text / SelectedItem プロパティを持つオブジェクトを渡す)
    function Set-SessionInput {
        param([string]$SessionValue, [string]$Command = 'start')
        $script:TextParameterControls = @(
            [pscustomobject]@{
                Parameter = [pscustomobject]@{ Key = 'sessionDir' }
                Control   = [pscustomobject]@{ Text = $SessionValue }
            }
        )
        $script:SelectParameterControls = @(
            [pscustomobject]@{
                Parameter = [pscustomobject]@{ Key = 'command' }
                Control   = [pscustomobject]@{ SelectedItem = $Command }
            }
        )
        $script:CheckParameterControls = @()
    }
}

AfterAll {
    if ($script:FixtureRoot -and (Test-Path -LiteralPath $script:FixtureRoot)) {
        Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:FunctionsOnlyPath -and (Test-Path -LiteralPath $script:FunctionsOnlyPath)) {
        Remove-Item -LiteralPath $script:FunctionsOnlyPath -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-PerfMonitorOutputDir' {
    It 'セッション欄が空なら $null を返す（呼び出し側がカタログ既定を使う）' {
        Set-SessionInput -SessionValue ''
        Get-PerfMonitorOutputDir | Should -BeNullOrEmpty
    }

    It 'session.conf を持つセッションを指定したら親ディレクトリを返す' {
        Set-SessionInput -SessionValue $script:SessionWithConf
        Get-PerfMonitorOutputDir | Should -Be $script:SessionsRoot
    }

    It 'data.jsonl を持つセッションを指定したら親ディレクトリを返す' {
        Set-SessionInput -SessionValue $script:SessionWithData
        Get-PerfMonitorOutputDir | Should -Be $script:SessionsRoot
    }

    It 'パス末尾に区切り文字があっても親ディレクトリを返す' {
        Set-SessionInput -SessionValue ($script:SessionWithConf + '\')
        Get-PerfMonitorOutputDir | Should -Be $script:SessionsRoot
    }

    It 'セッションを束ねるフォルダを指定したらそのフォルダ自体を返す' {
        Set-SessionInput -SessionValue $script:PlainDir
        Get-PerfMonitorOutputDir | Should -Be $script:PlainDir
    }

    It '存在しないパスなら $null を返す' {
        Set-SessionInput -SessionValue $script:MissingDir
        Get-PerfMonitorOutputDir | Should -BeNullOrEmpty
    }
}

Describe 'Get-ToolArguments (perf-monitor の -OutputDir)' {
    BeforeAll {
        $script:RunDir = Join-Path (Join-Path $script:OutputRoot 'perf-monitor') 'RUNSTAMP'

        function Get-OutputDirArgument {
            param([string]$SessionValue, [string]$Command = 'start')
            Set-SessionInput -SessionValue $SessionValue -Command $Command
            $toolArgs = @(Get-ToolArguments -Tool $script:PerfTool -RunDir $script:RunDir)
            for ($i = 0; $i -lt $toolArgs.Count - 1; $i++) {
                if ($toolArgs[$i] -eq '-OutputDir') { return $toolArgs[$i + 1] }
            }
            return $null
        }
    }

    It 'カタログに perf-monitor が存在する' {
        $script:PerfTool | Should -Not -BeNullOrEmpty
    }

    It 'セッション欄が空なら実行ごとの artifacts を渡す' {
        $expected = (Join-Path $script:RunDir 'artifacts').Replace('\', '/')
        Get-OutputDirArgument -SessionValue '' | Should -Be $expected
    }

    It 'セッション指定時はそのセッションと同じ場所を渡す' {
        Get-OutputDirArgument -SessionValue $script:SessionWithConf |
            Should -Be $script:SessionsRoot.Replace('\', '/')
    }

    It 'report でもセッション指定を尊重する' {
        Get-OutputDirArgument -SessionValue $script:SessionWithConf -Command 'report' |
            Should -Be $script:SessionsRoot.Replace('\', '/')
    }
}
