<#
.SYNOPSIS
    Instance role tab: attach/detach/replace IAM Instance Profile.
.DESCRIPTION
    左ペインの選択インスタンスに追従。Association と Instance Profile 一覧は
    AppState.RoleCache にインスタンス ID 単位でキャッシュし、タブがアクティブな
    ときだけ取得する。取得・適用は AsyncRunner 経由。
    PowerShell 5.1 compatible. App.ps1 から dot-source される。
#>

$reloadRoleButton = Find-Control -Name 'ReloadRoleButton'
$roleStatusText = Find-Control -Name 'RoleStatusText'
$applyRoleButton = Find-Control -Name 'ApplyRoleButton'
$appliedRoleList = Find-Control -Name 'AppliedRoleList'
$availableRoleList = Find-Control -Name 'AvailableRoleList'
$moveRoleToAppliedButton = Find-Control -Name 'MoveRoleToAppliedButton'
$moveRoleToAvailableButton = Find-Control -Name 'MoveRoleToAvailableButton'
$roleDiffPanel = Find-Control -Name 'RoleDiffPanel'

$roleTabState = [PSCustomObject]@{
    CurrentInstanceId        = $null
    OriginalProfileName      = ''
    OriginalAssociationId    = ''
    OriginalAssociationState = ''
    Loaded                   = $false
}

function Test-RoleTabActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $tabs = Find-Control -Name 'DetailTabs'
    return ($tabs.SelectedIndex -eq 2)
}

function Get-RoleProfileLabel {
    param($Item)
    if ($null -eq $Item) { return '' }
    $name = [string](Get-ObjectPropertyValue -Object $Item -Name 'InstanceProfileName')
    $roles = @((Get-ObjectPropertyValue -Object $Item -Name 'RoleNames'))
    $roleText = ($roles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', '
    if ([string]::IsNullOrWhiteSpace($roleText)) { return $name }
    return "$name / Role: $roleText"
}

function Add-RoleDiffText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper, not a system-state change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,
        [string]$Color = '#E5E7EB',
        [bool]$Bold = $false,
        [double]$FontSize = 13,
        [int]$Bottom = 4
    )

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
    $tb.FontSize = $FontSize
    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tb.Margin = New-Object System.Windows.Thickness 0, 0, 0, $Bottom
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $roleDiffPanel.Children.Add($tb) | Out-Null
}

function Get-RoleItemsFromList {
    param($ListBox)
    $items = @()
    if ($null -ne $ListBox.ItemsSource) {
        foreach ($x in $ListBox.ItemsSource) { $items += $x }
    }
    return $items
}

