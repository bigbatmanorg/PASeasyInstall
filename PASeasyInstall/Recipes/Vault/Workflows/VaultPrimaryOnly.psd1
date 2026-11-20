# Primary Vault FullInstall. Hardening is a mandatory, unattended stage. Data only: no code here.
@{
    SchemaVersion=1; Name='CyberArk Vault 15.0 primary-only FullInstall'; Target='primary'; Root='..'
    Steps=@(
        @{Id='preflight';Script='Tasks/Common/Test-Preflight.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Role='Primary'};Verify='Tasks/Common/Verify-Preflight.ps1'}
        @{Id='management-endpoint';Script='Tasks/Common/Register-ManagementEndpoint.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Common/Verify-ManagementEndpoint.ps1';Critical=$true;TimeoutSeconds=600}
        @{Id='prepare-paths';Script='Tasks/Common/Prepare-Paths.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Role='Primary'};Verify='Tasks/Common/Verify-Paths.ps1'}
        @{Id='upload-vc-x86';Kind='Transfer';Source=@{ConfigRef='Values.Media.VCx86'};Destination='C:\Cyberark\Automation\Prerequisites\VC_redist.x86.exe'}
        @{Id='upload-vc-x64';Kind='Transfer';Source=@{ConfigRef='Values.Media.VCx64'};Destination='C:\Cyberark\Automation\Prerequisites\VC_redist.x64.exe'}
        @{Id='upload-vc2013-x86';Kind='Transfer';Source=@{ConfigRef='Values.Media.VC2013x86'};Destination='C:\Cyberark\Automation\Prerequisites\vcredist_x86.exe'}
        @{Id='upload-server';Kind='Transfer';Source=@{ConfigRef='Values.Media.ServerZip'};Destination='C:\Cyberark\packages\Server-Rls.zip';TimeoutSeconds=3600}
        @{Id='upload-pacli';Kind='Transfer';Source=@{ConfigRef='Values.Media.PACLIZip'};Destination='C:\Cyberark\packages\PACLI-Rls.zip'}
        @{Id='upload-keygen-exe';Kind='Transfer';Source=@{ConfigRef='Values.Media.PAKeyGenExe'};Destination='C:\Cyberark\Automation\PAKeyGen\PAKeyGen.exe'}
        @{Id='upload-keygen-dll1';Kind='Transfer';Source=@{ConfigRef='Values.Media.PAKeyGenDll1'};Destination='C:\Cyberark\Automation\PAKeyGen\calibeay32102o.dll'}
        @{Id='upload-keygen-dll2';Kind='Transfer';Source=@{ConfigRef='Values.Media.PAKeyGenDll2'};Destination='C:\Cyberark\Automation\PAKeyGen\cassleay32102o.dll'}
        @{Id='upload-license';Kind='Transfer';Source=@{ConfigRef='Values.Media.License'};Destination='C:\Keys\license.xml'}
        @{Id='upload-public-recovery';Kind='Transfer';Source=@{ConfigRef='Values.Media.PublicRecoveryKey'};Destination='C:\recpub.key'}
        @{Id='upload-vault-template';Kind='Transfer';Source=@{ConfigRef='Values.Media.VaultTemplate'};Destination='C:\Cyberark\Automation\Templates\vault-iss.j2'}
        @{Id='prerequisites';Script='Tasks/Common/Install-Prerequisites.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Common/Verify-Prerequisites.ps1';TimeoutSeconds=1500}
        @{Id='extract';Script='Tasks/Common/Expand-Media.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Components=@('Server','PACLI')};Verify='Tasks/Common/Verify-Media.ps1';TimeoutSeconds=1800}
        @{Id='keygen';Script='Tasks/Vault/Generate-Keys.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Keys.ps1';Critical=$true;Publishes=@('primary-keys')}
        @{Id='install-server';Script='Tasks/Vault/Install-Server.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'};AdminPassword=@{SecretRef='VaultAdmin'};MasterPassword=@{SecretRef='VaultMaster'}};RecoveryScript='Tasks/Common/Recover-Management.ps1';Verify='Tasks/Verify/Verify-ServerInstalled.ps1';Critical=$true;TimeoutSeconds=3600}
        @{Id='configure-primary';Script='Tasks/Vault/Configure-PrimaryOnly.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};AdminPassword=@{SecretRef='VaultAdmin'}};Verify='Tasks/Verify/Verify-Primary.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=$true;Critical=$true;TimeoutSeconds=900}
        @{Id='harden-primary';Script='Tasks/Vault/Harden-Vault.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};RecoveryScript='Tasks/Common/Recover-Management.ps1';Verify='Tasks/Verify/Verify-Hardening.ps1';Critical=$true;TimeoutSeconds=3600}
        @{Id='hardening-reboot';Kind='Reboot';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Hardening.ps1';TimeoutSeconds=1800}
        @{Id='verify-primary';Script='Tasks/Vault/Wait-PrimaryReady.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};AdminPassword=@{SecretRef='VaultAdmin'}};Verify='Tasks/Verify/Verify-Primary.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=$true;Critical=$true;Publishes=@('primary-ready')}
    )
}
