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
. (Join-Path $script:EnvDocRoot 'lib\PageNetwork.ps1')
. (Join-Path $script:EnvDocRoot 'lib\PageMiddleware.ps1')
. (Join-Path $script:EnvDocRoot 'lib\PageOsBaseline.ps1')
. (Join-Path $script:EnvDocRoot 'lib\PageAws.ps1')

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
    Add-EnvDocAwsModel -Model $model -Inputs $inputs
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

    Write-EnvDocNetworkPage    -Model $model -OutputRoot $outputRoot
    Write-EnvDocMiddlewarePage -Model $model -OutputRoot $outputRoot
    Write-EnvDocOsBaselinePage -Model $model -OutputRoot $outputRoot
    Write-EnvDocAwsPage        -Model $model -OutputRoot $outputRoot

    Copy-Item -LiteralPath (Join-Path $script:EnvDocRoot 'assets') `
              -Destination (Join-Path $outputRoot 'assets') -Recurse -Force

    return $outputRoot
}

if (-not $env:ENVDOC_SKIP_MAIN) {
    # $ErrorActionPreference = 'Stop' の下では Write-Error 自体が終了エラーになり、
    # 後続の exit 分岐に到達しない。エラー出力は [Console]::Error に直接書く。
    try {
        # 終了コードをメッセージ文字列の推測で決めると誤分類する。
        # 1 と 2 を分ける条件はここで明示的に判定する。
        if (-not (Test-Path -LiteralPath $SystemFile -PathType Leaf)) {
            [Console]::Error.WriteLine("システム定義 YAML が見つかりません: $SystemFile")
            exit 1
        }
        if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
            [Console]::Error.WriteLine("入力ディレクトリが見つかりません: $InputDir")
            exit 2
        }

        $root = Invoke-EnvDoc -InputDir $InputDir -SystemFile $SystemFile -OutputDir $OutputDir -Force:$Force
        Write-Host "環境定義書を生成しました: $root"
        exit 0
    }
    catch {
        $msg = $_.Exception.Message
        [Console]::Error.WriteLine($msg)
        # ここに来るのは入力の存在チェックを通過した後の失敗のみ。
        # 'system.' のような広いパターンは .NET 型名(System.Boolean 等)を巻き込むため使わない。
        if ($msg -like '*行 *:*' -or
            $msg -like '*system.id*' -or
            $msg -like '*system.name*' -or
            $msg -like '*system セクション*' -or
            $msg -like '*-Force*') { exit 1 }
        if ($msg -like '*JSON が見つかりません*') { exit 2 }
        exit 4
    }
}
