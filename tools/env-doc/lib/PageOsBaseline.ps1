# os-baseline.html — OS / ハードウェアの横断表。
# 共通軸は 1 表にまとめ、意味が OS で異なる項目は OS 別サブ表に分ける。

$script:EnvDocOsLabels = @{
    windows = 'Windows'
    linux   = 'Linux'
    unknown = '不明'
}

# security / tuning は OS で意味が異なるため、OS 別に参照先を切り替える。
# scriptblock のネストで変数を捕まえないよう、関数として切り出している。
function Get-EnvDocAccessControl {
    param($Server, [string]$OsType)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'security')) { return '__MISSING__' }
    if ($OsType -eq 'windows') {
        # security.uac は {EnableLUA:<int>, ConsentPromptBehaviorAdmin:<int>}。
        # PascalCase かつ 0/1 の整数。取得に失敗すると security.uac ごと null になりうる（監査 C05）
        $lua = Get-JsonValue -Object $Server.Snapshot -Path 'security.uac.EnableLUA'
        if ($null -eq $lua) { return 'UAC: -' }
        $st = if ([string]$lua -eq '1') { '有効' } else { '無効' }
        return ('UAC: {0}' -f $st)
    }
    # Linux の apparmor は {} / {available, summary} / {active} の 3 形。state キーは存在しない
    $aa = Get-JsonValue -Object $Server.Snapshot -Path 'security.apparmor'
    if ($null -eq $aa) { return 'AppArmor: -' }
    $summary = [string](Get-JsonValue -Object $aa -Path 'summary' -Default '')
    if ($summary) { return ('AppArmor: {0}' -f $summary) }
    $active = [string](Get-JsonValue -Object $aa -Path 'active' -Default '')
    if ($active) { return ('AppArmor: {0}' -f $active) }
    $available = Get-JsonValue -Object $aa -Path 'available'
    if ($null -ne $available) {
        if ($available) { return 'AppArmor: 利用可' }
        return 'AppArmor: 利用不可'
    }
    return 'AppArmor: -'
}

# scheduled は配列ではなくオブジェクト（監査 M08）。
# Windows: {scheduled_tasks:[], startup:[]} / Linux: {cron:[], systemd_timers:[]}
function Get-EnvDocScheduledSummary {
    param($Server, [string]$OsType)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'scheduled')) { return '__MISSING__' }
    $keys = if ($OsType -eq 'windows') { @('scheduled_tasks', 'startup') } else { @('cron', 'systemd_timers') }

    $parts = @()
    foreach ($k in $keys) {
        $n = @(Get-JsonValue -Object $Server.Snapshot -Path ('scheduled.{0}' -f $k) -Default @()).Count
        $parts += ('{0}: {1} 件' -f $k, $n)
    }
    return ($parts -join "`n")
}

function Get-EnvDocTuningSummary {
    param($Server, [string]$OsType)

    if (-not (Test-EnvDocCategory -Server $Server -Category 'tuning')) { return '__MISSING__' }
    if ($OsType -eq 'windows') {
        # power_plan ではなく power_scheme（powercfg の出力 1 行そのまま。ロケール依存: 監査 C12）
        $scheme = [string](Get-JsonValue -Object $Server.Snapshot -Path 'tuning.power_scheme' -Default '-')
        # pagefile は配列 [{path, initial_mb, maximum_mb}]。size_mb というキーは無い
        $pf = @(Get-JsonValue -Object $Server.Snapshot -Path 'tuning.pagefile' -Default @())
        $page = if ($pf.Count -eq 0) { 'なし' } else {
            (@($pf | ForEach-Object { '{0} ({1}-{2} MB)' -f $_.path, $_.initial_mb, $_.maximum_mb }) -join "`n")
        }
        return ("電源プラン: {0}`nページファイル: {1}" -f $scheme, $page)
    }
    $thp = [string](Get-JsonValue -Object $Server.Snapshot -Path 'tuning.thp_enabled' -Default '-')
    # cpu_governor は文字列配列。[string] キャストだと区切りが消えるので join する
    $gov = @(Get-JsonValue -Object $Server.Snapshot -Path 'tuning.cpu_governor' -Default @())
    $govText = if ($gov.Count -eq 0) { '-' } else { ($gov -join ', ') }
    return ("THP: {0}`nCPU ガバナー: {1}" -f $thp, $govText)
}

