#Requires -Version 5.1
<#
.SYNOPSIS
    現在の EC2 インスタンスの AWS コンテキスト（IAM ロール / Security Group /
    VPC・Subnet・ENI・Route / メタデータ・タグ）を IMDSv2 + AWS CLI で収集して
    JSON 出力する。Linux 版 aws_instance_audit.sh と同等。

.DESCRIPTION
    tools/ 配下の自己完結スクリプト（lib 非依存）。EC2 インスタンス上で実行する
    ことを前提とし、IMDSv2 で自分のメタデータを取得し、aws CLI で詳細を引く。
    JSON 組み立ても HTML レポート生成も PowerShell ネイティブで行うため python3 は
    不要。python3 がある場合のみ render_report.py を使う（プラットフォーム間で
    出力が揃うため）。

.PARAMETER Category
    収集カテゴリ。all / instance / iam / sg / network（カンマ区切り可）。既定: all

.PARAMETER OutputPath
    JSON 出力先。既定: aws_audit_<instance-id>_<ts>.json

.PARAMETER HtmlReport
    HTML レポート出力先（python3 は任意）。

.PARAMETER Region
    リージョン上書き（既定: IMDS から自動取得）。

.EXAMPLE
    .\Get-AwsInstanceAudit.ps1
    .\Get-AwsInstanceAudit.ps1 -Category iam,sg -OutputPath audit.json -HtmlReport audit.html

.NOTES
    終了コード: 0 成功 / 1 引数不正 / 2 IMDS 到達不可 / 5 出力失敗 /
                10 aws CLI 不在 / 20 認証・権限エラー
#>
[CmdletBinding()]
param(
    [string]$Category = 'all',
    [string]$OutputPath = '',
    [string]$HtmlReport = '',
    [string]$Region = '',
    [string]$FromJson = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ImdsBase = 'http://169.254.169.254/latest'
$TokenTtl = 21600
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$renderPy  = Join-Path $scriptDir 'render_report.py'

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [Console]::Error.WriteLine("[$ts] [$Level] $Message")
}

function Want([string]$cat) {
    if ($Category -eq 'all') { return $true }
    return ($Category -split ',' | ForEach-Object { $_.Trim() }) -contains $cat
}

# StrictMode 下で「存在しないプロパティ」へのアクセスは例外になるため、
# aws CLI の JSON から省略されうるフィールドはこのヘルパー経由で安全に取り出す。
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $pp = $obj.PSObject.Properties[$name]
    if ($pp) { return $pp.Value }
    return $null
}

# ══════════════════════════════════════════════════════════════
# HTML レポート生成
#   python3 があれば render_report.py（プラットフォーム間で出力が揃う）を使い、
#   無ければ以下の PowerShell ネイティブレンダラーで同等の HTML を生成する。
#   python3 が使えない業務端末でも HTML レポートを作れるようにするため、
#   python3 は必須ではない。
# ══════════════════════════════════════════════════════════════

function ConvertTo-AuditHtmlText($Value) {
    # JSON 由来の値をそのまま HTML に埋め込むとインジェクションになるためエスケープする
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Format-AuditValue($Value) {
    if ($null -eq $Value) { return '' }
    # 配列は python 版と同様にカンマ区切りの 1 行へ畳む（文字列は列挙しない）
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ((@($Value) | ForEach-Object { [string]$_ }) -join ', ')
    }
    return [string]$Value
}

function New-AuditKvRows($Obj, [string[]]$ExcludeNames = @()) {
    if ($null -eq $Obj) { return '' }
    $rows = ''
    foreach ($p in $Obj.PSObject.Properties) {
        if ($ExcludeNames -contains $p.Name) { continue }
        $k = ConvertTo-AuditHtmlText $p.Name
        $v = ConvertTo-AuditHtmlText (Format-AuditValue $p.Value)
        $rows += "<tr><td class='k'>$k</td><td>$v</td></tr>"
    }
    return $rows
}

