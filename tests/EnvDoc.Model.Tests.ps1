#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'EnvDoc Model - 入力読み込み' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\Model.ps1')
        $script:InputDir = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures\env-doc\input')).Path
    }

    Context 'Read-EnvDocInput' {
        BeforeAll { $script:Inputs = Read-EnvDocInput -InputDir $script:InputDir }

        It 'snapshot を 3 件読む' {
            $script:Inputs.Snapshots.Count | Should -Be 3
        }
        It 'ホスト名を小文字キーで格納する' {
            $script:Inputs.Snapshots.ContainsKey('web01') | Should -BeTrue
            $script:Inputs.Snapshots.ContainsKey('db01')  | Should -BeTrue
        }
        It 'aws JSON を snapshot と区別して読む' {
            $script:Inputs.Aws.Count | Should -Be 1
            $script:Inputs.Aws['web01'].instance.instance_type | Should -Be 't3.medium'
        }
        It '種別判定できない JSON を警告してスキップする' {
            @($script:Inputs.Warnings | Where-Object { $_ -like '*broken.json*' }).Count | Should -Be 1
        }
        It '存在しないディレクトリで throw する' {
            { Read-EnvDocInput -InputDir (Join-Path $script:InputDir 'nope') } | Should -Throw
        }
    }

    Context 'Get-JsonValue' {
        It 'ドット区切りで値を取り出す' {
            $o = ConvertFrom-Json '{ "a": { "b": { "c": 5 } } }'
            Get-JsonValue -Object $o -Path 'a.b.c' | Should -Be 5
        }
        It '存在しないパスで既定値を返す' {
            $o = ConvertFrom-Json '{ "a": 1 }'
            Get-JsonValue -Object $o -Path 'x.y' -Default 'なし' | Should -Be 'なし'
        }
        It '$null オブジェクトで既定値を返す' {
            Get-JsonValue -Object $null -Path 'a' -Default '-' | Should -Be '-'
        }
    }
}
