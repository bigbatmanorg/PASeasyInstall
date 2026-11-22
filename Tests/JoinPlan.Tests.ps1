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

Describe 'CyberArk hardening GPOs of a lab domain' {
    It 'chooses the vendor GPO by the roles on a server' {
        InModuleScope PASeasyInstall {
            (Get-PASHardeningGpoRole -Types @('PVWA')).Key | Should -Be 'PVWA'
            (Get-PASHardeningGpoRole -Types @('CPM', 'PVWA')).Key | Should -Be 'PVWACPM'
            (Get-PASHardeningGpoRole -Types @('CPM', 'PVWA')).MediaType | Should -Be 'CPM'
            (Get-PASHardeningGpoRole -Types @('PSM')).Key | Should -Be 'PSM'
            Get-PASHardeningGpoRole -Types @('PSM', 'CPM') | Should -BeNullOrEmpty
            Get-PASHardeningGpoRole -Types @('PSMP') | Should -BeNullOrEmpty
            'Hardening/CyberArk Hardening - Windows In Domain - Shared - CPM PVWA PSM-V1.zip' | Should -Match (Get-PASHardeningGpoRole -Types @('CPM', 'PVWA')).Pattern
            'Hardening/CyberArk Hardening - Windows 2012R2 In Domain - Standalone - PVWA V1.zip' | Should -Match (Get-PASHardeningGpoRole -Types @('PVWA')).Pattern
            'Hardening/CyberArk Hardening - In Domain - PSM V2.3.2.zip' | Should -Match (Get-PASHardeningGpoRole -Types @('PSM')).Pattern
            'Hardening/CyberArk Hardening - In Domain - Unified - PSM V2.3.2.zip' | Should -Not -Match (Get-PASHardeningGpoRole -Types @('PSM')).Pattern
            'Hardening/CyberArk Hardening - Windows Out of Domain - Standalone - CPM V1.zip' | Should -Not -Match (Get-PASHardeningGpoRole -Types @('CPM')).Pattern
        }
    }
    It 'applies them only when the lab creates its own domain' {
        InModuleScope PASeasyInstall {
            $config = @{
                activeDirectory = @{ mode = 'Create'; join = @('web1', 'psm1') }
                hosts = @{ web1 = @{ address = '192.0.2.21' }; psm1 = @{ address = '192.0.2.22' } }
                components = @(@{ id = 'p'; type = 'PVWA'; host = 'web1' }, @{ id = 'c'; type = 'CPM'; host = 'web1' }, @{ id = 's'; type = 'PSM'; host = 'psm1' })
            }
            $plan = @(Get-PASDomainPolicyPlan -Config $config)
            $plan.Count | Should -Be 2
            ($plan | Where-Object HostId -eq 'web1').Role.Key | Should -Be 'PVWACPM'
            $config.activeDirectory.mode = 'Existing'
            @(Get-PASDomainPolicyPlan -Config $config).Count | Should -Be 0
        }
    }
}
