#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'EnvDoc Html' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\Html.ps1')
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('envdoc-html-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'ConvertTo-HtmlText' {
        It '記号をエスケープする' {
            ConvertTo-HtmlText -Text '<b>&"x"' | Should -Be '&lt;b&gt;&amp;&quot;x&quot;'
        }
        It 'シングルクォートをエスケープする' {
            ConvertTo-HtmlText -Text "it's" | Should -Be 'it&#39;s'
        }
        It '日本語をそのまま通す' {
            ConvertTo-HtmlText -Text '受注管理システム' | Should -Be '受注管理システム'
        }
        It '$null を空文字にする' {
            ConvertTo-HtmlText -Text $null | Should -Be ''
        }
        It 'アンパサンドを二重エスケープしない' {
            ConvertTo-HtmlText -Text 'a&b' | Should -Be 'a&amp;b'
        }
    }

    Context 'New-HtmlTable' {
        It 'ヘッダと行を出力する' {
            $t = New-HtmlTable -Headers @('項目', '値') -Rows @(@{ Cells = @('OS', 'RHEL'); Mismatch = $false })
            $t | Should -BeLike '*<th>項目</th>*'
            $t | Should -BeLike '*<td>RHEL</td>*'
        }
        It '不一致行に mismatch クラスを付ける' {
            $t = New-HtmlTable -Headers @('a') -Rows @(@{ Cells = @('x'); Mismatch = $true })
            $t | Should -BeLike '*<tr class="mismatch">*'
        }
        It '一致行にはクラスを付けない' {
            $t = New-HtmlTable -Headers @('a') -Rows @(@{ Cells = @('x'); Mismatch = $false })
            $t | Should -Not -BeLike '*mismatch*'
        }
        It '行が空なら「データなし」を出す' {
            New-HtmlTable -Headers @('a') -Rows @() | Should -BeLike '*データなし*'
        }
    }

    Context 'New-HtmlPage' {
        It 'charset と title を含む' {
            $p = New-HtmlPage -Title 'テスト' -SystemName 'S' -RelRoot '.' -Body '<p>x</p>'
            $p | Should -BeLike '*<meta charset="utf-8">*'
            $p | Should -BeLike '*<title>テスト*'
        }
        It 'RelRoot を使って相対リンクを組み立てる' {
            $p = New-HtmlPage -Title 't' -SystemName 'S' -RelRoot '..' -Body ''
            $p | Should -BeLike '*href="../index.html"*'
            $p | Should -BeLike '*href="../assets/style.css"*'
        }
        It '絶対 URL を含まない' {
            $p = New-HtmlPage -Title 't' -SystemName 'S' -RelRoot '.' -Body ''
            $p | Should -Not -BeLike '*http://*'
            $p | Should -Not -BeLike '*https://*'
        }
    }

    Context 'Write-HtmlFile' {
        It 'BOM なし UTF-8 で書き出す' {
            $f = Join-Path $script:TmpDir 'sub\a.html'
            Write-HtmlFile -Path $f -Content '<p>受注</p>'
            $bytes = [System.IO.File]::ReadAllBytes($f)
            $bytes[0] | Should -Not -Be 0xEF
            [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | Should -Be '<p>受注</p>'
        }
        It '親ディレクトリを自動作成する' {
            $f = Join-Path $script:TmpDir 'deep\er\b.html'
            Write-HtmlFile -Path $f -Content 'x'
            Test-Path -LiteralPath $f | Should -BeTrue
        }
    }

    Context 'Format-EnvDocMissing' {
        It '未収集を表す' { Format-EnvDocMissing -Collected $false -Count 0 | Should -BeLike '*未収集*' }
        It '0 件を「なし」にする' { Format-EnvDocMissing -Collected $true -Count 0 | Should -Be 'なし' }
        It '件数を出す' { Format-EnvDocMissing -Collected $true -Count 3 | Should -Be '3 件' }
    }
}
