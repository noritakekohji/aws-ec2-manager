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
        It '入力ディレクトリはあるが有効な JSON が無ければ 2 を返す' {
            $emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) ('envdoc-noinput-' + [guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
            try {
                $r = Invoke-EnvDocExe -ScriptArgs @('-InputDir', $emptyDir, '-SystemFile', $script:SysFile)
                $r.Code | Should -Be 2
            }
            finally {
                Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
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
        Context 'New-EnvDocCrossTable — 未収集サーバの除外(直接検証)' {
            BeforeAll {
                # 既存の共有フィクスチャ(WEB01/WEB02/db01)はどちらも全カテゴリ収集済みのため、
                # 「片方だけ未収集」という本バグの核心シナリオを再現できない。
                # 共有フィクスチャファイルは変更禁止のため、ここで最小のサーバレコードを
                # その場で組み立てて New-EnvDocCrossTable / Get-EnvDocCategoryValue を直接検証する。
                function New-CrossTableTestServer {
                    param([string]$Name, [bool]$HasSnapshot, [string[]]$Categories, $SnapshotObj)
                    return @{
                        Hostname    = $Name
                        Key         = $Name.ToLowerInvariant()
                        HasSnapshot = $HasSnapshot
                        Categories  = $Categories
                        Snapshot    = $SnapshotObj
                    }
                }

                $script:RowsServices = @(
                    @{ Label = 'サービス状態'; Getter = {
                        param($s) Get-EnvDocCategoryValue -Server $s -Category 'services' -Getter {
                            param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'services_state')
                        }
                    }}
                )
            }

            It 'カテゴリ未収集(__MISSING__)のサーバを比較対象から除外する' {
                # A01 は services を収集済みで値は同じ 'running'。A02 は services が
                # 未収集(Categories に 'services' が無い)。両者を同一グループにしても、
                # A02 の __MISSING__ が A01 の実値と比較されて mismatch になってはいけない
                $srvA = New-CrossTableTestServer -Name 'A01' -HasSnapshot $true -Categories @('services') `
                    -SnapshotObj (ConvertFrom-Json '{"services_state":"running"}')
                $srvB = New-CrossTableTestServer -Name 'A02' -HasSnapshot $true -Categories @() `
                    -SnapshotObj (ConvertFrom-Json '{}')

                $model = @{ Groups = @(@{ Name = 'A'; MemberKeys = @('a01', 'a02') }) }
                $html = New-EnvDocCrossTable -Model $model -Servers @($srvA, $srvB) -Rows $script:RowsServices
                $html | Should -Not -BeLike '*class="mismatch"*'
                $html | Should -BeLike '*未収集*'
            }

            It 'サーバ自体が未収集(HasSnapshot=$false)の場合も比較対象から除外する' {
                # 明示 compare_groups で HasSnapshot=$false のサーバが混ざるケース。
                # B02 はそもそも snapshot が無いため、比較列自体を作れない
                $srvA = New-CrossTableTestServer -Name 'B01' -HasSnapshot $true -Categories @('services') `
                    -SnapshotObj (ConvertFrom-Json '{"services_state":"running"}')
                $srvB = New-CrossTableTestServer -Name 'B02' -HasSnapshot $false -Categories @() -SnapshotObj $null

                $model = @{ Groups = @(@{ Name = 'B'; MemberKeys = @('b01', 'b02') }) }
                $html = New-EnvDocCrossTable -Model $model -Servers @($srvA, $srvB) -Rows $script:RowsServices
                $html | Should -Not -BeLike '*class="mismatch"*'
                $html | Should -BeLike '*未収集*'
            }

            It '実際に値が異なる場合は引き続き不一致として検出する(回帰防止)' {
                # 上の 2 テストが「常に mismatch=false を返す」ような壊れた実装で
                # グリーンにならないことを保証する対照テスト
                $srvA = New-CrossTableTestServer -Name 'C01' -HasSnapshot $true -Categories @('services') `
                    -SnapshotObj (ConvertFrom-Json '{"services_state":"running"}')
                $srvB = New-CrossTableTestServer -Name 'C02' -HasSnapshot $true -Categories @('services') `
                    -SnapshotObj (ConvertFrom-Json '{"services_state":"stopped"}')

                $model = @{ Groups = @(@{ Name = 'C'; MemberKeys = @('c01', 'c02') }) }
                $html = New-EnvDocCrossTable -Model $model -Servers @($srvA, $srvB) -Rows $script:RowsServices
                $html | Should -BeLike '*class="mismatch"*'
            }
        }
    }

    Context 'AWS ページ' {
        It 'aws.html を生成する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*i-0aaa1111bbbb2222c*'
            $html | Should -BeLike '*t3.medium*'
            $html | Should -Not -BeLike '*このページは未実装です*'
        }
        It 'SG カードを共有サーバ数によらず 1 枚だけ出す' {
            # WEB01 と WEB02 が同じ SG を共有する。サーバごとに繰り返すと冗長で読めないため、
            # カード(h3 見出し)は 1 枚だけであることを厳密に検証する
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            ([regex]::Matches($html, '<h3>web-sg \(sg-0example\)</h3>')).Count | Should -Be 1
        }
        It 'SG に適用サーバを逆引きで併記する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*適用サーバ: WEB01, WEB02*'
        }
        It 'IAM ロールカードを 1 枚だけ出し使用サーバを併記する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            ([regex]::Matches($html, '<h3>web-instance-role</h3>')).Count | Should -Be 1
            $html | Should -BeLike '*使用サーバ: WEB01, WEB02*'
            $html | Should -BeLike '*SampleReadOnly*'
        }
        It 'aws 未収集のサーバを未収集と表示する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'aws.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*db01*'
            $html | Should -BeLike '*未収集*'
        }
        It 'サーバ詳細ページに AWS 要約を再掲する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*t3.medium*'
            $html | Should -BeLike '*web-instance-role*'
        }
        It 'AWS 未収集サーバの詳細ページには AWS 要約セクションを出さない' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\db01.html'), [System.Text.Encoding]::UTF8)
            $html | Should -Not -BeLike '*AWS 要約*'
        }
    }

    Context '全件ページと opt-in' {
        It 'packages 全件ページを生成する' {
            $p = Join-Path $script:OutRoot 'servers\WEB01-packages.html'
            Test-Path -LiteralPath $p | Should -BeTrue
            $html = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*Sample Runtime*'
        }
        It 'packages 未収集なら全件ページを作らない' {
            Test-Path -LiteralPath (Join-Path $script:OutRoot 'servers\db01-packages.html') | Should -BeFalse
        }
        It 'サーバ詳細から全件ページへリンクする' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*WEB01-packages.html*'
            $html | Should -BeLike '*2 件*'
        }
        It 'show_configs: true なら設定ファイルページを作る' {
            $p = Join-Path $script:OutRoot 'servers\WEB01-configs.html'
            Test-Path -LiteralPath $p | Should -BeTrue
            $html = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*server.xml*'
            # 設定ファイル本文はエスケープされて出ること
            $html | Should -BeLike '*&lt;Server port=&quot;8005&quot;*'
        }
        It 'services 由来の設定ファイルも掲載する' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01-configs.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*sshd_config*'
            # config_files が付くのは sshd / ssh-agent と samba 系のみ
            $html | Should -BeLike '*service sshd*'
        }
        It '読み取り不可のファイルは本文を出さず理由を出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01-configs.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*permission_denied*'
            # 本文ブロックは readable: true の 2 件(server.xml / catalina.properties)。
            # catalina.properties は masked: true だが readable: true なので <pre> は出る
            # (masked はマスク済みの content をそのまま表示する仕様。Task 9 で確認済み)。
            # 件数で見ないと、readable ガードを外しても空の <pre></pre> が出るだけで
            # 上の文字列アサーションは通ってしまい、テストが実効性を失う
            ([regex]::Matches($html, '<pre>')).Count | Should -Be 2
        }
        It 'show_configs 未指定なら設定ファイルページを作らない' {
            Test-Path -LiteralPath (Join-Path $script:OutRoot 'servers\WEB02-configs.html') | Should -BeFalse
        }
        It 'show_environment: true なら詳細に環境変数を出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*SAMPLE_HOME*'
        }
        It 'show_environment 未指定なら環境変数を出さない' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB02.html'), [System.Text.Encoding]::UTF8)
            $html | Should -Not -BeLike '*SAMPLE_HOME*'
        }
    }

    Context 'サービス一覧の分離' {
        It 'サービス全件ページを生成する' {
            $p = Join-Path $script:OutRoot 'servers\WEB01-services.html'
            Test-Path -LiteralPath $p | Should -BeTrue
            $html = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*W3SVC*'
            $html | Should -BeLike '*sshd*'
        }
        It 'サーバ詳細に全件表を埋め込まず件数とリンクだけ出す' {
            # 299 件のサービスを詳細ページに直接並べるとスクロールが破綻するため、
            # 詳細ページは要約に留めて全件は別ページに逃がす
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*WEB01-services.html*'
            $html | Should -Not -BeLike '*<td>W3SVC</td>*'
        }
        It '状態と起動設定のクロス集計を出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01-services.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*状態 \ 起動設定*'
        }
        It '状態ごとに折りたたむ' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01-services.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*<details*<summary>running*'
        }
        It '該当 0 件のとき空行ではなく「データなし」を出す' {
            # ArrayList.ToArray() を return するとき空配列は $null にアンロールされ、
            # New-HtmlTable 側で @($null) が 1 要素になって空行が出る(PS の配列アンロール)
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01-services.html'), [System.Text.Encoding]::UTF8)
            $html | Should -Not -BeLike '*<tbody><tr><td></td></tr></tbody>*'
        }
        It '起動するはずなのに停止しているサービスを抽出する' {
            # db01 の sshd/postgresql は enabled かつ running なので 0 件になるのが正しい
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\db01-services.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*自動起動だが停止*'
        }
        It 'services 未収集なら全件ページを作らない' {
            # MISSING01 は snapshot 自体が無い
            Test-Path -LiteralPath (Join-Path $script:OutRoot 'servers\MISSING01-services.html') | Should -BeFalse
        }
        It 'services が収集済みでも 0 件ならリンクを張らない' {
            # 全件ページは 0 件だと生成されない。詳細ページが無条件にリンクすると
            # リンク切れになるため、件数 0 のときは packages と同じく「なし」を出す
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('envdoc-emptysvc-' + [guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path (Join-Path $tmp 'input') -Force | Out-Null
            try {
                $snap = '{ "meta": { "hostname": "EMPTY01", "os_type": "windows", "collected_at": "2026-07-28T00:00:00+09:00", "categories": ["os", "services"] }, "os": { "os_name": "Windows" }, "services": [] }'
                [System.IO.File]::WriteAllText((Join-Path $tmp 'input\EMPTY01.snapshot.json'), $snap, (New-Object System.Text.UTF8Encoding($false)))
                $sys = "system:`n  id: emptysvc`n  name: Empty`nservers:`n  - hostname: EMPTY01`n    role: t"
                [System.IO.File]::WriteAllText((Join-Path $tmp 'system.yaml'), $sys, (New-Object System.Text.UTF8Encoding($false)))

                $root = Invoke-EnvDoc -InputDir (Join-Path $tmp 'input') -SystemFile (Join-Path $tmp 'system.yaml') -OutputDir (Join-Path $tmp 'out')
                $html = [System.IO.File]::ReadAllText((Join-Path $root 'servers\EMPTY01.html'), [System.Text.Encoding]::UTF8)
                $html | Should -Not -BeLike '*EMPTY01-services.html*'
            }
            finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'ファイル一覧のディレクトリツリー' {
        It 'ディレクトリを details で入れ子にする' {
            $p = Join-Path $script:OutRoot 'servers\db01-filelist.html'
            Test-Path -LiteralPath $p | Should -BeTrue
            $html = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            # db01 の filelist は app.conf / sub(dir) / sub/extra.conf
            $html | Should -BeLike '*<summary>sub/*'
        }
        It 'ディレクトリごとに件数を出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\db01-filelist.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*1 ファイル*'
        }
        It '入れ子のファイルはフルパスでなく名前で出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\db01-filelist.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*<td>extra.conf</td>*'
            $html | Should -Not -BeLike '*<td>sub/extra.conf</td>*'
        }
    }

    Context 'ファイルツリー構築 (単体)' {
        It 'バックスラッシュ区切りを階層に分解する' {
            $entries = @(
                [PSCustomObject]@{ rel_path = 'game';          type = 'dir' }
                [PSCustomObject]@{ rel_path = 'game\ps1';      type = 'dir' }
                [PSCustomObject]@{ rel_path = 'game\ps1\a.iso'; type = 'file' }
                [PSCustomObject]@{ rel_path = 'readme.txt';    type = 'file' }
            )
            $tree = New-EnvDocFileTree -Entries $entries
            @($tree.Files).Count            | Should -Be 1
            $tree.Dirs.Contains('game')     | Should -BeTrue
            $tree.Dirs['game'].Dirs.Contains('ps1') | Should -BeTrue
            @($tree.Dirs['game'].Dirs['ps1'].Files).Count | Should -Be 1
        }
        It 'スラッシュ区切りも同じように扱う' {
            $entries = @(
                [PSCustomObject]@{ rel_path = 'sub';           type = 'dir' }
                [PSCustomObject]@{ rel_path = 'sub/extra.conf'; type = 'file' }
            )
            $tree = New-EnvDocFileTree -Entries $entries
            @($tree.Dirs['sub'].Files).Count | Should -Be 1
        }
        It '親ディレクトリの entry が無くても階層を作る' {
            $entries = @([PSCustomObject]@{ rel_path = 'a\b\c.txt'; type = 'file' })
            $tree = New-EnvDocFileTree -Entries $entries
            @($tree.Dirs['a'].Dirs['b'].Files).Count | Should -Be 1
        }
        It '再帰的に件数を数える' {
            $entries = @(
                [PSCustomObject]@{ rel_path = 'a';        type = 'dir' }
                [PSCustomObject]@{ rel_path = 'a\x.txt';  type = 'file' }
                [PSCustomObject]@{ rel_path = 'a\b';      type = 'dir' }
                [PSCustomObject]@{ rel_path = 'a\b\y.txt'; type = 'file' }
            )
            $tree = New-EnvDocFileTree -Entries $entries
            $c = Get-EnvDocFileTreeCount -Node $tree
            $c.Files | Should -Be 2
            $c.Dirs  | Should -Be 2
        }
    }

    Context 'サーバ詳細の目次' {
        It '目次を出す' {
            $html = [System.IO.File]::ReadAllText((Join-Path $script:OutRoot 'servers\WEB01.html'), [System.Text.Encoding]::UTF8)
            $html | Should -BeLike '*class="toc"*'
            $html | Should -BeLike '*href="#services"*'
        }
    }
}
