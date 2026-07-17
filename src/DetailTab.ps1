<#
.SYNOPSIS
    Detail tab: shows all properties of the selected instance.
.DESCRIPTION
    選択インスタンスの詳細をタブ内 DataGrid に表示する(ローカルデータのみ、AWS 呼び出しなし)。
    行のダブルクリックで値をクリップボードへコピー。
    PowerShell 5.1 compatible. App.ps1 から dot-source される。
#>

$detailGrid = Find-Control -Name 'DetailGrid'

function ConvertTo-DetailText {
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) { return '' }
        return (@($Value) -join ', ')
    }
    return [string]$Value
}

function New-DetailRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    return [PSCustomObject]@{
        Name  = $Name
        Value = ConvertTo-DetailText -Value $Value
    }
}

function Update-DetailTab {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $inst = Get-AppStateInstance -InstanceId $script:AppState.SelectedInstanceId
    if ($null -eq $inst) {
        $detailGrid.ItemsSource = @()
        return
    }

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($prop in @(
            'Name', 'InstanceId', 'State', 'InstanceType', 'Platform', 'AvailabilityZone',
            'PrivateIpAddress', 'PublicIpAddress', 'VpcId', 'SubnetId', 'ImageId', 'KeyName',
            'LaunchTime', 'RootDeviceName', 'IamInstanceProfile', 'IamInstanceProfileArn',
            'SecurityGroupIds', 'SecurityGroupNames',
            'SsmStatus', 'SsmAgentVersion', 'SsmPlatformName', 'SsmPlatformVersion', 'SsmLastPingDateTime',
            'LockState'
        )) {
        $value = $null
        if ($inst.PSObject.Properties.Name -contains $prop) { $value = $inst.$prop }
        $rows.Add((New-DetailRow -Name $prop -Value $value))
    }
    $detailGrid.ItemsSource = $rows.ToArray()
}

$detailGrid.Add_MouseDoubleClick({
        try {
            $selectedRow = $detailGrid.SelectedItem
            if ($null -ne $selectedRow) {
                [System.Windows.Clipboard]::SetText([string]$selectedRow.Value)
                Set-StatusText -Message "$($selectedRow.Name) の値をコピーしました"
            }
        }
        catch {
            Set-StatusText -Message "コピーエラー: $($_.Exception.Message)"
        }
    })