function Get-PlannedRoleItem {
    $items = @(Get-RoleItemsFromList -ListBox $appliedRoleList)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Get-PlannedRoleName {
    $item = Get-PlannedRoleItem
    if ($null -eq $item) { return '' }
    return [string]$item.InstanceProfileName
}

function Get-RoleActionForPlan {
    $originalName = [string]$roleTabState.OriginalProfileName
    $plannedName = Get-PlannedRoleName
    if ([string]::IsNullOrWhiteSpace($originalName) -and [string]::IsNullOrWhiteSpace($plannedName)) { return 'None' }
    if ([string]::IsNullOrWhiteSpace($originalName) -and -not [string]::IsNullOrWhiteSpace($plannedName)) { return 'Attach' }
    if (-not [string]::IsNullOrWhiteSpace($originalName) -and [string]::IsNullOrWhiteSpace($plannedName)) { return 'Detach' }
    if ($originalName -ne $plannedName) { return 'Replace' }
    return 'None'
}

function Update-RoleActionButtons {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $isReady = ($roleTabState.Loaded -and -not [string]::IsNullOrWhiteSpace([string]$roleTabState.CurrentInstanceId))
    $isLocked = $false
    if ($isReady) { $isLocked = Test-InstanceLocked -InstanceId ([string]$roleTabState.CurrentInstanceId) }
    $isBusy = Test-AsyncTaskRunning
    $action = Get-RoleActionForPlan

    $moveRoleToAppliedButton.IsEnabled = ($isReady -and (-not $isLocked) -and $null -ne $availableRoleList.SelectedItem)
    $moveRoleToAvailableButton.IsEnabled = ($isReady -and (-not $isLocked) -and $null -ne (Get-PlannedRoleItem))
    $applyRoleButton.IsEnabled = ($isReady -and (-not $isLocked) -and (-not $isBusy) -and $action -ne 'None')
}

function Render-RoleDiffPanel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $roleDiffPanel.Children.Clear()
    if ([string]::IsNullOrWhiteSpace([string]$roleTabState.CurrentInstanceId)) {
        Add-RoleDiffText -Text 'インスタンスを選択してください。' -Color '#94A3B8'
        Update-RoleActionButtons
        return
    }

    $current = if ([string]::IsNullOrWhiteSpace([string]$roleTabState.OriginalProfileName)) { '(なし)' } else { [string]$roleTabState.OriginalProfileName }
    $plannedName = Get-PlannedRoleName
    $planned = if ([string]::IsNullOrWhiteSpace($plannedName)) { '(なし)' } else { $plannedName }
    $action = Get-RoleActionForPlan
    Add-RoleDiffText -Text "Instance: $($roleTabState.CurrentInstanceId)" -Bold $true
    Add-RoleDiffText -Text "現在: $current" -Color '#94A3B8'
    Add-RoleDiffText -Text "適用後: $planned" -Color '#94A3B8'
    if (-not [string]::IsNullOrWhiteSpace([string]$roleTabState.OriginalAssociationState)) {
        Add-RoleDiffText -Text "Association: $($roleTabState.OriginalAssociationId) / State: $($roleTabState.OriginalAssociationState)" -Color '#94A3B8'
    }

    if ($action -eq 'None') {
        Add-RoleDiffText -Text 'インスタンスロール差分はありません。' -Color '#94A3B8'
        Update-RoleActionButtons
        return
    }

    if ($action -eq 'Attach') {
        Add-RoleDiffText -Text "[+] アタッチ: $plannedName" -Color '#38BDF8' -Bold $true
    }
    elseif ($action -eq 'Detach') {
        Add-RoleDiffText -Text "[-] デタッチ: $($roleTabState.OriginalProfileName)" -Color '#F97373' -Bold $true
    }
    else {
        Add-RoleDiffText -Text "[-] デタッチ: $($roleTabState.OriginalProfileName)" -Color '#F97373' -Bold $true
        Add-RoleDiffText -Text "[+] アタッチ: $plannedName" -Color '#38BDF8' -Bold $true
        Add-RoleDiffText -Text 'AWS API は replace-iam-instance-profile-association を使います。' -Color '#94A3B8'
    }
    Update-RoleActionButtons
}

function Clear-RoleTab {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $appliedRoleList.ItemsSource = $null
    $availableRoleList.ItemsSource = $null
    $roleTabState.CurrentInstanceId = $null
    $roleTabState.OriginalProfileName = ''
    $roleTabState.OriginalAssociationId = ''
    $roleTabState.OriginalAssociationState = ''
    $roleTabState.Loaded = $false
    $roleStatusText.Text = 'IAM Instance Profile'
    Render-RoleDiffPanel
}

