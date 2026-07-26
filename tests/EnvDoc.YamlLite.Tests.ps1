#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'YamlLite' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\YamlLite.ps1')
    }

    Context 'マップ' {
        It 'フラットな キー: 値 を読む' {
            $r = ConvertFrom-YamlLiteText -Text "id: order-mgmt`nname: 受注管理システム"
            $r['id']   | Should -Be 'order-mgmt'
            $r['name'] | Should -Be '受注管理システム'
        }
        It 'ネストしたマップを読む' {
            $r = ConvertFrom-YamlLiteText -Text "system:`n  id: a`n  name: b"
            $r['system']['id']   | Should -Be 'a'
            $r['system']['name'] | Should -Be 'b'
        }
        It '値に含まれるコロンを保持する' {
            $r = ConvertFrom-YamlLiteText -Text 'url: https://example.com/a'
            $r['url'] | Should -Be 'https://example.com/a'
        }
        It 'キーの順序を保持する' {
            $r = ConvertFrom-YamlLiteText -Text "z: 1`na: 2`nm: 3"
            @($r.Keys) | Should -Be @('z', 'a', 'm')
        }
    }

    Context 'シーケンス' {
        It 'スカラのシーケンスを読む' {
            $r = ConvertFrom-YamlLiteText -Text "hosts:`n  - web01`n  - db01"
            $r['hosts'].Count | Should -Be 2
            $r['hosts'][1]    | Should -Be 'db01'
        }
        It 'マップのシーケンスを読む' {
            $text = "servers:`n  - hostname: WEB01`n    role: Web`n  - hostname: db01`n    role: DB"
            $r = ConvertFrom-YamlLiteText -Text $text
            $r['servers'].Count          | Should -Be 2
            $r['servers'][0]['hostname'] | Should -Be 'WEB01'
            $r['servers'][0]['role']     | Should -Be 'Web'
            $r['servers'][1]['role']     | Should -Be 'DB'
        }
        It 'インラインシーケンスを読む' {
            $r = ConvertFrom-YamlLiteText -Text 'servers: [WEB01, WEB02]'
            $r['servers'].Count | Should -Be 2
            $r['servers'][0]    | Should -Be 'WEB01'
        }
        It '空のインラインシーケンスを読む' {
            $r = ConvertFrom-YamlLiteText -Text 'servers: []'
            @($r['servers']).Count | Should -Be 0
        }
    }

    Context 'スカラ変換' {
        It 'true / false を真偽値にする' {
            $r = ConvertFrom-YamlLiteText -Text "a: true`nb: false"
            $r['a'] | Should -BeTrue
            $r['b'] | Should -BeFalse
        }
        It '整数を数値にする' {
            (ConvertFrom-YamlLiteText -Text 'n: 42')['n'] | Should -Be 42
        }
        It 'シングルクォートを外す' {
            (ConvertFrom-YamlLiteText -Text "s: 'true'")['s'] | Should -Be 'true'
        }
        It 'ダブルクォートを外す' {
            (ConvertFrom-YamlLiteText -Text 's: "# not a comment"')['s'] | Should -Be '# not a comment'
        }
        It '値なしのキーを $null にする' {
            (ConvertFrom-YamlLiteText -Text 'note:')['note'] | Should -BeNullOrEmpty
        }
    }

    Context 'コメントと空行' {
        It '行頭コメントを無視する' {
            $r = ConvertFrom-YamlLiteText -Text "# comment`nid: a"
            $r['id'] | Should -Be 'a'
        }
        It '行末コメントを除去する' {
            (ConvertFrom-YamlLiteText -Text 'id: a  # trailing')['id'] | Should -Be 'a'
        }
        It '空行を無視する' {
            $r = ConvertFrom-YamlLiteText -Text "id: a`n`n`nname: b"
            $r['name'] | Should -Be 'b'
        }
    }

    Context '範囲外構文は行番号付きで拒否する' {
        It 'タブインデントを拒否する' {
            { ConvertFrom-YamlLiteText -Text "a:`n`tb: 1" } | Should -Throw -ExpectedMessage '*行 2*'
        }
        It 'アンカーを拒否する' {
            { ConvertFrom-YamlLiteText -Text 'a: &anchor x' } | Should -Throw -ExpectedMessage '*行 1*'
        }
        It 'エイリアスを拒否する' {
            { ConvertFrom-YamlLiteText -Text 'a: *ref' } | Should -Throw -ExpectedMessage '*行 1*'
        }
        It '複数行スカラを拒否する' {
            { ConvertFrom-YamlLiteText -Text "a: |`n  text" } | Should -Throw -ExpectedMessage '*行 1*'
        }
        It 'フローマップを拒否する' {
            { ConvertFrom-YamlLiteText -Text 'a: {b: 1}' } | Should -Throw -ExpectedMessage '*行 1*'
        }
        It 'ドキュメント区切りを拒否する' {
            { ConvertFrom-YamlLiteText -Text "---`na: 1" } | Should -Throw -ExpectedMessage '*行 1*'
        }
        It '奇数インデントを拒否する' {
            { ConvertFrom-YamlLiteText -Text "a:`n   b: 1" } | Should -Throw -ExpectedMessage '*行 2*'
        }
        It 'コロンのない行を拒否する' {
            { ConvertFrom-YamlLiteText -Text 'just text' } | Should -Throw -ExpectedMessage '*行 1*'
        }
    }

    Context 'ConvertFrom-YamlLite (ファイル)' {
        BeforeAll {
            $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('envdoc-yaml-' + [guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
        }
        AfterAll {
            Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        It 'BOM なし UTF-8 ファイルを読む' {
            $f = Join-Path $script:TmpDir 'a.yaml'
            [System.IO.File]::WriteAllText($f, "name: 受注管理", (New-Object System.Text.UTF8Encoding($false)))
            (ConvertFrom-YamlLite -Path $f)['name'] | Should -Be '受注管理'
        }
        It 'BOM 付き UTF-8 ファイルを読む' {
            $f = Join-Path $script:TmpDir 'b.yaml'
            [System.IO.File]::WriteAllText($f, "name: 受注管理", (New-Object System.Text.UTF8Encoding($true)))
            (ConvertFrom-YamlLite -Path $f)['name'] | Should -Be '受注管理'
        }
    }
}
