#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $Script:Src = Join-Path $PSScriptRoot '..\tools\server-snapshot\ServerSnapshot.ps1'
    $content = Get-Content -Raw -LiteralPath $Script:Src
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
    # Load class + support functions needed by Compare-Filelist
    $classes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)
    foreach ($c in $classes) { Invoke-Expression $c.Extent.Text }
    $needed = @('Format-Val','Compare-Dict','Compare-List','Get-Prop','As-Array','Obj-To-Dict','Compare-Os','Compare-Network','Compare-Services','Compare-RemoteAccess','Compare-Patches','Compare-Scheduled','Compare-Middleware','Compare-Filelist')
    foreach ($name in $needed) {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn -or $fn.Count -eq 0) { throw "$name not found in $Script:Src" }
        Invoke-Expression $fn[0].Extent.Text
    }
}

Describe 'Compare-Filelist' {
    It 'detects ADDED target' {
        $b = @()
        $a = @(@{ key='new'; path='/tmp/new'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='x.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/new' }).AddedCount | Should -BeGreaterThan 0
    }

    It 'detects REMOVED target' {
        $b = @(@{ key='gone'; path='/tmp/gone'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='x.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $a = @()
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/gone' }).RemovedCount | Should -BeGreaterThan 0
    }

    It 'detects REMOVED entry within a target' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(); truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).RemovedCount | Should -Be 1
    }

    It 'detects CHANGED when owner differs' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='root' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='admin' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 1
    }

    It 'compares sha256 only when hash_enabled=true on both sides' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='aaa' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='bbb' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 1
    }

    It 'uses matching hashes before file size' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mtime='2026-01-01T00:00:00Z'; mode='0644'; owner='root'; group='users'; sha256='aaa' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=999; mtime='2026-02-01T00:00:00Z'; mode='0644'; owner='root'; group='users'; sha256='aaa' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 0
    }

    It 'detects metadata changes even when file hashes match' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mode='0644'; owner='root'; group='users'; sha256='aaa' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=1; mode='0600'; owner='admin'; group='admins'; sha256='aaa' });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 1
    }

    It 'falls back to size and ignores mtime when either hash is absent' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-01-01T00:00:00Z'; owner='root'; sha256='aaa' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; mtime='2026-02-01T00:00:00Z'; owner='root'; sha256=$null });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 0
    }

    It 'detects a size difference when either hash is absent' {
        $b = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$true;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=10; owner='root'; sha256='aaa' });
                  truncated=$false })
        $a = @(@{ key='t'; path='/x'; os_matched=$true; exists=$true; hash_enabled=$false;
                  entries=@(@{ rel_path='a.txt'; type='file'; size=11; owner='root'; sha256=$null });
                  truncated=$false })
        $r = @(Compare-Filelist $b $a)
        ($r | Where-Object { $_.Name -eq 'filelist/t' }).ChangedCount | Should -Be 1
    }
}

Describe 'Timestamp fields are display-only' {
    It 'ignores OS boot time and BIOS date' {
        $before = @{ os_name='Windows'; install_date='2020-01-01'; last_boot='2026-01-01T00:00:00Z'; reboot_pending=@{ pending=$false }; hardware=@{ bios_date='2020-01-01'; model='VM' } }
        $after  = @{ os_name='Windows'; install_date='2021-01-01'; last_boot='2026-02-01T00:00:00Z'; reboot_pending=@{ pending=$true }; hardware=@{ bios_date='2021-01-01'; model='VM' } }
        $result = Compare-Os $before $after
        $result.ChangedCount | Should -Be 0
    }

    It 'ignores patch installation date' {
        $before = @(@{ id='KB1'; description='Security Update'; installed_on='2026-01-01' })
        $after  = @(@{ id='KB1'; description='Localized description'; installed_on='2026-02-01' })
        $result = Compare-Patches $before $after
        $result.ChangedCount | Should -Be 0
    }

    It 'ignores runtime service and remote-access states' {
        $before = @(@{ name='sshd'; status='running'; start_type='manual'; start_name='LocalSystem'; path_name='C:\ssh.exe'; description='SSH' })
        $after  = @(@{ name='sshd'; status='stopped'; start_type='manual'; start_name='LocalSystem'; path_name='C:\ssh.exe'; description='SSH updated' })
        (Compare-Services $before $after).ChangedCount | Should -Be 0

        $remoteBefore = @{ services = $before }
        $remoteAfter = @{ services = $after }
        $remoteResult = @(Compare-RemoteAccess $remoteBefore $remoteAfter | Where-Object { $_.Name -eq 'remote_access/services' })
        $remoteResult[0].ChangedCount | Should -Be 0
    }

    It 'ignores time synchronization health and scheduled task state' {
        $networkBefore = @{ time_sync = @{ servers=@('ntp-a'); synchronized=$true; _volatile=@{ last_sync='2026-01-01' } } }
        $networkAfter  = @{ time_sync = @{ servers=@('ntp-b'); synchronized=$false; _volatile=@{ last_sync='2026-02-01' } } }
        $networkResult = @(Compare-Network $networkBefore $networkAfter)
        (($networkResult | Measure-Object ChangedCount -Sum).Sum) | Should -Be 0

        $scheduledBefore = @{ scheduled_tasks=@(@{ name='Daily'; path='\'; state='Ready' }); startup=@() }
        $scheduledAfter  = @{ scheduled_tasks=@(@{ name='Daily'; path='\'; state='Running' }); startup=@() }
        $scheduledResult = @(Compare-Scheduled $scheduledBefore $scheduledAfter | Where-Object { $_.Name -eq 'scheduled/tasks' })
        $scheduledResult[0].ChangedCount | Should -Be 0
    }

    It 'ignores middleware runtime state and probe availability' {
        $before = @{ sqlserver=@(@{ instance_name='MSSQLSERVER'; version='16.0'; edition='Standard'; port='1433'; state='running'; sp_configure_available=$true; config_files=@{} }) }
        $after  = @{ sqlserver=@(@{ instance_name='MSSQLSERVER'; version='16.0'; edition='Standard'; port='1433'; state='stopped'; sp_configure_available=$false; config_files=@{} }) }
        $result = @(Compare-Middleware $before $after)
        (($result | Measure-Object ChangedCount -Sum).Sum) | Should -Be 0
    }
}
