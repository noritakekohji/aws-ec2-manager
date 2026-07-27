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
            $script:Inputs.Aws.Count | Should -Be 2
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

Describe 'EnvDoc Model - モデル構築' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\YamlLite.ps1')
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\Model.ps1')
        $fixtures = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures\env-doc')).Path
        $script:SystemDef = ConvertFrom-YamlLite -Path (Join-Path $fixtures 'system.yaml')
        $script:Inputs    = Read-EnvDocInput -InputDir (Join-Path $fixtures 'input')
        $script:Model     = Build-EnvDocModel -SystemDef $script:SystemDef -Inputs $script:Inputs
    }

    It 'システムのメタ情報を取り込む' {
        $script:Model.System.Id   | Should -Be 'sample-sys'
        $script:Model.System.Name | Should -Be 'サンプルシステム'
    }

    It 'YAML の順序どおりにサーバを並べる' {
        @($script:Model.Servers | ForEach-Object { $_.Hostname }) |
            Should -Be @('WEB01', 'WEB02', 'db01', 'MISSING01')
    }

    It 'YAML の役割を取り込む' {
        ($script:Model.Servers | Where-Object { $_.Hostname -eq 'db01' }).Role | Should -Be 'DB サーバ'
    }

    It 'snapshot から os_type を取り込む' {
        ($script:Model.Servers | Where-Object { $_.Hostname -eq 'WEB01' }).OsType | Should -Be 'windows'
        ($script:Model.Servers | Where-Object { $_.Hostname -eq 'db01' }).OsType  | Should -Be 'linux'
    }

    It 'snapshot が無いサーバを HasSnapshot=$false にして警告する' {
        $missing = $script:Model.Servers | Where-Object { $_.Hostname -eq 'MISSING01' }
        $missing.HasSnapshot | Should -BeFalse
        @($script:Model.Meta.Warnings | Where-Object { $_ -like '*MISSING01*' }).Count | Should -Be 1
    }

    It 'show_configs / show_environment の既定を $false にする' {
        # WEB01 は Task 9 で opt-in (show_configs/show_environment: true) しているため、
        # 既定値の検証には opt-in していない WEB02 を使う
        $s = $script:Model.Servers | Where-Object { $_.Hostname -eq 'WEB02' }
        $s.ShowConfigs     | Should -BeFalse
        $s.ShowEnvironment | Should -BeFalse
    }

    It 'Test-EnvDocCategory が未収集カテゴリを見分ける' {
        $web = $script:Model.Servers | Where-Object { $_.Hostname -eq 'WEB01' }
        $db  = $script:Model.Servers | Where-Object { $_.Hostname -eq 'db01' }
        Test-EnvDocCategory -Server $web -Category 'middleware' | Should -BeTrue
        Test-EnvDocCategory -Server $db  -Category 'middleware' | Should -BeFalse
    }

    It 'snapshot にあるが YAML に無いサーバを警告付きで追加する' {
        $def = ConvertFrom-YamlLiteText -Text "system:`n  id: x`n  name: X`nservers:`n  - hostname: WEB01"
        $m = Build-EnvDocModel -SystemDef $def -Inputs $script:Inputs
        @($m.Servers | ForEach-Object { $_.Hostname }) | Should -Contain 'db01'
        @($m.Meta.Warnings | Where-Object { $_ -like '*db01*' }).Count | Should -BeGreaterThan 0
    }

    It 'パストラバーサルを含む hostname を警告してスキップする' {
        $def = ConvertFrom-YamlLiteText -Text "system:`n  id: x`n  name: X`nservers:`n  - hostname: '../../evil'"
        $m = Build-EnvDocModel -SystemDef $def -Inputs $script:Inputs
        @($m.Servers | Where-Object { $_.Hostname -like '*evil*' }).Count | Should -Be 0
        @($m.Meta.Warnings | Where-Object { $_ -like '*使えない文字*' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-EnvDocHostname が FQDN を許し危険な名前を弾く' {
        Test-EnvDocHostname -Name 'web01'             | Should -BeTrue
        Test-EnvDocHostname -Name 'web01.example.com' | Should -BeTrue
        Test-EnvDocHostname -Name 'WEB-01_a'          | Should -BeTrue
        Test-EnvDocHostname -Name '../../evil'        | Should -BeFalse
        Test-EnvDocHostname -Name 'a/b'               | Should -BeFalse
        Test-EnvDocHostname -Name 'a\b'               | Should -BeFalse
        Test-EnvDocHostname -Name '..'                | Should -BeFalse
        Test-EnvDocHostname -Name ''                  | Should -BeFalse
        Test-EnvDocHostname -Name "web01`n"           | Should -BeFalse
    }

    It 'system.id が不正なら throw する' {
        $def = ConvertFrom-YamlLiteText -Text "system:`n  id: 'bad/id'`n  name: X"
        { Build-EnvDocModel -SystemDef $def -Inputs $script:Inputs } | Should -Throw -ExpectedMessage '*system.id*'
    }

    It 'system.name が無ければ throw する' {
        $def = ConvertFrom-YamlLiteText -Text "system:`n  id: ok"
        { Build-EnvDocModel -SystemDef $def -Inputs $script:Inputs } | Should -Throw -ExpectedMessage '*system.name*'
    }
}

Describe 'EnvDoc Model - AWS 正規化' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\YamlLite.ps1')
        . (Join-Path $PSScriptRoot '..\tools\env-doc\lib\Model.ps1')
        $fixtures = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures\env-doc')).Path
        $def    = ConvertFrom-YamlLite -Path (Join-Path $fixtures 'system.yaml')
        $inputs = Read-EnvDocInput -InputDir (Join-Path $fixtures 'input')
        $script:M = Build-EnvDocModel -SystemDef $def -Inputs $inputs
        Add-EnvDocAwsModel -Model $script:M -Inputs $inputs
    }

    It 'インスタンスを 2 件取り込む' {
        @($script:M.Aws.Instances).Count | Should -Be 2
        $script:M.Aws.Instances[0].InstanceType | Should -Be 't3.medium'
    }
    It 'SG をリソース単位に正規化し適用サーバを逆引きできる' {
        # WEB01 と WEB02 が同じ SG を共有する。カードは 1 枚で適用サーバが 2 台並ぶのが正解
        @($script:M.Aws.SecurityGroups).Count | Should -Be 1
        $script:M.Aws.SecurityGroups[0].GroupId | Should -Be 'sg-0example'
        @($script:M.Aws.SecurityGroups[0].AppliedTo) | Should -Be @('WEB01', 'WEB02')
    }
    It 'IAM ロールをリソース単位に正規化し使用サーバを逆引きできる' {
        @($script:M.Aws.IamRoles).Count | Should -Be 1
        $script:M.Aws.IamRoles[0].RoleName | Should -Be 'web-instance-role'
        @($script:M.Aws.IamRoles[0].AppliedTo) | Should -Be @('WEB01', 'WEB02')
    }
    It 'VPC を重複なくまとめ Subnet は別々に取り込む' {
        # 2 台は同一 VPC・別 Subnet。VPC は 1 件に畳まれる
        @($script:M.Aws.Vpcs).Count    | Should -Be 1
        @($script:M.Aws.Subnets).Count | Should -Be 2
    }
    It 'ルートテーブルを重複なくまとめる' {
        # 2 台が同じ rtb を参照しても 1 件
        @($script:M.Aws.RouteTables).Count | Should -Be 1
    }
    It 'aws JSON のあるサーバに Server.Aws を設定する' {
        ($script:M.Servers | Where-Object { $_.Hostname -eq 'WEB01' }).Aws | Should -Not -BeNullOrEmpty
        ($script:M.Servers | Where-Object { $_.Hostname -eq 'db01'  }).Aws | Should -BeNullOrEmpty
    }
}
