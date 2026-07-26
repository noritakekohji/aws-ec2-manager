# 入力 JSON の読み込みと中間モデルの構築。
# レンダラは snapshot JSON を直接参照せず、ここで作るモデルのみを見る。

function Get-JsonValue {
    param($Object, [string]$Path, $Default = $null)

    $cur = $Object
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$seg]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Get-EnvDocJsonKind {
    param($Json)

    $tool = Get-JsonValue -Object $Json -Path 'meta.tool'
    if ($tool -eq 'aws_instance_audit') { return 'aws' }

    $osType = Get-JsonValue -Object $Json -Path 'meta.os_type'
    $cats   = Get-JsonValue -Object $Json -Path 'meta.categories'
    if ($null -ne $osType -and $null -ne $cats) { return 'snapshot' }

    return 'unknown'
}

function Read-EnvDocInput {
    param([Parameter(Mandatory)][string]$InputDir)

    if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
        throw "入力ディレクトリが見つかりません: $InputDir"
    }

    $result = @{
        Snapshots = @{}
        Aws       = @{}
        Warnings  = @()
    }

    $files = @(Get-ChildItem -LiteralPath $InputDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object Name)

    foreach ($f in $files) {
        # Get-Content は CP932 環境で日本語を破壊するため使わない
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        $json = $null
        try {
            $json = ConvertFrom-Json $text
        }
        catch {
            $result.Warnings += "$($f.Name): JSON として読めませんでした。スキップします"
            continue
        }

        $kind = Get-EnvDocJsonKind -Json $json
        if ($kind -eq 'unknown') {
            $result.Warnings += "$($f.Name): server-snapshot / aws-instance-audit のいずれでもありません。スキップします"
            continue
        }

        $hostName = [string](Get-JsonValue -Object $json -Path 'meta.hostname' -Default '')
        if ($hostName -eq '') {
            $result.Warnings += "$($f.Name): meta.hostname が空です。スキップします"
            continue
        }
        # Linux は小文字、Windows は大文字を返すため、キーは小文字に正規化する
        $key = $hostName.ToLowerInvariant()

        if ($kind -eq 'snapshot') {
            if ($result.Snapshots.ContainsKey($key)) {
                $result.Warnings += "$($f.Name): ホスト $hostName の snapshot が重複しています。後勝ちで上書きします"
            }
            $result.Snapshots[$key] = $json
        }
        else {
            if ($result.Aws.ContainsKey($key)) {
                $result.Warnings += "$($f.Name): ホスト $hostName の aws 監査が重複しています。後勝ちで上書きします"
            }
            $result.Aws[$key] = $json
        }
    }

    return $result
}
