# 比較グループの決定と、横断表の行単位の不一致判定。
#
# Windows と Linux でカーネルが違うのは当然であり、全台一括で比較すると
# すべての行が強調されて意味を失う。そのため比較はグループ内でのみ行う。

function Get-EnvDocCompareGroup {
    param(
        [Parameter(Mandatory)][hashtable]$Model,
        $SystemDef
    )

    $byKey = @{}
    foreach ($s in $Model.Servers) { $byKey[$s.Key] = $s }

    # compare_groups が書かれていれば、自動グループ化は行わず明示指定のみを使う。
    # 空配列 (compare_groups: []) は「比較しない」という明示的な意思表示として扱い、
    # 自動グループ化にフォールバックしない(暗黙に差し替わると判定根拠が読み手に分からなくなる)
    $hasExplicit = ($null -ne $SystemDef -and $SystemDef.Contains('compare_groups'))
    $explicit = $null
    if ($hasExplicit) { $explicit = $SystemDef['compare_groups'] }
    if ($hasExplicit) {
        $groups = New-Object System.Collections.ArrayList
        foreach ($g in @($explicit)) {
            $name = [string]$g['name']
            if ([string]::IsNullOrWhiteSpace($name)) { $name = '(名称なし)' }
            $members = New-Object System.Collections.ArrayList
            foreach ($h in @($g['servers'])) {
                $k = ([string]$h).ToLowerInvariant()
                if ($byKey.ContainsKey($k)) { [void]$members.Add($k) }
            }
            [void]$groups.Add(@{ Name = $name; MemberKeys = @($members.ToArray()) })
        }
        # 要素 1 個の配列は return でアンロールされ、$g[0] がハッシュテーブルの
        # キー参照になってしまうため、カンマ演算子で配列のまま返す
        return , @($groups.ToArray())
    }

    # 自動グループ化: 同一 os_type × 同一 role。
    # role 未設定は意図せず束ねられることを避けるため対象外とする。
    $buckets = [ordered]@{}
    foreach ($s in $Model.Servers) {
        if (-not $s.HasSnapshot) { continue }
        if ([string]::IsNullOrWhiteSpace($s.Role)) { continue }
        # 区切りは role に現れない文字列にする(`u{} は PS 6 以降の構文なので使わない)
        $bk = '{0}||{1}' -f $s.OsType, $s.Role
        if (-not $buckets.Contains($bk)) {
            $buckets[$bk] = @{ Name = "$($s.Role) / $($s.OsType)"; MemberKeys = (New-Object System.Collections.ArrayList) }
        }
        [void]$buckets[$bk].MemberKeys.Add($s.Key)
    }

    $result = New-Object System.Collections.ArrayList
    foreach ($bk in $buckets.Keys) {
        [void]$result.Add(@{ Name = $buckets[$bk].Name; MemberKeys = @($buckets[$bk].MemberKeys.ToArray()) })
    }
    return , @($result.ToArray())
}

function Test-EnvDocMismatch {
    param(
        [Parameter(Mandatory)][hashtable]$ValuesByKey,
        $Groups
    )

    foreach ($g in @($Groups)) {
        $keys = @($g.MemberKeys)
        if ($keys.Count -lt 2) { continue }

        $values = @()
        foreach ($k in $keys) {
            # ValuesByKey に登録されていないキーは「そのサーバは未収集」を意味する
            # (呼び出し側が __MISSING__ / HasSnapshot=false を意図的に登録しない設計)。
            # 欠損を空文字として扱って比較対象に含めると、他サーバの実値と食い違って
            # 誤って不一致になるため、比較対象自体から除外する
            if (-not $ValuesByKey.ContainsKey($k)) { continue }
            # 欠損(この関数内では登録済みだが null)と空文字は同じ扱いにする
            $values += [string]$ValuesByKey[$k]
        }
        if (@($values | Select-Object -Unique).Count -gt 1) { return $true }
    }
    return $false
}
