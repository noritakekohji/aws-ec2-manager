<#
.SYNOPSIS
    server-snapshot / aws-instance-audit の JSON と system.yaml から
    システム環境定義書(マルチページ静的 HTML)を生成する。

.EXAMPLE
    .\EnvDoc.ps1 -InputDir .\input -SystemFile .\system.yaml -OutputDir .\output
#>
[CmdletBinding()]
param(
    [string]$InputDir   = '.\input',
    [string]$SystemFile = '.\system.yaml',
    [string]$OutputDir  = '.\output',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$script:EnvDocRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:EnvDocRoot 'lib\YamlLite.ps1')
. (Join-Path $script:EnvDocRoot 'lib\Model.ps1')
. (Join-Path $script:EnvDocRoot 'lib\Compare.ps1')
. (Join-Path $script:EnvDocRoot 'lib\Html.ps1')
. (Join-Path $script:EnvDocRoot 'lib\PageIndex.ps1')
. (Join-Path $script:EnvDocRoot 'lib\PageServer.ps1')

function Write-EnvDocStubPage {
    param([hashtable]$Model, [string]$OutputRoot, [string]$FileName, [string]$Title)

    $target = Join-Path $OutputRoot $FileName
    if (Test-Path -LiteralPath $target) { return }
    $body = '<p class="missing">このページは未実装です。</p>'
    $html = New-HtmlPage -Title $Title -SystemName $Model.System.Name -RelRoot '.' -Body $body
    Write-HtmlFile -Path $target -Content $html
}

function Invoke-EnvDoc {
    param(
        [Parameter(Mandatory)][string]$InputDir,
        [Parameter(Mandatory)][string]$SystemFile,
        [Parameter(Mandatory)][string]$OutputDir,
        [switch]$Force
    )

    $systemDef = ConvertFrom-YamlLite -Path $SystemFile
    $inputs    = Read-EnvDocInput -InputDir $InputDir
    $model     = Build-EnvDocModel -SystemDef $systemDef -Inputs $inputs
    $model.Groups = Get-EnvDocCompareGroup -Model $model -SystemDef $systemDef

    $outputRoot = Join-Path $OutputDir $model.System.Id
    if (Test-Path -LiteralPath $outputRoot) {
        if (-not $Force) {
            throw "出力先が既に存在します: $outputRoot (上書きするには -Force を指定してください)"
        }
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    Write-EnvDocIndexPage -Model $model -OutputRoot $outputRoot
    foreach ($s in $model.Servers) {
        Write-EnvDocServerPage -Model $model -Server $s -OutputRoot $outputRoot
    }

    # ナビ先のリンク切れを防ぐスタブ(Task 7・8 で本実装に置き換える)
    Write-EnvDocStubPage -Model $model -OutputRoot $outputRoot -FileName 'aws.html'         -Title 'AWS 構成'
    Write-EnvDocStubPage -Model $model -OutputRoot $outputRoot -FileName 'network.html'     -Title 'ネットワーク'
    Write-EnvDocStubPage -Model $model -OutputRoot $outputRoot -FileName 'middleware.html'  -Title 'ミドルウェア'
    Write-EnvDocStubPage -Model $model -OutputRoot $outputRoot -FileName 'os-baseline.html' -Title 'OS ベースライン'

    Copy-Item -LiteralPath (Join-Path $script:EnvDocRoot 'assets') `
              -Destination (Join-Path $outputRoot 'assets') -Recurse -Force

    return $outputRoot
}

if (-not $env:ENVDOC_SKIP_MAIN) {
    try {
        $root = Invoke-EnvDoc -InputDir $InputDir -SystemFile $SystemFile -OutputDir $OutputDir -Force:$Force
        Write-Host "環境定義書を生成しました: $root"
        exit 0
    }
    catch {
        $msg = $_.Exception.Message
        Write-Error $msg
        if ($msg -like '*が見つかりません*') { exit 2 }
        if ($msg -like '*行 *' -or $msg -like '*system.*' -or $msg -like '*-Force*') { exit 1 }
        exit 4
    }
}
