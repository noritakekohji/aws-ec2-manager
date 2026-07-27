#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'EnvDoc Compare' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\YamlLite.ps1')
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\Compare.ps1')

        function New-Srv {
            param([string]$Name, [string]$Role, [string]$Os, [bool]$Has = $true)
            return @{ Hostname = $Name; Key = $Name.ToLowerInvariant(); Role = $Role; OsType = $Os; HasSnapshot = $Has }
        }
        $script:Model = @{
            Servers = @(
                (New-Srv -Name 'WEB01' -Role 'Web' -Os 'windows'),
                (New-Srv -Name 'WEB02' -Role 'Web' -Os 'windows'),
                (New-Srv -Name 'db01'  -Role 'DB'  -Os 'linux'),
                (New-Srv -Name 'ETC01' -Role ''    -Os 'linux')
            )
        }
    }

    Context 'Get-EnvDocCompareGroup - 自動グループ化' {
        BeforeAll {
            $script:Groups = Get-EnvDocCompareGroup -Model $script:Model -SystemDef ([ordered]@{})
        }
        It 'os_type × role でグループを作る' {
            $web = $script:Groups | Where-Object { $_.MemberKeys -contains 'web01' }
            @($web.MemberKeys) | Should -Be @('web01', 'web02')
        }
        It 'OS が違えば別グループにする' {
            $web = $script:Groups | Where-Object { $_.MemberKeys -contains 'web01' }
            $web.MemberKeys | Should -Not -Contain 'db01'
        }
        It 'role 未設定のサーバをグループに入れない' {
            @($script:Groups | Where-Object { $_.MemberKeys -contains 'etc01' }).Count | Should -Be 0
        }
    }

    Context 'Get-EnvDocCompareGroup - 明示指定' {
        It 'compare_groups があれば自動グループ化を行わない' {
            $def = ConvertFrom-YamlLiteText -Text "compare_groups:`n  - name: ペア`n    servers: [WEB01, db01]"
            $g = Get-EnvDocCompareGroup -Model $script:Model -SystemDef $def
            @($g).Count      | Should -Be 1
            $g[0].Name       | Should -Be 'ペア'
            @($g[0].MemberKeys) | Should -Be @('web01', 'db01')
        }
        It '空の compare_groups は自動グループ化にフォールバックしない' {
            $def = ConvertFrom-YamlLiteText -Text 'compare_groups: []'
            $g = Get-EnvDocCompareGroup -Model $script:Model -SystemDef $def
            @($g).Count | Should -Be 0
        }
        It '存在しないホストを明示指定から除外する' {
            $def = ConvertFrom-YamlLiteText -Text "compare_groups:`n  - name: X`n    servers: [WEB01, NOPE]"
            $g = Get-EnvDocCompareGroup -Model $script:Model -SystemDef $def
            @($g[0].MemberKeys) | Should -Be @('web01')
        }
    }

    Context 'Test-EnvDocMismatch' {
        BeforeAll {
            $script:G = @(@{ Name = 'Web'; MemberKeys = @('web01', 'web02') })
        }
        It '値が揃っていれば $false' {
            Test-EnvDocMismatch -ValuesByKey @{ web01 = 'a'; web02 = 'a' } -Groups $script:G | Should -BeFalse
        }
        It '値が違えば $true' {
            Test-EnvDocMismatch -ValuesByKey @{ web01 = 'a'; web02 = 'b' } -Groups $script:G | Should -BeTrue
        }
        It 'グループ外の差異は無視する' {
            $v = @{ web01 = 'a'; web02 = 'a'; db01 = 'zzz' }
            Test-EnvDocMismatch -ValuesByKey $v -Groups $script:G | Should -BeFalse
        }
        It 'メンバー 1 台のグループは $false' {
            $g1 = @(@{ Name = 'Solo'; MemberKeys = @('web01') })
            Test-EnvDocMismatch -ValuesByKey @{ web01 = 'a' } -Groups $g1 | Should -BeFalse
        }
        It 'グループが空なら $false' {
            Test-EnvDocMismatch -ValuesByKey @{ web01 = 'a'; web02 = 'b' } -Groups @() | Should -BeFalse
        }
        It '欠損値と空文字を同じ扱いにする' {
            Test-EnvDocMismatch -ValuesByKey @{ web01 = ''; web02 = $null } -Groups $script:G | Should -BeFalse
        }
        It '片方が ValuesByKey に登録されていない(未収集)なら不一致にしない' {
            # __MISSING__ や HasSnapshot=false のサーバは呼び出し側が登録しない設計。
            # ValuesByKey にキーが無い状態を Test-EnvDocMismatch がどう扱うかを確認する
            Test-EnvDocMismatch -ValuesByKey @{ web01 = 'a' } -Groups $script:G | Should -BeFalse
        }
    }
}
