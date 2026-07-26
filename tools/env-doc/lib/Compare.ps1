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

    # compare_groups が書かれていれば、自動グループ化は行わず明示指定のみを使う
    $explicit = $null
    if ($null -ne $SystemDef -and $SystemDef.Contains('compare_groups')) {
        $explicit = $SystemDef['compare_groups']
    }
    if ($null -ne $explicit -and @($explicit).Count -gt 0) {
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
            $v = $null
            if ($ValuesByKey.ContainsKey($k)) { $v = $ValuesByKey[$k] }
            # 欠損と空文字は同じ扱いにする(片方が未収集というだけで不一致にしない)
            $values += [string]$v
        }
        if (@($values | Select-Object -Unique).Count -gt 1) { return $true }
    }
    return $false
}
