<#
.SYNOPSIS
    Left pane: instance list, filter, power actions, lock.
.DESCRIPTION
    インスタンス一覧の取得(非同期)・フィルタ・選択の一元管理。
    選択の変更は Update-SelectedInstanceDependents から右ペイン各タブへ伝搬する。
    PowerShell 5.1 compatible. App.ps1 から dot-source される。
#>

$instanceFilterBox = Find-Control -Name 'InstanceFilterBox'
$instanceFilterHint = Find-Control -Name 'InstanceFilterHint'
$instancesGrid = Find-Control -Name 'InstancesGrid'
$instanceEmptyText = Find-Control -Name 'InstanceEmptyText'
$instanceListProgressBar = Find-Control -Name 'InstanceListProgressBar'
$instanceCountText = Find-Control -Name 'InstanceCountText'
$refreshInstancesButton = Find-Control -Name 'RefreshInstancesButton'
$startInstanceButton = Find-Control -Name 'StartInstanceButton'
$stopInstanceButton = Find-Control -Name 'StopInstanceButton'
$restartInstanceButton = Find-Control -Name 'RestartInstanceButton'
$lockInstanceButton = Find-Control -Name 'LockInstanceButton'
$unlockInstanceButton = Find-Control -Name 'UnlockInstanceButton'
$selectedInstanceHeaderText = Find-Control -Name 'SelectedInstanceHeaderText'
$selectedInstanceSubText = Find-Control -Name 'SelectedInstanceSubText'
$noSelectionOverlay = Find-Control -Name 'NoSelectionOverlay'

$listPaneState = [PSCustomObject]@{
    SuppressSelection = $false
}

function Get-SelectedInstance {
    [CmdletBinding()]
    [OutputType([object])]
    param()
    $row = $instancesGrid.SelectedItem
    if ($null -eq $row) {
        Set-StatusText -Message 'インスタンス未選択'
        return $null
    }
    return $row
}

function Update-InstanceLockButtons {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $row = $instancesGrid.SelectedItem
    if ($null -eq $row) {
        $lockInstanceButton.IsEnabled = $false
        $unlockInstanceButton.IsEnabled = $false
        return
    }
    $locked = Test-InstanceLocked -InstanceId ([string]$row.InstanceId)
    $lockInstanceButton.IsEnabled = -not $locked
    $unlockInstanceButton.IsEnabled = $locked
}

function Test-InstanceOperationAllowed {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$OperationLabel
    )
    if (Test-InstanceLocked -InstanceId $InstanceId) {
        Set-StatusText -Message "$InstanceId はロック中のため $OperationLabel できません"
        Show-InfoDialog -Warning -Message "$InstanceId はロックされています。`n$OperationLabel は実行できません。`n必要な場合は先に「ロック解除」を行ってください。"
        Write-AppLog -Level 'WARN' -Message "ロック中のため操作ブロック: $OperationLabel $InstanceId"
        return $false
    }
    return $true
}

function Update-SelectedInstanceHeader {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        $selectedInstanceHeaderText.Text = 'インスタンス未選択'
        $selectedInstanceSubText.Text = ''
        $noSelectionOverlay.Visibility = [System.Windows.Visibility]::Visible
        return
    }
    $noSelectionOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    $name = [string](Get-InstancePropertyText -Instance $inst -Name 'Name')
    $lockedMark = if (Test-InstanceLocked -InstanceId ([string]$inst.InstanceId)) { ' [ロック中]' } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $selectedInstanceHeaderText.Text = "$($inst.InstanceId)$lockedMark"
    }
    else {
        $selectedInstanceHeaderText.Text = "$name ($($inst.InstanceId))$lockedMark"
    }
    $subParts = @()
    $subParts += [string](Get-InstancePropertyText -Instance $inst -Name 'State')
    $subParts += [string](Get-InstancePropertyText -Instance $inst -Name 'InstanceType')
    $subParts += [string](Get-InstancePropertyText -Instance $inst -Name 'Platform')
    $ip = [string](Get-InstancePropertyText -Instance $inst -Name 'PrivateIpAddress')
    if (-not [string]::IsNullOrWhiteSpace($ip)) { $subParts += $ip }
    $selectedInstanceSubText.Text = (($subParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '  |  ')
}

