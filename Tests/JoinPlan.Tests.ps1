BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    . (Get-PASTestPrivateProxy)
}
Describe 'Public domain join payload generation' {
    It 'bundles the checkpoint helper and freezes the new forest DNS address' {
        $c = New-PASConfigurationTemplate -Template ADOnly -Path (Join-Path $TestDrive 'ad.json') -WhatIf
        $c.hosts.member = @{os = 'Windows'; address = '192.0.2.5'; user = 'Administrator' }
        $c.activeDirectory.join = @('member')
        $result = & (Get-Module PASeasyInstall) { param(
                $c,
                $r
            ) New-PASDomainJoinWorkflow -Config $c -HostId member -RunDirectory $r } $c (Join-Path $TestDrive 'run')
        $inventory = Import-PowerShellDataFile $result.Inventory
        $inventory.Values.Components['join-member'].DnsServers[0] | Should -Be $c.hosts.dc01.address
        foreach ($name in @('Join-Task.ps1', 'Join-Verify.ps1')) {
            $text = Get-Content (Join-Path (Split-Path (Split-Path $result.Workflow -Parent) -Parent) $name) -Raw
            $text | Should -Match 'function Test-PASeasyJoinPending'
            $text | Should -Not -Match "\. \(Join-Path .*'Join-State.ps1'\)"
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }
    It 'refuses an existing domain join without explicit DNS before remote mutation' {
        $c = New-PASConfigurationTemplate -Template ADOnly -Path (Join-Path $TestDrive 'existing.json') -WhatIf
        $c.activeDirectory.mode = 'Existing'
        $c.components = @()
        $c.hosts.member = @{os = 'Windows'; address = '192.0.2.6'; user = 'Administrator' }
        { & (Get-Module PASeasyInstall) { param(
                    $c,
                    $r
                ) New-PASDomainJoinWorkflow -Config $c -HostId member -RunDirectory $r } $c (Join-Path $TestDrive 'existing-run') } |
            Should -Throw '*dnsServers*'
    }
    It 'refuses string security flags that would cast false text to true' {
        $c = New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'bool.json') -WhatIf
        $c.security.profile = 'Lab'
        $c.security.overrides = @{'Vault.AllowRDP' = 'false' }
        (Test-PASConfiguration -Configuration $c).Issues -join ' ' | Should -Match 'JSON boolean'
    }
}
