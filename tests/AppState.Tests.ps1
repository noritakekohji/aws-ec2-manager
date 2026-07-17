#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'AppState' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\AppState.ps1')

        function New-TestInstance {
            param(
                [string]$Id = 'i-0123456789abcdef0',
                [string]$Name = 'web-server-01',
                [string]$PrivateIp = '10.0.1.10',
                [string]$PublicIp = '203.0.113.5'
            )
            return [PSCustomObject]@{
                InstanceId       = $Id
                Name             = $Name
                State            = 'running'
                PrivateIpAddress = $PrivateIp
                PublicIpAddress  = $PublicIp
                Platform         = 'Linux'
            }
        }
    }

    BeforeEach {
        $script:persisted = $null
        Initialize-AppState -LockedInstanceIds @() -PersistLocks {
            param($ids)
            $script:persisted = @($ids)
        }
    }

    Context 'Test-InstanceMatchesFilter' {
        It '空または空白フィルタは常に一致する' {
            $inst = New-TestInstance
            Test-InstanceMatchesFilter -Instance $inst -Filter '' | Should -BeTrue
            Test-InstanceMatchesFilter -Instance $inst -Filter '   ' | Should -BeTrue
            Test-InstanceMatchesFilter -Instance $inst -Filter $null | Should -BeTrue
        }

        It 'Name の部分一致(大文字小文字無視)' {
            $inst = New-TestInstance -Name 'Web-Server-01'
            Test-InstanceMatchesFilter -Instance $inst -Filter 'web-ser' | Should -BeTrue
            Test-InstanceMatchesFilter -Instance $inst -Filter 'WEB' | Should -BeTrue
            Test-InstanceMatchesFilter -Instance $inst -Filter 'db' | Should -BeFalse
        }

        It 'InstanceId / PrivateIp / PublicIp でも一致する' {
            $inst = New-TestInstance -Id 'i-0abc' -PrivateIp '10.0.1.10' -PublicIp '203.0.113.5'
            Test-InstanceMatchesFilter -Instance $inst -Filter '0abc' | Should -BeTrue
            Test-InstanceMatchesFilter -Instance $inst -Filter '10.0.1' | Should -BeTrue
            Test-InstanceMatchesFilter -Instance $inst -Filter '203.0.113' | Should -BeTrue
        }

        It 'プロパティ欠落や null 値でも落ちない' {
            $inst = [PSCustomObject]@{ InstanceId = 'i-1'; Name = $null }
            { Test-InstanceMatchesFilter -Instance $inst -Filter 'x' } | Should -Not -Throw
            Test-InstanceMatchesFilter -Instance $inst -Filter 'i-1' | Should -BeTrue
        }
    }

    Context 'Get-FilteredInstances' {
        It 'フィルタに一致するものだけ返す' {
            $items = @(
                (New-TestInstance -Id 'i-1' -Name 'web-01'),
                (New-TestInstance -Id 'i-2' -Name 'db-01'),
                (New-TestInstance -Id 'i-3' -Name 'web-02')
            )
            $r = @(Get-FilteredInstances -Items $items -Filter 'web')
            $r.Count | Should -Be 2
            $r[0].InstanceId | Should -Be 'i-1'
        }

        It 'null 入力は空配列を返す' {
            @(Get-FilteredInstances -Items $null -Filter 'x').Count | Should -Be 0
        }
    }

    Context 'ロック管理' {
        It 'Add-InstanceLock でロックされ永続化コールバックが呼ばれる' {
            Add-InstanceLock -InstanceId 'i-lock1'
            Test-InstanceLocked -InstanceId 'i-lock1' | Should -BeTrue
            @($script:persisted) | Should -Contain 'i-lock1'
        }

        It '同じ ID を二重登録しない' {
            Add-InstanceLock -InstanceId 'i-dup'
            Add-InstanceLock -InstanceId 'i-dup'
            @($script:AppState.LockedInstanceIds | Where-Object { $_ -eq 'i-dup' }).Count | Should -Be 1
        }

        It 'Remove-InstanceLock で解除される' {
            Add-InstanceLock -InstanceId 'i-lock2'
            Remove-InstanceLock -InstanceId 'i-lock2'
            Test-InstanceLocked -InstanceId 'i-lock2' | Should -BeFalse
            @($script:persisted) | Should -Not -Contain 'i-lock2'
        }

        It '初期ロック ID を引き継ぐ' {
            Initialize-AppState -LockedInstanceIds @('i-pre') -PersistLocks { param($ids) }
            Test-InstanceLocked -InstanceId 'i-pre' | Should -BeTrue
        }

        It 'Add-InstanceLockMetadata がロック列とラベルを付与する' {
            Initialize-AppState -LockedInstanceIds @('i-9') -PersistLocks { param($ids) }
            $inst = New-TestInstance -Id 'i-9' -Name 'locked-host'
            Add-InstanceLockMetadata -Instance $inst | Out-Null
            $inst.IsLocked | Should -BeTrue
            $inst.LockState | Should -Be 'ロック'
        }
    }

    Context 'キャッシュ管理' {
        It 'SG / ロールキャッシュを個別インスタンスで破棄できる' {
            $script:AppState.SgCache['i-1'] = @{ VpcId = 'vpc-1' }
            $script:AppState.SgCache['i-2'] = @{ VpcId = 'vpc-2' }
            $script:AppState.RoleCache['i-1'] = @{ Role = 'r1' }
            Clear-InstanceScopedCaches -InstanceId 'i-1'
            $script:AppState.SgCache.ContainsKey('i-1') | Should -BeFalse
            $script:AppState.SgCache.ContainsKey('i-2') | Should -BeTrue
            $script:AppState.RoleCache.ContainsKey('i-1') | Should -BeFalse
        }

        It '引数なしで全キャッシュを破棄できる' {
            $script:AppState.SgCache['i-1'] = @{ VpcId = 'vpc-1' }
            $script:AppState.RoleCache['i-2'] = @{ Role = 'r2' }
            Clear-InstanceScopedCaches
            $script:AppState.SgCache.Count | Should -Be 0
            $script:AppState.RoleCache.Count | Should -Be 0
        }
    }
}
