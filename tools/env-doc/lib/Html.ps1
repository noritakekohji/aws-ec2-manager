# HTML 生成の共通部品。
# snapshot 由来の値がマークアップとして解釈されないよう、すべて ConvertTo-HtmlText を通す。

$script:EnvDocNavItems = @(
    @{ Href = 'index.html';       Label = '概要' }
    @{ Href = 'aws.html';         Label = 'AWS' }
    @{ Href = 'network.html';     Label = 'ネットワーク' }
    @{ Href = 'middleware.html';  Label = 'ミドルウェア' }
    @{ Href = 'os-baseline.html'; Label = 'OS' }
)

function ConvertTo-HtmlText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    # '&' を最初に置換しないと二重エスケープになる
    $s = $Text.Replace('&', '&amp;')
    $s = $s.Replace('<', '&lt;').Replace('>', '&gt;')
    $s = $s.Replace('"', '&quot;').Replace("'", '&#39;')
    return $s
}

function New-HtmlCell {
    param([AllowNull()][string]$Text, [string]$Link = '')

    $t = ConvertTo-HtmlText -Text $Text
    if ([string]::IsNullOrWhiteSpace($Link)) { return $t }
    return ('<a href="{0}">{1}</a>' -f (ConvertTo-HtmlText -Text $Link), $t)
}

function New-HtmlTable {
    param([string[]]$Headers, $Rows)

    $rowArray = @($Rows)
    if ($rowArray.Count -eq 0) {
        return '<p class="empty">データなし</p>'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($h in $Headers) {
        [void]$sb.Append('<th>').Append((ConvertTo-HtmlText -Text $h)).Append('</th>')
    }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $rowArray) {
        $cls = ''
        if ($r.Mismatch) { $cls = ' class="mismatch"' }
        [void]$sb.Append('<tr').Append($cls).Append('>')
        foreach ($c in @($r.Cells)) {
            # Cells は呼び出し側でエスケープ済みの HTML 断片
            [void]$sb.Append('<td>').Append([string]$c).Append('</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function New-HtmlSection {
    param([string]$Title, [string]$Body)

    return ('<section><h2>{0}</h2>{1}</section>' -f (ConvertTo-HtmlText -Text $Title), $Body)
}

function New-HtmlPage {
    param(
        [string]$Title,
        [string]$SystemName,
        [string]$RelRoot,
        [string]$Body
    )

    $root = if ([string]::IsNullOrWhiteSpace($RelRoot)) { '.' } else { $RelRoot.TrimEnd('/') }

    $nav = New-Object System.Text.StringBuilder
    foreach ($item in $script:EnvDocNavItems) {
        [void]$nav.Append('<a href="').Append($root).Append('/').Append($item.Href).Append('">')
        [void]$nav.Append((ConvertTo-HtmlText -Text $item.Label)).Append('</a>')
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="ja">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine(('<title>{0} - {1}</title>' -f (ConvertTo-HtmlText -Text $Title), (ConvertTo-HtmlText -Text $SystemName)))
    [void]$sb.AppendLine(('<link rel="stylesheet" href="{0}/assets/style.css">' -f $root))
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine(('<header><div class="sys">{0}</div><nav>{1}</nav></header>' -f (ConvertTo-HtmlText -Text $SystemName), $nav.ToString()))
    [void]$sb.AppendLine(('<main><h1>{0}</h1>' -f (ConvertTo-HtmlText -Text $Title)))
    [void]$sb.AppendLine($Body)
    [void]$sb.AppendLine('</main>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')
    return $sb.ToString()
}

function Write-HtmlFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Out-File -Encoding utf8 は BOM が付くため使わない
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# 戻り値は「エスケープ済みの HTML 断片」。'未収集' は span を含むため、
# 呼び出し側で ConvertTo-HtmlText を通してはいけない（通すとタグが見えてしまう）
function Format-EnvDocMissing {
    param([bool]$Collected, [int]$Count)

    if (-not $Collected) { return '<span class="missing">未収集</span>' }
    if ($Count -eq 0) { return 'なし' }
    return ('{0} 件' -f $Count)
}
