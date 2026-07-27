#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'EnvDoc 統合' {
    BeforeAll {
        $env:ENVDOC_SKIP_MAIN = '1'
        . (Resolve-Path (Join-Path $PSScriptRoot '..\tools\env-doc\EnvDoc.ps1')).Path

        $script:Fixtures = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures\env-doc')).Path
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('envdoc-e2e-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null

        $script:OutRoot = Invoke-EnvDoc `
            -InputDir   (Join-Path $script:Fixtures 'input') `
            -SystemFile (Join-Path $script:Fixtures 'system.yaml') `
            -OutputDir  $script:TmpDir
    }
    AfterAll {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\ENVDOC_SKIP_MAIN -ErrorAction SilentlyContinue
    }

    It 'system.id のディレクトリに出力する' {
        (Split-Path -Leaf $script:OutRoot) | Should -Be 'sample-sys'
    }

    It 'index.html を生成する' {
        Test-Path -LiteralPath (Join-Path $script:OutRoot 'index.html') | Should -BeTrue
    }

    It 'サーバ詳細ページを snapshot のあるサーバ分だけ生成する' {
        Test-Path -LiteralPath (Join-Path $script:OutRoot 'servers\WEB01.html') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:OutRoot 'servers\db01.html')  | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:OutRoot 'servers\MISSING01.html') | Should -BeFalse
    }

    It 'style.css をコピーする' {
        Test-Path -LiteralPath (Join-Path $script:OutRoot 'assets\style.css') | Should -BeTrue
    }

    It 'index に未収集サーバを掲載する' {
        $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'index.html'), [System.Text.Encoding]::UTF8)
        $html | Should -BeLike '*MISSING01*'
        $html | Should -BeLike '*未収集*'
    }

    It 'index に警告を掲載する' {
        $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'index.html'), [System.Text.Encoding]::UTF8)
        $html | Should -BeLike '*警告*'
    }

    It '生成 HTML が BOM なし UTF-8 である' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:OutRoot 'index.html'))
        $bytes[0] | Should -Not -Be 0xEF
    }

    It '日本語が壊れていない' {
        $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'index.html'), [System.Text.Encoding]::UTF8)
        $html | Should -BeLike '*サンプルシステム*'
    }

    It '出力先が既存で -Force なしなら throw する' {
        {
            Invoke-EnvDoc -InputDir (Join-Path $script:Fixtures 'input') `
                          -SystemFile (Join-Path $script:Fixtures 'system.yaml') `
                          -OutputDir $script:TmpDir
        } | Should -Throw -ExpectedMessage '*Force*'
    }

    It '-Force なら上書きできる' {
        {
            Invoke-EnvDoc -InputDir (Join-Path $script:Fixtures 'input') `
                          -SystemFile (Join-Path $script:Fixtures 'system.yaml') `
                          -OutputDir $script:TmpDir -Force
        } | Should -Not -Throw
    }

    Context '終了コード' {
        # dot-source では if (-not $env:ENVDOC_SKIP_MAIN) ブロックを通らないため、
        # 終了コードは必ず子プロセスで実行して検証する
        BeforeAll {
            # 子プロセスは環境変数を継承する。ENVDOC_SKIP_MAIN が立ったままだと
            # 子プロセス側でもメインブロックがスキップされ、常に exit 0 になり検知できない
            Remove-Item Env:\ENVDOC_SKIP_MAIN -ErrorAction SilentlyContinue

            $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\env-doc\EnvDoc.ps1')).Path
            $script:SysFile    = (Join-Path $script:Fixtures 'system.yaml')
            $script:InDir      = (Join-Path $script:Fixtures 'input')

            function Invoke-EnvDocExe {
                param([string[]]$ScriptArgs)
                $out = Join-Path ([System.IO.Path]::GetTempPath()) ('envdoc-ec-' + [guid]::NewGuid().ToString())
                $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath) + $ScriptArgs + @('-OutputDir', $out)
                # このファイルの外側の BeforeAll で EnvDoc.ps1 を dot-source しているため、
                # $ErrorActionPreference = 'Stop' がこのスコープにも及んでいる。
                # その状態で子プロセスの stderr を 2>$null すると NativeCommandError が
                # 終了エラーとして送出され $LASTEXITCODE を読む前に落ちるため、ここだけ緩める
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    & powershell.exe @all 2>$null | Out-Null
                }
                finally {
                    $ErrorActionPreference = $prevEap
                }
                return @{ Code = $LASTEXITCODE; Out = $out }
            }
        }

        It '成功したら 0 を返す' {
            $r = Invoke-EnvDocExe -ScriptArgs @('-InputDir', $script:InDir, '-SystemFile', $script:SysFile)
            $r.Code | Should -Be 0
            Remove-Item -LiteralPath $r.Out -Recurse -Force -ErrorAction SilentlyContinue
        }
        It '入力ディレクトリが無ければ 2 を返す' {
            $r = Invoke-EnvDocExe -ScriptArgs @('-InputDir', 'Z:\no\such\dir', '-SystemFile', $script:SysFile)
            $r.Code | Should -Be 2
        }
        It 'system.yaml が無ければ 1 を返す' {
            $r = Invoke-EnvDocExe -ScriptArgs @('-InputDir', $script:InDir, '-SystemFile', 'Z:\no\such.yaml')
            $r.Code | Should -Be 1
        }
        It '出力先が既存で -Force なしなら 1 を返す' {
            $r1 = Invoke-EnvDocExe -ScriptArgs @('-InputDir', $script:InDir, '-SystemFile', $script:SysFile)
            $r1.Code | Should -Be 0
            $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath,
                     '-InputDir', $script:InDir, '-SystemFile', $script:SysFile, '-OutputDir', $r1.Out)
            # Invoke-EnvDocExe と同じ理由で、ここも一時的に EAP を緩める
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & powershell.exe @all 2>$null | Out-Null
            }
            finally {
                $ErrorActionPreference = $prevEap
            }
            $LASTEXITCODE | Should -Be 1
            Remove-Item -LiteralPath $r1.Out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '相対リンクに切れがない' {
        $files = @(Get-ChildItem -LiteralPath $script:OutRoot -Recurse -File -Filter '*.html')
        $broken = @()
        foreach ($f in $files) {
            $html = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            foreach ($m in [regex]::Matches($html, '(?:href|src)="([^"]+)"')) {
                $href = $m.Groups[1].Value
                if ($href.StartsWith('#') -or $href -match '^[a-z]+:') { continue }
                $target = Join-Path (Split-Path -Parent $f.FullName) ($href -replace '/', '\')
                if (-not (Test-Path -LiteralPath $target)) { $broken += "$($f.Name) -> $href" }
            }
        }
        $broken -join '; ' | Should -Be ''
    }

    Context '横断ページ' {
        It 'network.html を生成する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'network.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*10.0.1.11*'
            $html | Should -BeLike '*ntp.sample.internal*'
            $html | Should -Not -BeLike '*未実装*'
        }
        It 'network.html にリモートアクセスを OS 別サブ表で出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'network.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*リモートアクセス - Windows (2 台)*'
            $html | Should -BeLike '*リモートアクセス - Linux (1 台)*'
            # Linux は unit 名から .service を除去し、status は SubState を入れる
            $html | Should -BeLike '*sshd: running*'
        }
        It 'NLA の不一致をハイライトする' {
            # WEB01 は nla_enabled=true、WEB02 は false
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'network.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*<tr class="mismatch"><td>NLA</td>*'
        }
        It 'middleware.html に Tomcat のバージョン不一致を出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'middleware.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*9.0.85*'
            $html | Should -BeLike '*9.0.80*'
            $html | Should -BeLike '*class="mismatch"*'
        }
        It 'middleware.html で未収集サーバを未収集と表示する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'middleware.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*未収集*'
        }
        It 'スタブが本実装に置き換わっている' {
            # Task 6 の Write-EnvDocStubPage は本実装への置き換え忘れを検知できないため、
            # 横断ページに「未実装」が残っていないことをここで担保する
            foreach ($f in @('network.html', 'middleware.html', 'os-baseline.html')) {
                $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot $f), [System.Text.Encoding]::UTF8)
                $html | Should -Not -BeLike '*このページは未実装です*' -Because "$f がスタブのまま"
            }
        }
        It 'os-baseline.html を OS 別サブ表に分ける' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'os-baseline.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*Windows*'
            $html | Should -BeLike '*Linux*'
            $html | Should -BeLike '*Sample Enterprise Linux*'
        }
        It '揮発値(最終起動)を不一致にしない' {
            # WEB01 と WEB02 は last_boot が異なるが、NoCompare のためハイライトしない
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'os-baseline.html'), [System.Text.Encoding]::UTF8)
            $html | Should -Not -BeLike '*<tr class="mismatch"><td>最終起動</td>*'
        }
        It 'OS が違うだけの行を不一致にしない' {
            # WEB01/WEB02 は同一グループで os_version が同じ。db01 は別グループ。
            # 共通軸表で os_version 行が mismatch にならないこと
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'os-baseline.html'), [System.Text.Encoding]::UTF8)
            $m = [regex]::Match($html, '<tr class="mismatch"><td>OS バージョン</td>')
            $m.Success | Should -BeFalse
        }
    }

    Context 'AWS ページ' {
        It 'aws.html を生成する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*i-0aaa1111bbbb2222c*'
            $html | Should -BeLike '*t3.medium*'
            $html | Should -Not -BeLike '*このページは未実装です*'
        }
        It 'SG を 1 回だけ出し適用サーバを併記する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            ([regex]::Matches($html, 'sg-0example</td>')).Count | Should -BeLessOrEqual 2
            $html | Should -BeLike '*web-sg*'
            $html | Should -BeLike '*適用サーバ*'
        }
        It 'IAM ロールと使用サーバを出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*web-instance-role*'
            $html | Should -BeLike '*SampleReadOnly*'
        }
        It 'aws 未収集のサーバを未収集と表示する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*db01*'
            $html | Should -BeLike '*未収集*'
        }
    }
}