function New-AuditKvTable($Obj, [string[]]$ExcludeNames = @()) {
    $rows = New-AuditKvRows $Obj $ExcludeNames
    if (-not $rows) { return '' }
    return "<table class='kv'><tbody>$rows</tbody></table>"
}

function New-AuditSection([string]$Title, [string]$Body) {
    if (-not $Body) { return '' }
    return @"

<div class="section">
  <div class="section-title">$(ConvertTo-AuditHtmlText $Title)</div>
  $Body
</div>
"@
}

function New-AuditInstanceSection($Inst) {
    if ($null -eq $Inst) { return '' }
    $body = New-AuditKvTable $Inst @('tags')
    $tags = Get-Prop $Inst 'tags'
    if ($null -ne $tags) {
        $tagRows = New-AuditKvRows $tags
        if ($tagRows) {
            $body += "<div class='subtitle'>Tags</div><table class='kv'><tbody>$tagRows</tbody></table>"
        }
    }
    return New-AuditSection 'インスタンス' $body
}

function New-AuditIamSection($Iam) {
    if ($null -eq $Iam) { return '' }
    $roleName = ConvertTo-AuditHtmlText (Get-Prop $Iam 'role_name')
    $roleArn  = ConvertTo-AuditHtmlText (Get-Prop $Iam 'role_arn')
    $body = "<table class='kv'><tbody><tr><td class='k'>role_name</td><td>$roleName</td></tr>" +
            "<tr><td class='k'>role_arn</td><td>$roleArn</td></tr></tbody></table>"

    # Where-Object の結果が 1 件だと配列がスカラーへアンラップされ、StrictMode 下で
    # .Count 参照が例外になる。外側を @() で包んで必ず配列にする。
    $attached = @(@(Get-Prop $Iam 'attached_policies') | Where-Object { $null -ne $_ })
    if ($attached.Count -gt 0) {
        $rows = ''
        foreach ($p in $attached) {
            $n = ConvertTo-AuditHtmlText (Get-Prop $p 'name')
            $a = ConvertTo-AuditHtmlText (Get-Prop $p 'arn')
            $rows += "<tr><td>$n</td><td class='mono'>$a</td></tr>"
        }
        $body += "<div class='subtitle'>Attached managed policies</div>" +
                 "<table><thead><tr><th>Name</th><th>ARN</th></tr></thead><tbody>$rows</tbody></table>"
    }

    $inline = @(@(Get-Prop $Iam 'inline_policies') | Where-Object { $null -ne $_ })
    if ($inline.Count -gt 0) {
        $items = ''
        foreach ($n in $inline) { $items += "<li>$(ConvertTo-AuditHtmlText $n)</li>" }
        $body += "<div class='subtitle'>Inline policies</div><ul>$items</ul>"
    }

    if ($attached.Count -eq 0 -and $inline.Count -eq 0) {
        $body += "<p class='muted'>（アタッチされたポリシーなし、または取得権限なし）</p>"
    }
    return New-AuditSection 'IAM ロール / ポリシー' $body
}

function New-AuditPermRows($Perms) {
    $rows = ''
    foreach ($p in @($Perms)) {
        if ($null -eq $p) { continue }
        $proto = ConvertTo-AuditHtmlText (Get-Prop $p 'protocol')
        $frm = Get-Prop $p 'from_port'
        $to  = Get-Prop $p 'to_port'
        if ($null -eq $frm -and $null -eq $to) {
            $port = 'all'
        } elseif ([string]$frm -eq [string]$to) {
            $port = [string]$frm
        } else {
            $port = "$frm-$to"
        }
        $targets = @()
        foreach ($c in @(Get-Prop $p 'cidrs'))   { if ($null -ne $c) { $targets += [string]$c } }
        foreach ($s in @(Get-Prop $p 'sg_refs')) { if ($null -ne $s) { $targets += [string]$s } }
        $tgt = if ($targets.Count -gt 0) { $targets -join ', ' } else { '-' }
        $rows += "<tr><td>$proto</td><td>$(ConvertTo-AuditHtmlText $port)</td>" +
                 "<td class='mono'>$(ConvertTo-AuditHtmlText $tgt)</td></tr>"
    }
    if (-not $rows) { $rows = "<tr><td colspan='3' class='muted'>(なし)</td></tr>" }
    return $rows
}

