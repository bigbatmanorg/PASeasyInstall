BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Recipes/WindowsComponent/PrepareManagement.ps1') -Settings @{}
    $sid=([Security.Principal.NTAccount]::new($env:COMPUTERNAME,'Administrator')).Translate([Security.Principal.SecurityIdentifier]).Value
}
Describe 'Explicit restricted management endpoint' {
    It 'normalizes local names and preserves domain/UPN identities' {
        Get-PASeasyManagementAccountName Administrator|Should -BeExactly ($env:COMPUTERNAME+'\Administrator')
        Get-PASeasyManagementAccountName '.\Administrator'|Should -BeExactly ($env:COMPUTERNAME+'\Administrator')
        Get-PASeasyManagementAccountName 'PAM\operator'|Should -BeExactly 'PAM\operator'
        Get-PASeasyManagementAccountName 'operator@pam.lab'|Should -BeExactly 'operator@pam.lab'
        {Get-PASeasyManagementAccountName ' operator'}|Should -Throw
    }
    It 'accepts only one exact SID allow ACE and virtual-account execution' {
        $c=@{Enabled=$true;RunAsVirtualAccount=$true;SecurityDescriptorSddl="O:NSG:BAD:P(A;;GA;;;$sid)"}
        Test-PASeasyManagementEndpoint $c $sid|Should -BeTrue
        $c.SecurityDescriptorSddl="O:NSG:BAD:P(A;;GA;;;$sid)(A;;GA;;;BA)"
        Test-PASeasyManagementEndpoint $c $sid|Should -BeFalse
        $c.SecurityDescriptorSddl='O:NSG:BAD:P(A;;GA;;;BA)'
        Test-PASeasyManagementEndpoint $c $sid|Should -BeFalse
        $c.SecurityDescriptorSddl="O:NSG:BAD:P(A;;GA;;;$sid)";$c.RunAsVirtualAccount=$false
        Test-PASeasyManagementEndpoint $c $sid|Should -BeFalse
    }
    It 'is idempotent without service restart or registration for a correct existing endpoint' {
        Mock Get-PSSessionConfiguration {@{Enabled=$true;RunAsVirtualAccount=$true;SecurityDescriptorSddl="O:NSG:BAD:P(A;;GA;;;$sid)"}}
        Mock Register-PSSessionConfiguration {throw 'must not register'}
        Mock Restart-Service {throw 'must not restart'}
        (Invoke-PASeasyManagementPreparation @{ManagementUser='Administrator'}).Changed|Should -BeFalse
        Should -Invoke Register-PSSessionConfiguration -Times 0
        Should -Invoke Restart-Service -Times 0
    }
    It 'fails closed on an unexpected existing endpoint without modifying it' {
        Mock Get-PSSessionConfiguration {@{Enabled=$true;RunAsVirtualAccount=$true;SecurityDescriptorSddl='O:NSG:BAD:P(A;;GA;;;BA)'}}
        Mock Register-PSSessionConfiguration {throw 'must not register'}
        Mock Unregister-PSSessionConfiguration {throw 'must not unregister'}
        Mock Restart-Service {throw 'must not restart'}
        {Invoke-PASeasyManagementPreparation @{ManagementUser='Administrator'}}|Should -Throw '*differs*'
        Should -Invoke Register-PSSessionConfiguration -Times 0
        Should -Invoke Unregister-PSSessionConfiguration -Times 0
        Should -Invoke Restart-Service -Times 0
    }
}
