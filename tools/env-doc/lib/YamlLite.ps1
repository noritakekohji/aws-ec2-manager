# YAML サブセットパーサ。外部モジュールに依存しない。
#
# 対応:   2 スペースインデントのマップ / '-' シーケンス / スカラ / '#' コメント /
#         クォート / [a, b] インラインシーケンス
# 非対応: タブ / アンカー / エイリアス / 複数行スカラ / フローマップ / ドキュメント区切り / タグ
#
# 静かに誤った値を読むことを避けるため、非対応構文は行番号付きで throw する。

function Remove-YamlLiteComment {
    param([string]$Text)
    $inSingle = $false
    $inDouble = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
        if ($c -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
        if ($c -eq '#' -and -not $inSingle -and -not $inDouble) {
            # '#' はコメント開始とみなす。ただし直前が空白でない場合は値の一部
            if ($i -eq 0 -or $Text[$i - 1] -eq ' ') { return $Text.Substring(0, $i) }
        }
    }
    return $Text
}

function Split-YamlLiteInlineItem {
    # インラインシーケンス [a, b] の中身をカンマで分割する。
    # 単純な -split ',' だと 'x, y' のようなクォート内のカンマまで区切ってしまい、
    # 例外を投げずに静かに誤った要素数を返すため、クォート状態を追跡して分割する。
    param([string]$Text, [int]$LineNo)

    $items = New-Object System.Collections.ArrayList
    $buffer = New-Object System.Text.StringBuilder
    $inSingle = $false
    $inDouble = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle }
        elseif ($c -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble }
        elseif ($c -eq ',' -and -not $inSingle -and -not $inDouble) {
            [void]$items.Add($buffer.ToString())
            $buffer = New-Object System.Text.StringBuilder
            continue
        }
        # クォート文字自体も残す(除去は ConvertTo-YamlLiteScalar が行う)
        [void]$buffer.Append($c)
    }
    if ($inSingle -or $inDouble) {
        throw "行 ${LineNo}: インラインシーケンスのクォートが閉じていません: [$Text]"
    }
    [void]$items.Add($buffer.ToString())
    return , $items.ToArray()
}

function ConvertTo-YamlLiteScalar {
    param([string]$Text, [int]$LineNo)

    $t = $Text.Trim()
    if ($t -eq '') { return $null }

    if ($t.StartsWith('&')) { throw "行 ${LineNo}: アンカー(&)は未対応です" }
    if ($t.StartsWith('*')) { throw "行 ${LineNo}: エイリアス(*)は未対応です" }
    if ($t.StartsWith('|') -or $t.StartsWith('>')) { throw "行 ${LineNo}: 複数行スカラ(| >)は未対応です" }
    if ($t.StartsWith('{')) { throw "行 ${LineNo}: フローマップ({})は未対応です" }
    if ($t.StartsWith('!')) { throw "行 ${LineNo}: タグ(!)は未対応です" }

    if ($t.StartsWith('[')) {
        if (-not $t.EndsWith(']')) { throw "行 ${LineNo}: インラインシーケンスが ']' で閉じていません" }
        $inner = $t.Substring(1, $t.Length - 2).Trim()
        if ($inner -eq '') { return , @() }
        $items = @()
        foreach ($part in (Split-YamlLiteInlineItem -Text $inner -LineNo $LineNo)) {
            $items += , (ConvertTo-YamlLiteScalar -Text $part -LineNo $LineNo)
        }
        return , $items
    }

    if ($t.Length -ge 2 -and $t.StartsWith("'") -and $t.EndsWith("'")) {
        return $t.Substring(1, $t.Length - 2).Replace("''", "'")
    }
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
        return $t.Substring(1, $t.Length - 2).Replace('\"', '"')
    }

    if (@('true', 'True', 'TRUE', 'yes', 'Yes') -contains $t) { return $true }
    if (@('false', 'False', 'FALSE', 'no', 'No') -contains $t) { return $false }
    if (@('null', 'Null', 'NULL', '~') -contains $t) { return $null }

    $intVal = 0
    if ([int]::TryParse($t, [ref]$intVal)) { return $intVal }
    $dblVal = 0.0
    if ([double]::TryParse($t, [ref]$dblVal)) { return $dblVal }

    return $t
}

function Get-YamlLiteToken {
    param([string[]]$Lines)

    $tokens = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $lineNo = $i + 1
        $raw = $Lines[$i]
        if ($raw -match '^\s*$') { continue }

        $indentMatch = [regex]::Match($raw, '^[ \t]*')
        if ($indentMatch.Value.Contains("`t")) {
            throw "行 ${lineNo}: タブインデントは未対応です。半角スペース 2 個を使ってください"
        }
        $indent = $indentMatch.Value.Length
        $body = (Remove-YamlLiteComment -Text $raw.Substring($indent)).TrimEnd()
        if ($body -eq '') { continue }

        if ($body -eq '---' -or $body -eq '...') {
            throw "行 ${lineNo}: ドキュメント区切り(--- ...)は未対応です"
        }
        if ($indent % 2 -ne 0) {
            throw "行 ${lineNo}: インデントは 2 の倍数にしてください(現在 $indent)"
        }

        [void]$tokens.Add([PSCustomObject]@{ LineNo = $lineNo; Indent = $indent; Text = $body })
    }
    return , $tokens.ToArray()
}

function Read-YamlLiteBlock {
    param($Tokens, [ref]$Index, [int]$Indent)

    $first = $Tokens[$Index.Value]
    if ($first.Text -eq '-' -or $first.Text.StartsWith('- ')) {
        return Read-YamlLiteSequence -Tokens $Tokens -Index $Index -Indent $Indent
    }
    return Read-YamlLiteMap -Tokens $Tokens -Index $Index -Indent $Indent
}