function Render-RoleData {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter()][AllowNull()]$Association,
        [Parameter()][AllowNull()][object[]]$Profiles
    )

    $roleTabState.CurrentInstanceId = [string]$Instance.InstanceId
    $roleTabState.OriginalProfileName = ''
    $roleTabState.OriginalAssociationId = ''
    $roleTabState.OriginalAssociationState = ''

    if ($null -ne $Association) {
        $roleTabState.OriginalProfileName = [string]$Association.InstanceProfileName
        $roleTabState.OriginalAssociationId = [string]$Association.AssociationId
        $roleTabState.OriginalAssociationState = [string]$Association.State
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -Object $Instance -Name 'IamInstanceProfile'))) {
        $roleTabState.OriginalProfileName = [string]$Instance.IamInstanceProfile
    }

    if ($null -eq $Profiles) { $Profiles = @() }

    $applied = New-Object System.Collections.Generic.List[PSCustomObject]
    $items = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($profileItem in @($Profiles)) {
        $displayLabel = Get-RoleProfileLabel -Item $profileItem
        $profileItem | Add-Member -NotePropertyName DisplayLabel -NotePropertyValue $displayLabel -Force
        if (-not [string]::IsNullOrWhiteSpace([string]$roleTabState.OriginalProfileName) -and
            [string]$profileItem.InstanceProfileName -eq [string]$roleTabState.OriginalProfileName) {
            $applied.Add($profileItem)
        }
        else {
            $items.Add($profileItem)
        }
    }
    if ($applied.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$roleTabState.OriginalProfileName)) {
        $fallback = [PSCustomObject]@{
            InstanceProfileName = [string]$roleTabState.OriginalProfileName
            Arn                 = ''
            Path                = ''
            RoleNames           = @()
            DisplayLabel        = [string]$roleTabState.OriginalProfileName
        }
        $applied.Add($fallback)
    }
    $appliedRoleList.ItemsSource = $applied.ToArray()
    $availableRoleList.ItemsSource = $items.ToArray()
    if ($applied.Count -gt 0) {
        $appliedRoleList.SelectedIndex = 0
    }
    $roleTabState.Loaded = $true

    $isLocked = Test-InstanceLocked -InstanceId ([string]$Instance.InstanceId)
    if ($isLocked) {
        $roleStatusText.Text = "ロック中のため適用不可 / 候補 $($items.Count) 件"
    }
    else {
        $roleStatusText.Text = "Instance Profile 候補 $($items.Count) 件"
    }
    Render-RoleDiffPanel
}

function Invoke-RoleLoadAsync {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts async load by design.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [switch]$Force
    )

    $instanceId = [string]$Instance.InstanceId

    if ((-not $Force) -and $script:AppState.RoleCache.ContainsKey($instanceId)) {
        $cached = $script:AppState.RoleCache[$instanceId]
        Render-RoleData -Instance $Instance -Association $cached.Association -Profiles @($cached.Profiles)
        return
    }

    if (Test-AsyncTaskRunning) {
        $roleStatusText.Text = '他のタスクを実行中のため未取得です。完了後に「再取得」を押してください。'
        return
    }

    $name = Get-SelectedProfile
    if ($null -eq $name) { return }

    $roleStatusText.Text = 'Instance Profile 情報を取得中…'
    Set-StatusText -Message "$instanceId の Instance Profile 取得中…"

    $started = Start-AsyncTask -Name "ロール取得: $instanceId" -Work {
        param($Channel, $ReportProgress, $profileName, $targetId)
        $assoc = Get-InstanceProfileAssociation -Profile $profileName -InstanceId $targetId
        [object[]]$profiles = Get-IamInstanceProfiles -Profile $profileName
        if ($null -eq $profiles) { $profiles = @() }
        return [PSCustomObject]@{ Association = $assoc; Profiles = $profiles }
    } -ArgumentList @([string]$name, $instanceId) -Context @{ InstanceId = $instanceId } -OnSuccess {
        param($result, $ctx)
        $fetchedFor = [string]$ctx.InstanceId
        $script:AppState.RoleCache[$fetchedFor] = @{
            Association = $result.Association
            Profiles    = @($result.Profiles)
        }
        $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
        if ($null -ne $inst -and [string]$inst.InstanceId -eq $fetchedFor) {
            Render-RoleData -Instance $inst -Association $result.Association -Profiles @($result.Profiles)
            Set-StatusText -Message "Instance Profile 情報を取得しました"
        }
    } -OnError {
        param($err, $ctx)
        $roleStatusText.Text = "取得エラー: $err"
        Set-StatusText -Message "インスタンスロール取得エラー: $err"
        Write-AppLog -Level 'ERROR' -Message "インスタンスロール取得エラー: $err"
    }
    if (-not $started) {
        $roleStatusText.Text = '他のタスクを実行中のため未取得です。完了後に「再取得」を押してください。'
    }
}

