BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Public join-only configuration' {
    BeforeEach {$config=New-PASConfigurationTemplate -Template DomainJoin -Path (Join-Path $TestDrive 'join.json') -WhatIf}
    It 'creates an explicit existing forest Windows join with no component or media' {
        @($config.components).Count | Should -Be 0
        $config.activeDirectory.mode | Should -Be 'Existing'
        $config.activeDirectory.join | Should -Contain 'pam01'
        (Test-PASConfiguration -Configuration $config -CheckMedia).Valid | Should -BeTrue
    }
    It 'rejects an empty deployment without a join' {
        $config.activeDirectory.join=@()
        (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
    }
    It 'rejects empty deployments in forest creation or no-AD modes' {
        foreach($mode in @('Create','None')){
            $config.activeDirectory.mode=$mode
            (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
        }
    }
    It 'rejects missing and Linux join hosts' {
        foreach($id in @('missing','psmp01')){
            $config.activeDirectory.join=@($id)
            (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
        }
    }
    It 'retains the explicit Vault and DC component host exclusion' {
        foreach($type in @('Vault','DRVault','AD')){
            $config.components=@(@{id='blocked';type=$type;host='pam01';variant='Standard'})
            (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
        }
    }
    It 'requires a valid AD DNS domain for a join-only run' {
        $config.activeDirectory.domain='bad domain'
        (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
    }
}
