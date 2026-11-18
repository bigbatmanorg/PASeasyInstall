BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    . (Join-Path $root 'Modules/PASeasyInstall.UI/Legacy/Credentials.ps1')
}
Describe 'UI private credential handoff' {
    BeforeEach {
        $path=Join-Path $TestDrive 'config.json'
        $config=New-PASeasyConfig -Template Vault -Path $path -Force
        $state=@{Auth=(New-PASeasyUICredentialCache)}
    }
    It 'requires independent selected-host and role secrets by default' {
        $state.Auth.Credentials.vault01=[pscredential]::new('host-user',(ConvertTo-SecureString 'host-marker' -AsPlainText -Force))
        $state.Auth.Secrets.VaultAdmin=ConvertTo-SecureString 'admin-marker' -AsPlainText -Force
        {New-PASeasyUICredentials $state $path} | Should -Throw '*VaultMaster*'
        $state.Auth.Secrets.VaultMaster=ConvertTo-SecureString 'master-marker' -AsPlainText -Force
        $result=New-PASeasyUICredentials $state $path
        $result.Credentials.Count | Should -Be 1
        $result.Secrets.Count | Should -Be 2
        $result.Credentials.vault01.UserName | Should -BeExactly 'host-user'
        [object]::ReferenceEquals($result.Secrets.VaultAdmin,$result.Secrets.VaultMaster) | Should -BeFalse
        [IO.File]::ReadAllText($path) | Should -Not -Match 'host-marker|admin-marker|master-marker'
    }
    It 'refuses shared shortcut in secure profile' {
        $state.Auth.SharedLabPassword=ConvertTo-SecureString 'lab-marker' -AsPlainText -Force
        {New-PASeasyUICredentials $state $path} | Should -Throw '*Lab profile*'
    }
    It 'allows explicitly selected Lab fallback and preserves independent overrides' {
        $config.security.profile='Lab';$config|ConvertTo-Json -Depth 50|Set-Content $path
        $state.Auth.SharedLabPassword=ConvertTo-SecureString 'lab-marker' -AsPlainText -Force
        $state.Auth.Secrets.VaultAdmin=ConvertTo-SecureString 'independent-marker' -AsPlainText -Force
        $result=New-PASeasyUICredentials $state $path
        $result.Credentials.Count | Should -Be 1
        [object]::ReferenceEquals($result.Secrets.VaultAdmin,$result.Secrets.VaultMaster) | Should -BeFalse
        Clear-PASeasyUICredentials $state
        $state.Auth.Credentials.Count | Should -Be 0
        $state.Auth.Secrets.Count | Should -Be 0
        $state.Auth.SharedLabPassword | Should -BeNullOrEmpty
    }
}

Describe 'Native Windows credential dialog support' {
    It 'compiles the public Win32 dialog binding without opening or persisting credentials' {
        Initialize-PASeasyNativeCredentialPrompt
        ('PASeasyInstall.NativeCredentialPrompt' -as [type]) | Should -Not -BeNullOrEmpty
    }
}

Describe 'PSM domain installer credential references' {
    It 'requires and forwards an independent declared installer identity' {
        $path=Join-Path $TestDrive 'psm.json'
        $config=New-PASeasyConfig -Template ExistingVault -Path $path -Force
        $config.components=@(@{id='psm';type='PSM';host='pam01';options=@{}})
        $config.activeDirectory.mode='Existing';$config.activeDirectory.join=@('pam01')
        $config|ConvertTo-Json -Depth 50|Set-Content $path
        $state=@{Auth=(New-PASeasyUICredentialCache)}
        $ss=ConvertTo-SecureString 'marker' -AsPlainText -Force
        $state.Auth.Credentials.pam01=[pscredential]::new('local-admin',$ss)
        $state.Auth.Secrets.VaultAdmin=$ss
        $state.Auth.Secrets.DomainJoinPassword=$ss
        {New-PASeasyUICredentials $state $path} | Should -Throw '*PSMDomainInstaller*'
        $state.Auth.Credentials.PSMDomainInstaller=[pscredential]::new('PAM\installer',$ss)
        $result=New-PASeasyUICredentials $state $path
        $result.Credentials.PSMDomainInstaller.UserName | Should -BeExactly 'PAM\installer'
    }
}

Describe 'PTA installer API credential role' {
    It 'requires independent PTA installer and primary Windows credentials' {
        $path=Join-Path $TestDrive 'pta.json'
        $config=New-PASeasyConfig -Template ExistingVault -Path $path -Force
        $config.components=@(@{id='pta';type='PTA';host='pta01';options=@{ptaConfigurationTransport='API'}})
        $config|ConvertTo-Json -Depth 50|Set-Content $path
        $state=@{Auth=(New-PASeasyUICredentialCache)}
        $state.Auth.Secrets.VaultAdmin=ConvertTo-SecureString 'vault-marker' -AsPlainText -Force
        {New-PASeasyUICredentials $state $path} | Should -Throw '*vault01*'
        $state.Auth.Credentials.vault01=[pscredential]::new('primary-os-user',(ConvertTo-SecureString 'primary-os-marker' -AsPlainText -Force))
        {New-PASeasyUICredentials $state $path} | Should -Throw '*PTAInstallerPassword*'
        $state.Auth.Secrets.PTAInstallerPassword=ConvertTo-SecureString 'installer-marker' -AsPlainText -Force
        $result=New-PASeasyUICredentials $state $path
        $result.Credentials.Count | Should -Be 1
        $result.Credentials.vault01.UserName | Should -BeExactly 'primary-os-user'
        [object]::ReferenceEquals($result.Secrets.VaultAdmin,$result.Secrets.PTAInstallerPassword) | Should -BeFalse
    }
}

Describe 'PTA native CLI secret minimization' {
    It 'does not export an unused OS installer password for the default native CLI route' {
        $path=Join-Path $TestDrive 'pta-native.json'
        $config=New-PASeasyConfig -Template ExistingVault -Path $path -Force
        $config.components=@(@{id='pta';type='PTA';host='pta01';options=@{}})
        $config | ConvertTo-Json -Depth 50 | Set-Content $path
        $state=@{Auth=(New-PASeasyUICredentialCache)}
        $state.Auth.Secrets.VaultAdmin=ConvertTo-SecureString 'vault-marker' -AsPlainText -Force
        $state.Auth.Secrets.PTAInstallerPassword=ConvertTo-SecureString 'unused-marker' -AsPlainText -Force
        $state.Auth.Credentials.vault01=[pscredential]::new('primary-os-user',(ConvertTo-SecureString 'primary-os-marker' -AsPlainText -Force))
        $result=New-PASeasyUICredentials $state $path
        $result.Secrets.ContainsKey('PTAInstallerPassword') | Should -BeFalse
    }
}