function Update-SelectedInstanceDependents {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI fan-out helper.')]
    [CmdletBinding()]
    param()
    Update-SelectedInstanceHeader
    if ($null -ne (Get-Command -Name Update-DetailTab -ErrorAction SilentlyContinue)) { Update-DetailTab }
    if ($null -ne (Get-Command -Name Update-SgTabForSelection -ErrorAction SilentlyContinue)) { Update-SgTabForSelection }
    if ($null -ne (Get-Command -Name Update-RoleTabForSelection -ErrorAction SilentlyContinue)) { Update-RoleTabForSelection }
    if ($null -ne (Get-Command -Name Update-SsmTabForSelection -ErrorAction SilentlyContinue)) { Update-SsmTabForSelection }
}

function Update-InstanceListView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    [object[]]$allItems = @($script:AppState.Items)
    foreach ($it in $allItems) {
        Add-InstanceLockMetadata -Instance $it | Out-Null
    }
    [object[]]$filtered = @(Get-FilteredInstances -Items $allItems -Filter $script:AppState.FilterText)

    $prevId = [string]$script:AppState.SelectedInstanceId

    $listPaneState.SuppressSelection = $true
    try {
        $instancesGrid.ItemsSource = $filtered
        if (-not [string]::IsNullOrWhiteSpace($prevId)) {
            $match = $filtered | Where-Object { [string]$_.InstanceId -eq $prevId } | Select-Object -First 1
            if ($null -ne $match) { $instancesGrid.SelectedItem = $match }
        }
    }
    finally {
        $listPaneState.SuppressSelection = $false
    }

    # フィルタで選択が外れた場合は選択解除として扱う
    $newId = $null
    if ($null -ne $instancesGrid.SelectedItem) { $newId = [string]$instancesGrid.SelectedItem.InstanceId }
    $script:AppState.SelectedInstanceId = $newId

    if ($allItems.Count -eq 0) {
        $instanceEmptyText.Visibility = [System.Windows.Visibility]::Visible
        $instanceCountText.Text = ''
    }
    else {
        $instanceEmptyText.Visibility = [System.Windows.Visibility]::Collapsed
        if ($filtered.Count -eq $allItems.Count) {
            $instanceCountText.Text = "$($allItems.Count) 件"
        }
        else {
            $instanceCountText.Text = "$($filtered.Count) / $($allItems.Count) 件"
        }
    }

    Update-InstanceLockButtons
    Update-SelectedInstanceDependents
}

function Update-InstanceListAsync {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts async refresh by design.')]
    [CmdletBinding()]
    param([switch]$Force)

    $name = Get-SelectedProfile
    if ($null -eq $name) {
        Update-InstanceListView
        return
    }
    if ((-not $Force) -and $script:AppState.HasLoaded -and $script:AppState.Profile -eq $name) {
        Update-InstanceListView
        Set-StatusText -Message "キャッシュ済みインスタンス $(@($script:AppState.Items).Count) 件を表示しました（再取得は更新ボタン）"
        return
    }

    $instanceListProgressBar.Visibility = [System.Windows.Visibility]::Visible
    Set-StatusText -Message "インスタンス一覧を取得中… ($name)"

    $started = Start-AsyncTask -Name 'インスタンス一覧取得' -Work {
        param($Channel, $ReportProgress, $profileName)
        # @() で包むと unary-comma 返り値が「1 要素 = 配列まるごと」に化けるので使わない
        [object[]]$items = Get-Ec2Instances -Profile $profileName
        if ($null -eq $items) { $items = @() }
        return , $items
    } -ArgumentList @([string]$name) -OnSuccess {
        param($result)
        $instanceListProgressBar.Visibility = [System.Windows.Visibility]::Collapsed
        [object[]]$items = @($result)
        $currentProfile = [string]$profileComboBox.SelectedItem
        $script:AppState.Profile = $currentProfile
        $script:AppState.Items = $items
        $script:AppState.HasLoaded = $true
        $script:AppState.LastUpdated = Get-Date
        Clear-InstanceScopedCaches
        Update-InstanceListView
        Set-StatusText -Message "インスタンス $($items.Count) 件を更新しました"
        Write-AppLog -Level 'INFO' -Message "インスタンス一括更新: $($items.Count) 件 (Profile=$currentProfile)"
    } -OnError {
        param($err)
        $instanceListProgressBar.Visibility = [System.Windows.Visibility]::Collapsed
        Set-StatusText -Message "インスタンス取得エラー: $err"
        Write-AppLog -Level 'ERROR' -Message "インスタンス取得エラー: $err"
        Update-InstanceListView
    }
    if (-not $started) {
        $instanceListProgressBar.Visibility = [System.Windows.Visibility]::Collapsed
        Set-StatusText -Message '他のタスクを実行中です。完了後に再度お試しください。'
    }
}