function New-AuditSgSection($Sgs) {
    $groups = @(@($Sgs) | Where-Object { $null -ne $_ })
    if ($groups.Count -eq 0) { return '' }
    $blocks = ''
    foreach ($g in $groups) {
        $head = "<table class='kv'><tbody>"
        foreach ($k in 'group_id', 'group_name', 'description', 'vpc_id') {
            $head += "<tr><td class='k'>$k</td><td>$(ConvertTo-AuditHtmlText (Get-Prop $g $k))</td></tr>"
        }
        $head += "</tbody></table>"
        $ingress = "<div class='subtitle'>Ingress</div>" +
                   "<table><thead><tr><th>Proto</th><th>Port</th><th>Source</th></tr></thead>" +
                   "<tbody>$(New-AuditPermRows (Get-Prop $g 'ingress'))</tbody></table>"
        $egress  = "<div class='subtitle'>Egress</div>" +
                   "<table><thead><tr><th>Proto</th><th>Port</th><th>Destination</th></tr></thead>" +
                   "<tbody>$(New-AuditPermRows (Get-Prop $g 'egress'))</tbody></table>"
        $blocks += "<div class='card'>$head$ingress$egress</div>"
    }
    return New-AuditSection "Security Groups ($($groups.Count))" $blocks
}

function New-AuditNetworkSection($Net) {
    if ($null -eq $Net) { return '' }
    $body = ''
    $vpc = Get-Prop $Net 'vpc'
    if ($null -ne $vpc) {
        $t = New-AuditKvTable $vpc
        if ($t) { $body += "<div class='subtitle'>VPC</div>$t" }
    }
    $subnet = Get-Prop $Net 'subnet'
    if ($null -ne $subnet) {
        $t = New-AuditKvTable $subnet
        if ($t) { $body += "<div class='subtitle'>Subnet</div>$t" }
    }

    $enis = @(@(Get-Prop $Net 'enis') | Where-Object { $null -ne $_ })
    if ($enis.Count -gt 0) {
        $rows = ''
        foreach ($e in $enis) {
            $sgList = ((@(Get-Prop $e 'groups') | Where-Object { $null -ne $_ }) -join ', ')
            $rows += "<tr><td class='mono'>$(ConvertTo-AuditHtmlText (Get-Prop $e 'eni_id'))</td>" +
                     "<td>$(ConvertTo-AuditHtmlText (Get-Prop $e 'private_ip'))</td>" +
                     "<td class='mono'>$(ConvertTo-AuditHtmlText $sgList)</td>" +
                     "<td>$(ConvertTo-AuditHtmlText (Get-Prop $e 'description'))</td></tr>"
        }
        $body += "<div class='subtitle'>ENIs</div>" +
                 "<table><thead><tr><th>ENI</th><th>Private IP</th><th>SGs</th><th>Desc</th></tr></thead>" +
                 "<tbody>$rows</tbody></table>"
    }

    foreach ($rt in @(Get-Prop $Net 'route_tables')) {
        if ($null -eq $rt) { continue }
        $rows = ''
        foreach ($r in @(Get-Prop $rt 'routes')) {
            if ($null -eq $r) { continue }
            $rows += "<tr><td class='mono'>$(ConvertTo-AuditHtmlText (Get-Prop $r 'dest'))</td>" +
                     "<td class='mono'>$(ConvertTo-AuditHtmlText (Get-Prop $r 'target'))</td></tr>"
        }
        $body += "<div class='subtitle'>Route table $(ConvertTo-AuditHtmlText (Get-Prop $rt 'route_table_id'))</div>" +
                 "<table><thead><tr><th>Destination</th><th>Target</th></tr></thead><tbody>$rows</tbody></table>"
    }

    return New-AuditSection 'ネットワーク (VPC / Subnet / ENI / Route)' $body
}

