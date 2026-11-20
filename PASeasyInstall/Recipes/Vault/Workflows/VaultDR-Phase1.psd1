# DR Vault FullInstall. PADR is installed BEFORE hardening (StandardVault hardening disables msiserver).
@{
    SchemaVersion=1; Name='CyberArk Vault 15.0 DR FullInstall'; Target='dr'; Root='..'
    Steps=@(
        @{Id='preflight';Script='Tasks/Common/Test-Preflight.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Role='DR'};Verify='Tasks/Common/Verify-Preflight.ps1'}
        @{Id='management-endpoint';Script='Tasks/Common/Register-ManagementEndpoint.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Common/Verify-ManagementEndpoint.ps1';Critical=$true;TimeoutSeconds=600}
        @{Id='prepare-paths';Script='Tasks/Common/Prepare-Paths.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Role='DR'};Verify='Tasks/Common/Verify-Paths.ps1'}
        @{Id='upload-vc-x86';Kind='Transfer';Source=@{ConfigRef='Values.Media.VCx86'};Destination='C:\Cyberark\Automation\Prerequisites\VC_redist.x86.exe'}
        @{Id='upload-vc-x64';Kind='Transfer';Source=@{ConfigRef='Values.Media.VCx64'};Destination='C:\Cyberark\Automation\Prerequisites\VC_redist.x64.exe'}
        @{Id='upload-vc2013-x86';Kind='Transfer';Source=@{ConfigRef='Values.Media.VC2013x86'};Destination='C:\Cyberark\Automation\Prerequisites\vcredist_x86.exe'}
        @{Id='upload-server';Kind='Transfer';Source=@{ConfigRef='Values.Media.ServerZip'};Destination='C:\Cyberark\packages\Server-Rls.zip';TimeoutSeconds=3600}
        @{Id='upload-dr';Kind='Transfer';Source=@{ConfigRef='Values.Media.DisasterRecoveryZip'};Destination='C:\Cyberark\packages\Disaster Recovery-Rls.zip'}
        @{Id='upload-license';Kind='Transfer';Source=@{ConfigRef='Values.Media.License'};Destination='C:\Keys\license.xml'}
        @{Id='upload-public-recovery';Kind='Transfer';Source=@{ConfigRef='Values.Media.PublicRecoveryKey'};Destination='C:\recpub.key'}
        @{Id='upload-vault-template';Kind='Transfer';Source=@{ConfigRef='Values.Media.VaultTemplate'};Destination='C:\Cyberark\Automation\Templates\vault-iss.j2'}
        @{Id='upload-dr-template';Kind='Transfer';Source=@{ConfigRef='Values.Media.DRTemplate'};Destination='C:\Cyberark\Automation\Templates\vaultdr-iss.j2'}
        @{Id='prerequisites';Script='Tasks/Common/Install-Prerequisites.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Common/Verify-Prerequisites.ps1';TimeoutSeconds=1500}
        @{Id='extract';Script='Tasks/Common/Expand-Media.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Components=@('Server','Disaster Recovery')};Verify='Tasks/Common/Verify-Media.ps1';TimeoutSeconds=1800}
        @{Id='await-primary-keys';Kind='Wait';Milestone='primary-keys';TimeoutSeconds=7200}
        @{Id='relay-shared-keys';Kind='Relay';SourceTarget='primary';SourceDir='C:\Keys';DestinationDir='C:\Keys';Files=@('server.key','recprv.key','recpub.key','rndbase.dat','.paeasy-key-generation.claim.json','.paeasy-key-generation.json');Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Keys.ps1'}
        @{Id='install-dr-server';Script='Tasks/Vault/Install-Server.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'};AdminPassword=@{SecretRef='VaultAdmin'};MasterPassword=@{SecretRef='VaultMaster'}};RecoveryScript='Tasks/Common/Recover-Management.ps1';Verify='Tasks/Verify/Verify-ServerInstalled.ps1';Critical=$true;TimeoutSeconds=3600}
        @{Id='prepare-standby';Script='Tasks/VaultDR/Prepare-Standby.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Standby.ps1';Critical=$true}
        @{Id='await-primary-ready';Kind='Wait';Milestone='primary-ready';TimeoutSeconds=10800}
        @{Id='install-padr';Script='Tasks/VaultDR/Install-PADR.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'};DRPassword=@{SecretRef='DRPassword'}};RecoveryScript='Tasks/Common/Recover-Management.ps1';Verify='Tasks/Verify/Verify-PADRInstalled.ps1';Critical=$true;TimeoutSeconds=2700}
        @{Id='configure-padr';Script='Tasks/VaultDR/Configure-PADR.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-PADRInstalled.ps1';Critical=$true}
        @{Id='first-replication';Script='Tasks/VaultDR/Wait-Replication.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Minutes=30};Verify='Tasks/Verify/Verify-DR.ps1';Critical=$true;TimeoutSeconds=2400}
        @{Id='harden-dr';Script='Tasks/Vault/Harden-Vault.ps1';Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};RecoveryScript='Tasks/Common/Recover-Management.ps1';Verify='Tasks/Verify/Verify-Hardening.ps1';Critical=$true;TimeoutSeconds=3600}
        @{Id='hardening-reboot';Kind='Reboot';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Hardening.ps1';TimeoutSeconds=1800}
        @{Id='replication-after-hardening';Script='Tasks/VaultDR/Wait-Replication.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Restart=$true;Minutes=20};Verify='Tasks/Verify/Verify-DR.ps1';Critical=$true;TimeoutSeconds=1800;Publishes=@('dr-replicating')}
    )
}