function Update-SingleInstanceAsync {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts async refresh by design.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter()][AllowNull()][scriptblock]$After = $null
    )
    $name = Get-SelectedProfile
    if ($null -eq $name) { return }

    # SG/ロール変更や電源操作の後に副次項目を手組みすると食い違いの元になるため、
    # 対象 1 台だけ AWS から取り直して丸ごと差し替える。
    $started = Start-AsyncTask -Name "インスタンス情報更新: $InstanceId" -Work {
        param($Channel, $ReportProgress, $profileName, $targetId)
        [object[]]$fresh = Get-Ec2Instances -Profile $profileName -InstanceIds @($targetId)
        if ($null -eq $fresh) { $fresh = @() }
        return , $fresh
    } -ArgumentList @([string]$name, [string]$InstanceId) -Context @{ After = $After; InstanceId = [string]$InstanceId } -OnSuccess {
        param($result, $ctx)
        [object[]]$fresh = @($result)
        if ($fresh.Count -gt 0) {
            $updated = $fresh[0]
            $items = New-Object System.Collections.Generic.List[object]
            $targetId = [string]$updated.InstanceId
            foreach ($it in @($script:AppState.Items)) {
                if ([string]$it.InstanceId -eq $targetId) { $items.Add($updated) }
                else { $items.Add($it) }
            }
            $script:AppState.Items = $items.ToArray()
            Update-InstanceListView
        }
        else {
            Write-AppLog -Level 'WARN' -Message "変更後のインスタンス再取得で 0 件: $($ctx.InstanceId)"
        }
        if ($null -ne $ctx.After) { & $ctx.After }
    } -OnError {
        param($err, $ctx)
        Write-AppLog -Level 'WARN' -Message "変更後のインスタンス再取得に失敗: $err"
        Set-StatusText -Message "インスタンス再取得エラー: $err"
        if ($null -ne $ctx.After) { & $ctx.After }
    }
    if (-not $started) {
        Set-StatusText -Message '他のタスクを実行中のためインスタンス情報を再取得できませんでした（更新ボタンで反映）'
    }
}

function Invoke-InstanceActionAsync {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven EC2 power operation.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActionLabel,
        [Parameter(Mandatory = $true)][ValidateSet('Start', 'Stop', 'Restart')][string]$Verb
    )
    try {
        $name = Get-SelectedProfile
        if ($null -eq $name) { return }
        $row = Get-SelectedInstance
        if ($null -eq $row) { return }
        $instanceId = [string]$row.InstanceId
        if (-not (Test-InstanceOperationAllowed -InstanceId $instanceId -OperationLabel $ActionLabel)) { return }
        if (-not (Show-ConfirmDialog -Message "$instanceId を $ActionLabel しますか？")) {
            Set-StatusText -Message "$ActionLabel をキャンセルしました"
            return
        }

        Set-StatusText -Message "$instanceId を $ActionLabel 中…"
        Write-AppLog -Level 'INFO' -Message "インスタンス操作開始: $ActionLabel $instanceId"

        $started = Start-AsyncTask -Name "${ActionLabel}: $instanceId" -Work {
            param($Channel, $ReportProgress, $profileName, $targetId, $verb)
            switch ($verb) {
                'Start'   { return (Start-Ec2Instance -Profile $profileName -InstanceId $targetId) }
                'Stop'    { return (Stop-Ec2Instance -Profile $profileName -InstanceId $targetId) }
                'Restart' { return (Restart-Ec2Instance -Profile $profileName -InstanceId $targetId) }
            }
        } -ArgumentList @([string]$name, $instanceId, $Verb) -Context @{ ActionLabel = $ActionLabel; InstanceId = $instanceId } -OnSuccess {
            param($result, $ctx)
            if ($result) {
                Set-StatusText -Message "$($ctx.InstanceId) の $($ctx.ActionLabel) 要求を送信しました。状態を再取得しています…"
                Write-AppLog -Level 'INFO' -Message "インスタンス操作完了: $($ctx.ActionLabel) $($ctx.InstanceId)"
                Update-SingleInstanceAsync -InstanceId ([string]$ctx.InstanceId)
            }
            else {
                Set-StatusText -Message "$($ctx.InstanceId) の $($ctx.ActionLabel) に失敗しました"
                Write-AppLog -Level 'ERROR' -Message "インスタンス操作失敗: $($ctx.ActionLabel) $($ctx.InstanceId)"
            }
        } -OnError {
            param($err, $ctx)
            Set-StatusText -Message "$($ctx.ActionLabel) エラー: $err"
            Write-AppLog -Level 'ERROR' -Message "インスタンス操作エラー: $($ctx.ActionLabel) - $err"
        }
        if (-not $started) {
            Set-StatusText -Message '他のタスクを実行中です。完了後に再度お試しください。'
        }
    }
    catch {
        Set-StatusText -Message "エラー: $($_.Exception.Message)"
        Write-AppLog -Level 'ERROR' -Message "インスタンス操作エラー: $ActionLabel - $($_.Exception.Message)"
    }
}

