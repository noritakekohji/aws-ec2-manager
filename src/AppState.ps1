<#
.SYNOPSIS
    Application state: selected instance, caches, filter, and locks.
.DESCRIPTION
    マスター/ディテール UI の共有状態を一元管理する。
    - Items / SelectedInstanceId: 左ペインの一覧と選択
    - SgCache / RoleCache: インスタンス ID 単位の SG / ロール情報キャッシュ
    - LockedInstanceIds: 操作禁止インスタンス(AppSettings に永続化)
    PowerShell 5.1 compatible. dot-source して使う。
#>

Set-StrictMode -Version Latest

$script:AppState = [PSCustomObject]@{
    Profile            = $null
    Items              = @()
    SelectedInstanceId = $null
    HasLoaded          = $false
    LastUpdated        = $null
    FilterText         = ''
    SgCache            = @{}
    RoleCache          = @{}
    LockedInstanceIds  = @()
    PersistLocks       = $null
}

function Initialize-AppState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory initialization only.')]
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]]$LockedInstanceIds = @(),

        # ロック一覧を永続化するコールバック: { param($ids) ... }
        [Parameter()]
        [AllowNull()]
        [scriptblock]$PersistLocks = $null
    )
    $script:AppState.Profile = $null
    $script:AppState.Items = @()
    $script:AppState.SelectedInstanceId = $null
    $script:AppState.HasLoaded = $false
    $script:AppState.LastUpdated = $null
    $script:AppState.FilterText = ''
    $script:AppState.SgCache = @{}
    $script:AppState.RoleCache = @{}
    $script:AppState.LockedInstanceIds = @()
    if ($null -ne $LockedInstanceIds) {
        $script:AppState.LockedInstanceIds = @($LockedInstanceIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $script:AppState.PersistLocks = $PersistLocks
}

function Get-InstancePropertyText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Instance) { return '' }
    if ($Instance.PSObject.Properties.Name -contains $Name) {
        $value = $Instance.$Name
        if ($null -ne $value) { return [string]$value }
    }
    return ''
}

function Test-InstanceMatchesFilter {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Filter
    )
    if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }
    $needle = $Filter.Trim()
    foreach ($prop in @('Name', 'InstanceId', 'PrivateIpAddress', 'PublicIpAddress')) {
        $text = Get-InstancePropertyText -Instance $Instance -Name $prop
        if ($text.Length -gt 0 -and $text.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-FilteredInstances {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Items,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Filter
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        if (Test-InstanceMatchesFilter -Instance $item -Filter $Filter) {
            $result.Add($item)
        }
    }
    return $result.ToArray()
}

function Test-InstanceLocked {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstanceId
    )
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $false }
    return (@($script:AppState.LockedInstanceIds) -contains $InstanceId)
}

function Save-InstanceLockList {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven lock persistence.')]
    [CmdletBinding()]
    param()
    if ($null -ne $script:AppState.PersistLocks) {
        & $script:AppState.PersistLocks @($script:AppState.LockedInstanceIds)
    }
}

function Add-InstanceLock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven lock operation.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    $script:AppState.LockedInstanceIds = @((@($script:AppState.LockedInstanceIds) + $InstanceId) | Select-Object -Unique)
    Save-InstanceLockList
}

function Remove-InstanceLock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven lock operation.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    $script:AppState.LockedInstanceIds = @(@($script:AppState.LockedInstanceIds) | Where-Object { $_ -ne $InstanceId })
    Save-InstanceLockList
}

function Add-InstanceLockMetadata {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Adds UI-only properties to display rows.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [string]$DisplayLabel
    )
    $id = Get-InstancePropertyText -Instance $Instance -Name 'InstanceId'
    $locked = Test-InstanceLocked -InstanceId $id
    $stateText = if ($locked) { 'ロック' } else { '' }
    $Instance | Add-Member -NotePropertyName IsLocked -NotePropertyValue $locked -Force
    $Instance | Add-Member -NotePropertyName LockState -NotePropertyValue $stateText -Force
    if ($PSBoundParameters.ContainsKey('DisplayLabel')) {
        $label = if ($locked) { "[ロック] $DisplayLabel" } else { $DisplayLabel }
        $Instance | Add-Member -NotePropertyName DisplayLabel -NotePropertyValue $label -Force
    }
    return $Instance
}

function Clear-InstanceScopedCaches {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory cache invalidation.')]
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstanceId
    )
    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        $script:AppState.SgCache = @{}
        $script:AppState.RoleCache = @{}
        return
    }
    $script:AppState.SgCache.Remove($InstanceId)
    $script:AppState.RoleCache.Remove($InstanceId)
}

function Get-AppStateInstance {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstanceId
    )
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    foreach ($item in @($script:AppState.Items)) {
        if ($null -ne $item -and [string]$item.InstanceId -eq $InstanceId) { return $item }
    }
    return $null
}