function Update-RoleTabForSelection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        Clear-RoleTab
        return
    }
    if (-not (Test-RoleTabActive)) {
        if ([string]$roleTabState.CurrentInstanceId -ne [string]$inst.InstanceId) {
            $roleTabState.Loaded = $false
        }
        return
    }
    if ($roleTabState.Loaded -and [string]$roleTabState.CurrentInstanceId -eq [string]$inst.InstanceId) {
        Update-RoleActionButtons
        return
    }
    Invoke-RoleLoadAsync -Instance $inst
}

function Move-RoleToApplied {
    [CmdletBinding()]
    param()

    $selected = $availableRoleList.SelectedItem
    if ($null -eq $selected) { return }

    $available = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($x in @(Get-RoleItemsFromList -ListBox $availableRoleList)) {
        if ([string]$x.InstanceProfileName -ne [string]$selected.InstanceProfileName) {
            $available.Add($x)
        }
    }
    foreach ($x in @(Get-RoleItemsFromList -ListBox $appliedRoleList)) {
        if ([string]$x.InstanceProfileName -ne [string]$selected.InstanceProfileName) {
            $available.Add($x)
        }
    }

    $appliedRoleList.ItemsSource = @($selected)
    $appliedRoleList.SelectedIndex = 0
    $availableRoleList.ItemsSource = $available.ToArray()
    Render-RoleDiffPanel
}

function Move-RoleToAvailable {
    [CmdletBinding()]
    param()

    $planned = Get-PlannedRoleItem
    if ($null -eq $planned) { return }
    $available = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($x in @(Get-RoleItemsFromList -ListBox $availableRoleList)) {
        if ([string]$x.InstanceProfileName -ne [string]$planned.InstanceProfileName) {
            $available.Add($x)
        }
    }
    $available.Add($planned)
    $appliedRoleList.ItemsSource = @()
    $availableRoleList.ItemsSource = $available.ToArray()
    Render-RoleDiffPanel
}