$instanceFilterBox.Add_TextChanged({
        try {
            $text = [string]$instanceFilterBox.Text
            if ([string]::IsNullOrEmpty($text)) {
                $instanceFilterHint.Visibility = [System.Windows.Visibility]::Visible
            }
            else {
                $instanceFilterHint.Visibility = [System.Windows.Visibility]::Collapsed
            }
            $script:AppState.FilterText = $text
            Update-InstanceListView
        }
        catch {
            Set-StatusText -Message "フィルタエラー: $($_.Exception.Message)"
        }
    })

$instancesGrid.Add_SelectionChanged({
        try {
            if ($listPaneState.SuppressSelection) { return }
            $row = $instancesGrid.SelectedItem
            if ($null -ne $row) {
                $script:AppState.SelectedInstanceId = [string]$row.InstanceId
            }
            else {
                $script:AppState.SelectedInstanceId = $null
            }
            Update-InstanceLockButtons
            Update-SelectedInstanceDependents
        }
        catch {
            Set-StatusText -Message "選択エラー: $($_.Exception.Message)"
        }
    })

$instancesGrid.Add_MouseDoubleClick({
        try {
            if ($null -ne $instancesGrid.SelectedItem) {
                $detailTabs = Find-Control -Name 'DetailTabs'
                $detailTabs.SelectedIndex = 0
            }
        }
        catch {
            Set-StatusText -Message "詳細表示エラー: $($_.Exception.Message)"
        }
    })

$refreshInstancesButton.Add_Click({
        Update-InstanceListAsync -Force
    })

$startInstanceButton.Add_Click({
        Invoke-InstanceActionAsync -ActionLabel '起動' -Verb 'Start'
    })

$stopInstanceButton.Add_Click({
        Invoke-InstanceActionAsync -ActionLabel '停止' -Verb 'Stop'
    })

$restartInstanceButton.Add_Click({
        Invoke-InstanceActionAsync -ActionLabel '再起動' -Verb 'Restart'
    })

$lockInstanceButton.Add_Click({
        try {
            $row = Get-SelectedInstance
            if ($null -eq $row) { return }
            $instanceId = [string]$row.InstanceId
            if (Test-InstanceLocked -InstanceId $instanceId) {
                Set-StatusText -Message "$instanceId はすでにロックされています"
                Update-InstanceLockButtons
                return
            }
            Add-InstanceLock -InstanceId $instanceId
            Add-InstanceLockMetadata -Instance $row | Out-Null
            $instancesGrid.Items.Refresh()
            Update-InstanceLockButtons
            Update-SelectedInstanceDependents
            Set-StatusText -Message "$instanceId をロックしました"
            Write-AppLog -Level 'INFO' -Message "インスタンスロック: $instanceId"
        }
        catch {
            Set-StatusText -Message "ロックエラー: $($_.Exception.Message)"
        }
    })

$unlockInstanceButton.Add_Click({
        try {
            $row = Get-SelectedInstance
            if ($null -eq $row) { return }
            $instanceId = [string]$row.InstanceId
            if (-not (Test-InstanceLocked -InstanceId $instanceId)) {
                Set-StatusText -Message "$instanceId はロックされていません"
                Update-InstanceLockButtons
                return
            }
            $confirmed = Show-ConfirmDialog -Warning -Message "$instanceId のロックを解除します。`n解除後は起動・停止・再起動・SG変更・SSMコマンド実行が可能になります。`n本当に解除しますか？"
            if (-not $confirmed) {
                Set-StatusText -Message 'ロック解除をキャンセルしました'
                return
            }
            Remove-InstanceLock -InstanceId $instanceId
            Add-InstanceLockMetadata -Instance $row | Out-Null
            $instancesGrid.Items.Refresh()
            Update-InstanceLockButtons
            Update-SelectedInstanceDependents
            Set-StatusText -Message "$instanceId のロックを解除しました"
            Write-AppLog -Level 'WARN' -Message "インスタンスロック解除: $instanceId"
        }
        catch {
            Set-StatusText -Message "ロック解除エラー: $($_.Exception.Message)"
        }
    })

Update-InstanceLockButtons