function New-AuditHtmlDocument($Data) {
    $meta = Get-Prop $Data 'meta'
    $gen  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $body = (New-AuditInstanceSection (Get-Prop $Data 'instance')) +
            (New-AuditIamSection      (Get-Prop $Data 'iam')) +
            (New-AuditSgSection       (Get-Prop $Data 'security_groups')) +
            (New-AuditNetworkSection  (Get-Prop $Data 'network'))

    $mHost  = ConvertTo-AuditHtmlText (Get-Prop $meta 'hostname')
    $mInst  = ConvertTo-AuditHtmlText (Get-Prop $meta 'instance_id')
    $mRegn  = ConvertTo-AuditHtmlText (Get-Prop $meta 'region')
    $mColl  = ConvertTo-AuditHtmlText (Get-Prop $meta 'collected_at')
    $mCats  = ConvertTo-AuditHtmlText (Format-AuditValue (Get-Prop $meta 'categories'))
    $genEnc = ConvertTo-AuditHtmlText $gen

    return @"
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8">
<title>AWS Instance Audit Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}
.header{background:#232f3e;color:#fff;padding:20px 24px}
.header h1{font-size:20px;font-weight:700}
.header .sub{font-size:12px;color:#ff9900;margin-top:4px}
.meta-bar{display:flex;gap:14px;padding:12px 24px;flex-wrap:wrap;background:#fff;border-bottom:1px solid #e2e8f0}
.meta-item{font-size:12px;color:#475569}.meta-item span{font-weight:600;color:#1e293b;margin-left:4px}
.section{padding:16px 24px}
.section-title{font-size:15px;font-weight:700;color:#1e293b;margin-bottom:12px;padding-left:8px;border-left:3px solid #ff9900}
.subtitle{font-size:12px;font-weight:700;color:#475569;margin:12px 0 6px}
.card{background:#fff;border-radius:8px;padding:16px;margin-bottom:14px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08);margin-bottom:8px}
th{background:#f1f5f9;padding:7px 10px;text-align:left;font-weight:600;color:#475569;font-size:12px;border-bottom:2px solid #e2e8f0}
td{padding:6px 10px;border-bottom:1px solid #f1f5f9;font-size:12px;vertical-align:top;word-break:break-all}
tr:last-child td{border-bottom:none}
td.k{font-weight:600;color:#475569;width:200px}
.mono{font-family:Consolas,monospace;font-size:11px}
.muted{color:#94a3b8}
ul{margin-left:20px}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}
</style></head><body>
<div class="header">
  <h1>&#9729; AWS Instance Audit Report</h1>
  <div class="sub">Generated: $genEnc</div>
</div>
<div class="meta-bar">
  <div class="meta-item">Host<span>$mHost</span></div>
  <div class="meta-item">Instance<span>$mInst</span></div>
  <div class="meta-item">Region<span>$mRegn</span></div>
  <div class="meta-item">Collected<span>$mColl</span></div>
  <div class="meta-item">Categories<span>$mCats</span></div>
</div>
$body
<div class="footer">aws_instance_audit &bull; $genEnc</div>
</body></html>
"@
}

function Invoke-AuditHtmlRender([string]$JsonPath, [string]$HtmlPath) {
    $htmlDir = Split-Path -Parent $HtmlPath
    if ($htmlDir -and -not (Test-Path $htmlDir)) {
        New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null
    }

    # 1) python3 が使えるなら render_report.py を優先
    if (Test-Path -LiteralPath $renderPy) {
        $py = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $py) { $py = Get-Command py     -ErrorAction SilentlyContinue }
        if ($py) {
            & $py.Source $renderPy $JsonPath $HtmlPath
            if ($LASTEXITCODE -eq 0) { return $true }
            # Windows Store のダミー python は見つかっても実行できず exit 9009 を返す
            Write-Log 'WARN' "render_report.py exited with $LASTEXITCODE; falling back to the PowerShell renderer"
            $global:LASTEXITCODE = 0
        } else {
            Write-Log 'INFO' 'python3 not found - using the PowerShell HTML renderer'
        }
    }

    # 2) PowerShell ネイティブレンダラー
    try {
        $data = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc  = New-AuditHtmlDocument $data
        $utf8NoBomHtml = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($HtmlPath, $doc, $utf8NoBomHtml)
        return $true
    } catch {
        Write-Log 'ERROR' "HTML render failed: $($_.Exception.Message)"
        return $false
    }
}

# ── FromJson: 保存済み JSON からレポートを再生成（収集・aws CLI 不要）──
if ($FromJson) {
    if (-not (Test-Path -LiteralPath $FromJson)) {
        Write-Log 'ERROR' "FromJson file not found: $FromJson"
        exit 2
    }
    try {
        $fj = Get-Content -LiteralPath $FromJson -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log 'ERROR' "Failed to parse JSON: $FromJson"
        exit 1
    }
    if (-not (Get-Prop $fj 'meta')) {
        Write-Log 'ERROR' 'Invalid structure: top-level "meta" object not found'
        exit 1
    }

    # HTML レポート（入力は FromJson 自身。python3 があれば使い、無ければ PS ネイティブ）
    if ($HtmlReport) {
        if (-not (Invoke-AuditHtmlRender $FromJson $HtmlReport)) { exit 5 }
        Write-Log 'INFO' "HTML report: $HtmlReport"
    }

    # OutputPath 指定時は JSON をコピー
    if ($OutputPath) {
        $outDir = Split-Path -Parent $OutputPath
        if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        Copy-Item -LiteralPath $FromJson -Destination $OutputPath -Force
        Write-Log 'INFO' "JSON copied: $OutputPath"
    }

    $m = Get-Prop $fj 'meta'
    Write-Host ''
    Write-Host '  AWS instance audit (from JSON)'
    Write-Host "  instance_id : $([string](Get-Prop $m 'instance_id'))"
    Write-Host "  collected_at: $([string](Get-Prop $m 'collected_at'))"
    if ($OutputPath) { Write-Host "  JSON: $OutputPath" }
    if ($HtmlReport) { Write-Host "  HTML: $HtmlReport" }
    Write-Host ''
    exit 0
}

# ── 前提チェック ───────────────────────────────────────────────
$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCmd) { Write-Log 'ERROR' 'aws CLI not found in PATH'; exit 10 }

# HTML レポートは python3 があれば render_report.py、無ければ PowerShell ネイティブ
# レンダラーで生成するため、python3 の事前チェックは不要。

# ── AWS CLI 挙動の安定化 ───────────────────────────────────────
# AWS_PAGER='' : v2 のページャー入力待ちで固まるのを防ぐ
# タイムアウト / リトライ抑制で到達不可エンドポイント時の長時間ハングを防ぐ
$env:AWS_PAGER = ''
if (-not $env:AWS_MAX_ATTEMPTS) { $env:AWS_MAX_ATTEMPTS = '2' }
if (-not $env:AWS_RETRY_MODE)   { $env:AWS_RETRY_MODE   = 'standard' }
$AwsTimeoutOpts = @('--cli-connect-timeout', '5', '--cli-read-timeout', '30')

# ── IMDSv2 ─────────────────────────────────────────────────────
# IMDS はリンクローカル (169.254.169.254)。システムプロキシ経由になると
# 到達できず長時間ブロックするため、IMDS アクセスの間だけ既定プロキシを無効化する。
$script:savedProxy = $null
try { $script:savedProxy = [System.Net.WebRequest]::DefaultWebProxy } catch {}
try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch {}

function Get-ImdsToken {
    try {
        return Invoke-RestMethod -Method Put -Uri "$ImdsBase/api/token" `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = "$TokenTtl" } `
            -TimeoutSec 3 -ErrorAction Stop
    } catch { return $null }
}

$token = Get-ImdsToken
if (-not $token) {
    Write-Log 'ERROR' "Cannot reach IMDS ($ImdsBase). Not on an EC2 instance, or IMDS disabled."
    try { [System.Net.WebRequest]::DefaultWebProxy = $script:savedProxy } catch {}
    exit 2
}

function Get-Imds([string]$path) {
    try {
        return (Invoke-RestMethod -Method Get -Uri "$ImdsBase/meta-data/$path" `
            -Headers @{ 'X-aws-ec2-metadata-token' = $token } `
            -TimeoutSec 3 -ErrorAction Stop)
    } catch { return '' }
}

# ── メタデータ収集 ─────────────────────────────────────────────
$instanceId   = [string](Get-Imds 'instance-id')
$instanceType = [string](Get-Imds 'instance-type')
$amiId        = [string](Get-Imds 'ami-id')
$az           = [string](Get-Imds 'placement/availability-zone')
$localIp      = [string](Get-Imds 'local-ipv4')
$publicIp     = [string](Get-Imds 'public-ipv4')
$mac          = [string](Get-Imds 'mac')
if (-not $Region) { $Region = [string](Get-Imds 'placement/region') }
if (-not $Region -and $az) { $Region = $az.Substring(0, $az.Length - 1) }

$vpcId = ''; $subnetId = ''; $sgIdsRaw = ''
if ($mac) {
    $vpcId    = [string](Get-Imds "network/interfaces/macs/$mac/vpc-id")
    $subnetId = [string](Get-Imds "network/interfaces/macs/$mac/subnet-id")
    $sgIdsRaw = [string](Get-Imds "network/interfaces/macs/$mac/security-group-ids")
}
$iamRole = [string](Get-Imds 'iam/security-credentials/')

Write-Log 'INFO' "Instance: id=$instanceId type=$instanceType region=$Region vpc=$vpcId role=$(if($iamRole){$iamRole}else{'<none>'})"

$env:AWS_DEFAULT_REGION = $Region

if (-not $OutputPath) {
    $ts = (Get-Date).ToUniversalTime().AddHours(9).ToString('yyyyMMdd-HHmmss')
    $idPart = if ($instanceId) { $instanceId } else { 'unknown' }
    $OutputPath = "aws_audit_${idPart}_${ts}.json"
}

# ── aws CLI 呼び出し（生 JSON を ConvertFrom-Json で解析して返す）──
function Invoke-AwsObj {
    param([string[]]$AwsArgs)
    try {
        $raw = & aws @AwsArgs @AwsTimeoutOpts --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            return ($raw | ConvertFrom-Json)
        }
        Write-Log 'WARN' "aws $($AwsArgs -join ' ') failed (exit $LASTEXITCODE)"
        return $null
    } catch {
        Write-Log 'WARN' "aws $($AwsArgs -join ' ') error: $($_.Exception.Message)"
        return $null
    }
}

# SG の IpPermissions / IpPermissionsEgress を共通スキーマに正規化する。
# 戻り値はカンマ演算子 (, $out) で配列性を保ち、単一要素のアンロールを防ぐ。
function Convert-Perms($perms) {
    $out = @()
    foreach ($p in @($perms)) {
        if ($null -eq $p) { continue }
        $proto = [string](Get-Prop $p 'IpProtocol')
        if ($proto -eq '-1') { $proto = 'all' }

        $cidrs = @()
        foreach ($r in @(Get-Prop $p 'IpRanges'))    { $c = [string](Get-Prop $r 'CidrIp');    if ($c) { $cidrs += $c } }
        foreach ($r in @(Get-Prop $p 'Ipv6Ranges'))  { $c = [string](Get-Prop $r 'CidrIpv6');  if ($c) { $cidrs += $c } }

        $sgRefs = @()
        foreach ($g in @(Get-Prop $p 'UserIdGroupPairs')) { $s = [string](Get-Prop $g 'GroupId'); if ($s) { $sgRefs += $s } }

        $out += ,([ordered]@{
            protocol  = $proto
            from_port = Get-Prop $p 'FromPort'
            to_port   = Get-Prop $p 'ToPort'
            cidrs     = @($cidrs)
            sg_refs   = @($sgRefs)
        })
    }
    return ,@($out)
}

try {
    # 認証確認（生データは使わず、戻りコードのみ見る）
    & aws sts get-caller-identity @AwsTimeoutOpts --output json > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'ERROR' 'AWS auth failed (sts get-caller-identity)'
        exit 20
    }

    $nowJst = (Get-Date).ToUniversalTime().AddHours(9).ToString('yyyy-MM-dd HH:mm:ss')
    $result = [ordered]@{
        meta = [ordered]@{
            tool         = 'aws_instance_audit'
            collected_at = $nowJst
            hostname     = [string]$env:COMPUTERNAME
            region       = $Region
            instance_id  = $instanceId
            categories   = if ($Category) { $Category } else { 'all' }
        }
    }

    # ── instance + tags ────────────────────────────────────────
    if (Want 'instance') {
        $tags = [ordered]@{}
        if ($instanceId) {
            $td = Invoke-AwsObj @('ec2','describe-tags','--filters',"Name=resource-id,Values=$instanceId")
            foreach ($t in @(Get-Prop $td 'Tags')) {
                $k = [string](Get-Prop $t 'Key')
                if ($k) { $tags[$k] = [string](Get-Prop $t 'Value') }
            }
        }
        $result.instance = [ordered]@{
            instance_id       = $instanceId
            instance_type     = $instanceType
            ami_id            = $amiId
            availability_zone = $az
            region            = $Region
            private_ip        = $localIp
            public_ip         = $publicIp
            vpc_id            = $vpcId
            subnet_id         = $subnetId
            tags              = $tags
        }
    }

    # ── IAM ────────────────────────────────────────────────────
    if (Want 'iam') {
        $iam = [ordered]@{
            role_name         = $iamRole
            role_arn          = ''
            attached_policies = @()
            inline_policies   = @()
        }
        if ($iamRole) {
            Write-Log 'INFO' "Collecting IAM role/policies: $iamRole"
            $rj = Invoke-AwsObj @('iam','get-role','--role-name',$iamRole)
            $role = Get-Prop $rj 'Role'
            if ($role) {
                $iam.role_arn     = [string](Get-Prop $role 'Arn')
                $iam.create_date  = [string](Get-Prop $role 'CreateDate')
            }
            $aj = Invoke-AwsObj @('iam','list-attached-role-policies','--role-name',$iamRole)
            $att = @()
            foreach ($p in @(Get-Prop $aj 'AttachedPolicies')) {
                $att += ,([ordered]@{ name = [string](Get-Prop $p 'PolicyName'); arn = [string](Get-Prop $p 'PolicyArn') })
            }
            $iam.attached_policies = @($att)
            $ij = Invoke-AwsObj @('iam','list-role-policies','--role-name',$iamRole)
            $iam.inline_policies   = @(@(Get-Prop $ij 'PolicyNames') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
        $result.iam = $iam
    }

    # ── Security Groups ────────────────────────────────────────
    if (Want 'sg') {
        $sgs = @()
        if ($sgIdsRaw) {
            Write-Log 'INFO' 'Collecting security groups'
            $sgIds = @($sgIdsRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $sj = Invoke-AwsObj (@('ec2','describe-security-groups','--group-ids') + $sgIds)
            foreach ($g in @(Get-Prop $sj 'SecurityGroups')) {
                $sgs += ,([ordered]@{
                    group_id    = [string](Get-Prop $g 'GroupId')
                    group_name  = [string](Get-Prop $g 'GroupName')
                    description = [string](Get-Prop $g 'Description')
                    vpc_id      = [string](Get-Prop $g 'VpcId')
                    ingress     = Convert-Perms (Get-Prop $g 'IpPermissions')
                    egress      = Convert-Perms (Get-Prop $g 'IpPermissionsEgress')
                })
            }
        }
        $result.security_groups = @($sgs)
    }

    # ── Network ────────────────────────────────────────────────
    if (Want 'network') {
        Write-Log 'INFO' 'Collecting network (vpc/subnet/eni/route)'
        $net = [ordered]@{}

        if ($vpcId) {
            $vj = Invoke-AwsObj @('ec2','describe-vpcs','--vpc-ids',$vpcId)
            $v = @(Get-Prop $vj 'Vpcs') | Select-Object -First 1
            if ($v) {
                $net.vpc = [ordered]@{
                    vpc_id     = [string](Get-Prop $v 'VpcId')
                    cidr       = [string](Get-Prop $v 'CidrBlock')
                    is_default = [bool](Get-Prop $v 'IsDefault')
                }
            }
        }
        if ($subnetId) {
            $sj = Invoke-AwsObj @('ec2','describe-subnets','--subnet-ids',$subnetId)
            $s = @(Get-Prop $sj 'Subnets') | Select-Object -First 1
            if ($s) {
                $net.subnet = [ordered]@{
                    subnet_id     = [string](Get-Prop $s 'SubnetId')
                    cidr          = [string](Get-Prop $s 'CidrBlock')
                    az            = [string](Get-Prop $s 'AvailabilityZone')
                    map_public_ip = [bool](Get-Prop $s 'MapPublicIpOnLaunch')
                }
            }
        }
        if ($instanceId) {
            $ej = Invoke-AwsObj @('ec2','describe-network-interfaces','--filters',"Name=attachment.instance-id,Values=$instanceId")
            $enis = @()
            foreach ($e in @(Get-Prop $ej 'NetworkInterfaces')) {
                $groups = @()
                foreach ($g in @(Get-Prop $e 'Groups')) { $gid = [string](Get-Prop $g 'GroupId'); if ($gid) { $groups += $gid } }
                $enis += ,([ordered]@{
                    eni_id      = [string](Get-Prop $e 'NetworkInterfaceId')
                    private_ip  = [string](Get-Prop $e 'PrivateIpAddress')
                    subnet_id   = [string](Get-Prop $e 'SubnetId')
                    description = [string](Get-Prop $e 'Description')
                    groups      = @($groups)
                })
            }
            $net.enis = @($enis)
        }
        if ($vpcId) {
            $rj = Invoke-AwsObj @('ec2','describe-route-tables','--filters',"Name=vpc-id,Values=$vpcId")
            $rts = @()
            foreach ($r in @(Get-Prop $rj 'RouteTables')) {
                $routes = @()
                foreach ($rt in @(Get-Prop $r 'Routes')) {
                    $dest = [string](Get-Prop $rt 'DestinationCidrBlock')
                    if (-not $dest) { $dest = [string](Get-Prop $rt 'DestinationPrefixListId') }
                    $target = ''
                    foreach ($k in 'GatewayId','NatGatewayId','NetworkInterfaceId','TransitGatewayId') {
                        $tv = [string](Get-Prop $rt $k)
                        if ($tv) { $target = $tv; break }
                    }
                    $routes += ,([ordered]@{ dest = $dest; target = $target })
                }
                $rts += ,([ordered]@{ route_table_id = [string](Get-Prop $r 'RouteTableId'); routes = @($routes) })
            }
            $net.route_tables = @($rts)
        }
        $result.network = $net
    }

    # ── JSON 出力（PowerShell ネイティブ）──────────────────────
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $json = $result | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $json, $utf8NoBom)
    Write-Log 'INFO' "JSON written: $OutputPath"

    # ── HTML レポート（python3 があれば使い、無ければ PS ネイティブ）─────
    if ($HtmlReport) {
        if (-not (Invoke-AuditHtmlRender $OutputPath $HtmlReport)) { exit 5 }
        Write-Log 'INFO' "HTML report: $HtmlReport"
    }

    Write-Host ''
    Write-Host '  AWS instance audit complete'
    Write-Host "  JSON: $OutputPath"
    if ($HtmlReport) { Write-Host "  HTML: $HtmlReport" }
    Write-Host ''
    exit 0
}
finally {
    # IMDS 用に無効化した既定プロキシを元に戻す
    try { [System.Net.WebRequest]::DefaultWebProxy = $script:savedProxy } catch {}
}