function Invoke-InstanceProfileApply {
    [CmdletBinding()]
    param()

    $name = Get-SelectedProfile
    if ($null -eq $name) { return }
    if (-not $roleTabState.Loaded -or [string]::IsNullOrWhiteSpace([string]$roleTabState.CurrentInstanceId)) {
        Set-StatusText -Message 'インスタンス未選択'
        return
    }
    $instanceId = [string]$roleTabState.CurrentInstanceId
    if (-not (Test-InstanceOperationAllowed -InstanceId $instanceId -OperationLabel 'インスタンスロール適用')) { return }

    $action = Get-RoleActionForPlan
    if ($action -eq 'None') {
        Set-StatusText -Message '変更はありません'
        return
    }
    $plannedName = Get-PlannedRoleName
    if (($action -eq 'Detach' -or $action -eq 'Replace') -and [string]::IsNullOrWhiteSpace([string]$roleTabState.OriginalAssociationId)) {
        Set-StatusText -Message '現在の AssociationId が取得できていません。再取得してください'
        return
    }
    $msg = "$instanceId にインスタンスロール変更を適用しますか？"
    if ($action -eq 'Attach') { $msg += "`n追加: $plannedName" }
    elseif ($action -eq 'Detach') { $msg += "`n削除: $($roleTabState.OriginalProfileName)" }
    else { $msg += "`n削除: $($roleTabState.OriginalProfileName)`n追加: $plannedName" }

    if (-not (Show-ConfirmDialog -Message $msg)) {
        Set-StatusText -Message 'インスタンスロール適用をキャンセルしました'
        return
    }

    Set-StatusText -Message "$instanceId にインスタンスロール適用中..."
    Write-AppLog -Level 'INFO' -Message "インスタンスロール適用開始: $instanceId action=$action current=$($roleTabState.OriginalProfileName) planned=$plannedName association=$($roleTabState.OriginalAssociationId)"

    $started = Start-AsyncTask -Name "ロール適用: $instanceId" -Work {
        param($Channel, $ReportProgress, $profileName, $targetId, $roleAction, $associationId, $instanceProfileName)
        $actionParams = @{
            Profile       = $profileName
            InstanceId    = $targetId
            Action        = $roleAction
            AssociationId = $associationId
        }
        if ($roleAction -eq 'Attach' -or $roleAction -eq 'Replace') {
            $actionParams['InstanceProfileName'] = $instanceProfileName
        }
        return (Set-InstanceProfileAssociation @actionParams)
    } -ArgumentList @([string]$name, $instanceId, $action, [string]$roleTabState.OriginalAssociationId, $plannedName) -Context @{ InstanceId = $instanceId; Action = $action } -OnSuccess {
        param($result, $ctx)
        $targetId = [string]$ctx.InstanceId
        if ($result) {
            Set-StatusText -Message "$targetId にインスタンスロール変更を適用しました"
            Write-AppLog -Level 'INFO' -Message "インスタンスロール適用完了: $targetId action=$($ctx.Action)"
            Clear-InstanceScopedCaches -InstanceId $targetId
            $roleTabState.Loaded = $false
            Update-SingleInstanceAsync -InstanceId $targetId -After {
                Update-RoleTabForSelection
            }
        }
        else {
            Set-StatusText -Message "$targetId へのインスタンスロール適用に失敗しました"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール適用失敗: $targetId action=$($ctx.Action)"
        }
    } -OnError {
        param($err, $ctx)
        Set-StatusText -Message "インスタンスロール適用エラー: $err"
        Write-AppLog -Level 'ERROR' -Message "インスタンスロール適用エラー: $err"
    }
    if (-not $started) {
        Set-StatusText -Message '他のタスクを実行中です。完了後に再度お試しください。'
    }
}

$applyRoleButton.IsEnabled = $false
$moveRoleToAppliedButton.IsEnabled = $false
$moveRoleToAvailableButton.IsEnabled = $false

$reloadRoleButton.Add_Click({
        try {
            $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
            if ($null -eq $inst) {
                Set-StatusText -Message 'インスタンス未選択'
                return
            }
            Invoke-RoleLoadAsync -Instance $inst -Force
        }
        catch {
            Set-StatusText -Message "ロール再取得エラー: $($_.Exception.Message)"
        }
    })

$appliedRoleList.Add_SelectionChanged({
        Update-RoleActionButtons
    })

$availableRoleList.Add_SelectionChanged({
        Update-RoleActionButtons
    })

$moveRoleToAppliedButton.Add_Click({
        try { Move-RoleToApplied }
        catch {
            Set-StatusText -Message "インスタンスロール移動エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール移動エラー(候補 -> 適用予定): $($_.Exception.Message)"
        }
    })

$moveRoleToAvailableButton.Add_Click({
        try { Move-RoleToAvailable }
        catch {
            Set-StatusText -Message "インスタンスロール移動エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール移動エラー(適用予定 -> 候補): $($_.Exception.Message)"
        }
    })

$applyRoleButton.Add_Click({
        try { Invoke-InstanceProfileApply }
        catch {
            Set-StatusText -Message "インスタンスロール適用エラー: $($_.Exception.Message)"
            Write-AppLog -Level 'ERROR' -Message "インスタンスロール適用エラー: $($_.Exception.Message)"
        }
    })

Clear-RoleTab
