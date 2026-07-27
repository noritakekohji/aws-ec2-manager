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

    It '相対リンクに切れがない' {
        $files = @(Get-ChildItem -LiteralPath $script:OutRoot -Recurse -File -Filter '*.html')
        $broken = @()
        foreach ($f in $files) {
            $html = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            foreach ($m in [regex]::Matches($html, 'href="([^"]+)"')) {
                $href = $m.Groups[1].Value
                if ($href.StartsWith('#') -or $href -match '^[a-z]+:') { continue }
                $target = Join-Path (Split-Path -Parent $f.FullName) ($href -replace '/', '\')
                if (-not (Test-Path -LiteralPath $target)) { $broken += "$($f.Name) -> $href" }
            }
        }
        $broken -join '; ' | Should -Be ''
    }
}