function Write-EnvDocOsBaselinePage {
    param([Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][string]$OutputRoot)

    $servers = @($Model.Servers)
    $body = New-Object System.Text.StringBuilder

    # ① OS 非依存の共通軸
    $commonRows = @(
        @{ Label = 'OS';            Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.os_name' -Default '-') } } }
        @{ Label = 'OS バージョン';  Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.os_version' -Default '-') } } }
        @{ Label = 'アーキテクチャ';  Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.architecture' -Default '-') } } }
        @{ Label = 'CPU';           Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.cpu_model' -Default '-') } } }
        @{ Label = 'CPU コア数';     Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.cpu_cores' -Default '-') } } }
        @{ Label = 'メモリ (GB)';    Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.total_memory_gb' -Default '-') } } }
        @{ Label = 'タイムゾーン';    Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.timezone' -Default '-') } } }
        @{ Label = '仮想化';         Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.hardware.virtualization' -Default '-') } } }
        @{ Label = '最終起動'; NoCompare = $true; Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'os' -Getter { param($x) [string](Get-JsonValue -Object $x.Snapshot -Path 'os.last_boot' -Default '-') } } }
    )
    [void]$body.Append((New-HtmlSection -Title '共通項目(横断)' -Body (New-EnvDocCrossTable -Model $Model -Servers $servers -Rows $commonRows)))

    # ② 意味が OS で異なる項目 → OS 別サブ表
    $osTypes = @($servers | Where-Object { $_.HasSnapshot } | ForEach-Object { $_.OsType } | Select-Object -Unique | Sort-Object)

    foreach ($osType in $osTypes) {
        $osServers = @($servers | Where-Object { $_.HasSnapshot -and $_.OsType -eq $osType })
        $label = if ($script:EnvDocOsLabels.ContainsKey($osType)) { $script:EnvDocOsLabels[$osType] } else { $osType }
        $title = '{0} ({1} 台)' -f $label, $osServers.Count

        $osRows = @(
            @{ Label = 'パッチ/更新'; Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'patches' -Getter { param($x) ('{0} 件' -f @(Get-JsonValue -Object $x.Snapshot -Path 'patches' -Default @()).Count) } } }
            @{ Label = 'パッケージ';  Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'packages' -Getter { param($x) ('{0} 件' -f @(Get-JsonValue -Object $x.Snapshot -Path 'packages' -Default @()).Count) } } }
            @{ Label = 'サービス';    Getter = { param($s) Get-EnvDocCategoryValue -Server $s -Category 'services' -Getter { param($x) ('{0} 件' -f @(Get-JsonValue -Object $x.Snapshot -Path 'services' -Default @()).Count) } } }
            @{ Label = 'スケジュール'; Arg = $osType; Getter = { param($s, $os) Get-EnvDocScheduledSummary -Server $s -OsType $os } }
            @{ Label = 'ファイアウォール'; Getter = { param($s) Get-EnvDocFirewallSummary -Server $s } }
            @{ Label = 'アクセス制御'; Arg = $osType; Getter = { param($s, $os) Get-EnvDocAccessControl -Server $s -OsType $os } }
            @{ Label = 'チューニング'; Arg = $osType; Getter = { param($s, $os) Get-EnvDocTuningSummary -Server $s -OsType $os } }
        )
        $sub = New-EnvDocCrossTable -Model $Model -Servers $osServers -Rows $osRows
        [void]$body.Append((New-HtmlSection -Title $title -Body $sub))
    }

    $html = New-HtmlPage -Title 'OS ベースライン' -SystemName $Model.System.Name -RelRoot '.' -Body $body.ToString()
    Write-HtmlFile -Path (Join-Path $OutputRoot 'os-baseline.html') -Content $html
}
