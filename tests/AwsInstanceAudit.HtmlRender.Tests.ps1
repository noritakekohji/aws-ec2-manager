#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Get-AwsInstanceAudit.ps1 の HTML レポートが python3 なしでも生成できることの担保。
# 以前は -HtmlReport 指定時に python3 が無いと exit 10 で止まっていた。現在は
# render_report.py を優先しつつ、python3 が無ければ PowerShell ネイティブ
# レンダラーへフォールバックする。python3 が入っていない業務端末でも
# HTML レポートを作れることが要件なので、PATH から python を隠して検証する。
#
# -FromJson は aws CLI を呼ばずに保存済み JSON からレポートを再生成するモードなので、
# EC2 外(IMDS 不在)のテスト環境でもレンダラーだけを検証できる。

# -Skip: の条件は discovery フェーズで評価されるため、python3 判定はここで行う。
$PythonAvailable = $false
foreach ($pyCandidate in @('python3', 'python', 'py')) {
    if (Get-Command $pyCandidate -ErrorAction SilentlyContinue) { $PythonAvailable = $true; break }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:AuditTool = Join-Path $repoRoot 'tools\aws-instance-audit\Get-AwsInstanceAudit.ps1'
    $script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "audit-html-$PID"
    if (Test-Path -LiteralPath $script:WorkDir) { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force }
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # 全セクション(instance/iam/sg/network)を含む監査 JSON。
    # タグ値に HTML 特殊文字を混ぜ、エスケープ漏れも検知できるようにする。
    $script:AuditJson = Join-Path $script:WorkDir 'audit.json'
    $audit = [ordered]@{
        meta = [ordered]@{
            hostname = 'TESTHOST'; instance_id = 'i-0123456789abcdef0'
            region = 'ap-northeast-1'; collected_at = '2026-08-06T10:00:00+09:00'
            categories = @('instance', 'iam', 'sg', 'network')
        }
        instance = [ordered]@{
            instance_id = 'i-0123456789abcdef0'; instance_type = 't3.medium'; state = 'running'
            tags = [ordered]@{ Name = 'test-web-01'; Desc = 'a<b>&c"d' }
        }
        iam = [ordered]@{
            role_name = 'TestRole'; role_arn = 'arn:aws:iam::123456789012:role/TestRole'
            attached_policies = @([ordered]@{ name = 'AmazonSSMManagedInstanceCore'; arn = 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore' })
            inline_policies = @('inline-s3-read')
        }
        security_groups = @(
            [ordered]@{
                group_id = 'sg-aaa'; group_name = 'web-sg'; description = 'web'; vpc_id = 'vpc-111'
                ingress = @(
                    [ordered]@{ protocol = 'tcp'; from_port = 443;  to_port = 443;  cidrs = @('0.0.0.0/0'); sg_refs = @() }
                    [ordered]@{ protocol = 'tcp'; from_port = 8000; to_port = 8100; cidrs = @(); sg_refs = @('sg-bbb') }
                )
                egress = @([ordered]@{ protocol = '-1'; from_port = $null; to_port = $null; cidrs = @('0.0.0.0/0'); sg_refs = @() })
            }
        )
        network = [ordered]@{
            vpc = [ordered]@{ vpc_id = 'vpc-111'; cidr = '10.0.0.0/16' }
            subnet = [ordered]@{ subnet_id = 'subnet-222'; cidr = '10.0.1.0/24' }
            enis = @([ordered]@{ eni_id = 'eni-333'; private_ip = '10.0.1.15'; groups = @('sg-aaa'); description = 'primary' })
            route_tables = @([ordered]@{ route_table_id = 'rtb-444'; routes = @(
                [ordered]@{ dest = '10.0.0.0/16'; target = 'local' }
                [ordered]@{ dest = '0.0.0.0/0';   target = 'igw-555' }
            ) })
        }
    }
    [System.IO.File]::WriteAllText($script:AuditJson, ($audit | ConvertTo-Json -Depth 12),
        (New-Object System.Text.UTF8Encoding($false)))

    # HidePython 指定時は PATH を Windows 標準ディレクトリだけに絞り、
    # python3 / python / py が見つからない状況を再現する。
    function Invoke-AuditRender {
        param([string]$HtmlPath, [switch]$HidePython)
        $savedPath = $env:PATH
        if ($HidePython) {
            $env:PATH = @(
                (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0'),
                (Join-Path $env:SystemRoot 'System32'),
                $env:SystemRoot
            ) -join ';'
        }
        try {
            $stdout = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass `
                -File $script:AuditTool -FromJson $script:AuditJson -HtmlReport $HtmlPath 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally {
            $env:PATH = $savedPath
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Stdout   = $stdout
            Html     = if (Test-Path -LiteralPath $HtmlPath) { [System.IO.File]::ReadAllText($HtmlPath) } else { '' }
        }
    }

    # HTML からタグを落として表示テキストだけを取り出す(レンダラー間の比較用)
    function Get-VisibleText {
        param([string]$Html)
        $s = [regex]::Replace($Html, '(?s)<style.*?</style>', '')
        $s = [regex]::Replace($s, '<[^>]+>', "`n")
        $s = [System.Net.WebUtility]::HtmlDecode($s)
        return @($s -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^Generated:' -and $_ -notmatch '^aws_instance_audit' })
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-AwsInstanceAudit HTML レポート (python3 なし)' {
    BeforeAll {
        $script:NoPy = Invoke-AuditRender -HtmlPath (Join-Path $script:WorkDir 'nopy.html') -HidePython
    }

    It 'PowerShell ネイティブレンダラーへフォールバックする' {
        $script:NoPy.Stdout | Should -Match 'PowerShell HTML renderer'
    }

    It '終了コード 0 で完了する' {
        $script:NoPy.ExitCode | Should -Be 0
    }

    It '全セクションを出力する' {
        $script:NoPy.Html | Should -Match 'インスタンス'
        $script:NoPy.Html | Should -Match 'IAM'
        $script:NoPy.Html | Should -Match 'Security Groups \(1\)'
        $script:NoPy.Html | Should -Match 'Route table rtb-444'
    }

    It 'ポート範囲と全ポートを正しく表記する' {
        $script:NoPy.Html | Should -Match '8000-8100'   # from/to が異なる場合は範囲表記
        $script:NoPy.Html | Should -Match '>all<'       # from/to とも null は all 表記
    }

    It 'JSON 由来の値を HTML エスケープする' {
        $script:NoPy.Html | Should -Match 'a&lt;b&gt;&amp;c'
        $script:NoPy.Html | Should -Not -Match '<b>&c'
    }
}

Describe 'Get-AwsInstanceAudit HTML レポート (python3 あり)' -Skip:(-not $PythonAvailable) {
    BeforeAll {
        $script:WithPy = Invoke-AuditRender -HtmlPath (Join-Path $script:WorkDir 'py.html')
        $script:NoPy2  = Invoke-AuditRender -HtmlPath (Join-Path $script:WorkDir 'nopy2.html') -HidePython
    }

    It 'render_report.py を使い、終了コード 0 で完了する' {
        $script:WithPy.ExitCode | Should -Be 0
        $script:WithPy.Stdout | Should -Not -Match 'PowerShell HTML renderer'
    }

    It 'PowerShell ネイティブ版と表示内容が一致する' {
        $pyText = Get-VisibleText -Html $script:WithPy.Html
        $psText = Get-VisibleText -Html $script:NoPy2.Html
        ($psText -join "`n") | Should -Be ($pyText -join "`n")
    }
}