function Read-YamlLiteMapEntry {
    param($Token, $Tokens, [ref]$Index, [int]$Indent, $Map)

    $m = [regex]::Match($Token.Text, '^([^:]+):\s*(.*)$')
    if (-not $m.Success) {
        throw "行 $($Token.LineNo): 'キー: 値' の形式ではありません: $($Token.Text)"
    }
    $key = $m.Groups[1].Value.Trim()
    $val = $m.Groups[2].Value

    # 重複キーは YAML 仕様でもエラー。黙って後勝ちで上書きすると
    # typo で片方の値が消えたことに気づけないため、ここで落とす
    if ($Map.Contains($key)) {
        throw "行 $($Token.LineNo): キー '$key' が重複しています"
    }

    if ($val.Trim() -ne '') {
        $Map[$key] = ConvertTo-YamlLiteScalar -Text $val -LineNo $Token.LineNo
        return
    }
    # 値が空 → 次行以降が子ブロックかどうかで判定
    if ($Index.Value -lt $Tokens.Count -and $Tokens[$Index.Value].Indent -gt $Indent) {
        $childIndent = $Tokens[$Index.Value].Indent
        $Map[$key] = Read-YamlLiteBlock -Tokens $Tokens -Index $Index -Indent $childIndent
    }
    else {
        $Map[$key] = $null
    }
}

function Read-YamlLiteMap {
    # -Map を渡すと既存のマップに読み足す。シーケンス項目("- key: value" の続き)で
    # 別マップを作って後からマージすると重複キー検査を素通りしてしまうため、
    # 最初から同じマップに書き込ませる
    param($Tokens, [ref]$Index, [int]$Indent, $Map)

    $map = if ($null -eq $Map) { [ordered]@{} } else { $Map }
    while ($Index.Value -lt $Tokens.Count) {
        $tok = $Tokens[$Index.Value]
        if ($tok.Indent -lt $Indent) { break }
        if ($tok.Indent -gt $Indent) {
            throw "行 $($tok.LineNo): インデントが不正です(期待 $Indent、実際 $($tok.Indent))"
        }
        if ($tok.Text -eq '-' -or $tok.Text.StartsWith('- ')) { break }

        $Index.Value++
        Read-YamlLiteMapEntry -Token $tok -Tokens $Tokens -Index $Index -Indent $Indent -Map $map
    }
    return $map
}

function Read-YamlLiteSequence {
    param($Tokens, [ref]$Index, [int]$Indent)

    $list = New-Object System.Collections.ArrayList
    while ($Index.Value -lt $Tokens.Count) {
        $tok = $Tokens[$Index.Value]
        if ($tok.Indent -lt $Indent) { break }
        if ($tok.Indent -gt $Indent) {
            throw "行 $($tok.LineNo): インデントが不正です(期待 $Indent、実際 $($tok.Indent))"
        }
        if ($tok.Text -ne '-' -and -not $tok.Text.StartsWith('- ')) { break }

        if ($tok.Text -ne '-' -and $tok.Text.Substring(2).StartsWith(' ')) {
            throw "行 $($tok.LineNo): '- ' の後の余分な空白は未対応です"
        }
        $rest = if ($tok.Text -eq '-') { '' } else { $tok.Text.Substring(2) }
        $Index.Value++

        if ($rest -eq '') {
            if ($Index.Value -lt $Tokens.Count -and $Tokens[$Index.Value].Indent -gt $Indent) {
                $childIndent = $Tokens[$Index.Value].Indent
                [void]$list.Add((Read-YamlLiteBlock -Tokens $Tokens -Index $Index -Indent $childIndent))
            }
            else {
                [void]$list.Add($null)
            }
            continue
        }

        $m = [regex]::Match($rest, '^([^:]+):\s*(.*)$')
        if (-not $m.Success) {
            [void]$list.Add((ConvertTo-YamlLiteScalar -Text $rest -LineNo $tok.LineNo))
            continue
        }

        # "- key: value" 形式。'- ' の分だけ深い位置(Indent + 2)がこの項目のマップの基準
        $itemIndent = $Indent + 2
        $map = [ordered]@{}
        $synthetic = [PSCustomObject]@{ LineNo = $tok.LineNo; Indent = $itemIndent; Text = $rest }
        Read-YamlLiteMapEntry -Token $synthetic -Tokens $Tokens -Index $Index -Indent $itemIndent -Map $map

        if ($Index.Value -lt $Tokens.Count -and $Tokens[$Index.Value].Indent -eq $itemIndent) {
            [void](Read-YamlLiteMap -Tokens $Tokens -Index $Index -Indent $itemIndent -Map $map)
        }
        [void]$list.Add($map)
    }
    return , $list.ToArray()
}

function ConvertFrom-YamlLiteText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = $Text -split "`r`n|`n|`r"
    $tokens = Get-YamlLiteToken -Lines $lines
    if ($tokens.Count -eq 0) { return [ordered]@{} }

    $index = 0
    $result = Read-YamlLiteBlock -Tokens $tokens -Index ([ref]$index) -Indent $tokens[0].Indent
    if ($index -lt $tokens.Count) {
        throw "行 $($tokens[$index].LineNo): 解釈できない行が残っています: $($tokens[$index].Text)"
    }
    return $result
}

function ConvertFrom-YamlLite {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "YAML ファイルが見つかりません: $Path"
    }
    # Get-Content は CP932 環境で日本語を破壊するため使わない
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    try {
        return ConvertFrom-YamlLiteText -Text $text
    }
    catch {
        throw "$Path : $($_.Exception.Message)"
    }
}
