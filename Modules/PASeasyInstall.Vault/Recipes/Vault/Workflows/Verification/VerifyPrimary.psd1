# Independent read-only acceptance of the primary Vault (no target changes).
@{
    SchemaVersion=1; Name='Primary Vault acceptance (read-only)'; Target='primary'; Root='../..'
    Steps=@(
        @{Id='primary-health';Kind='Verify';Inputs=@{Settings=@{ConfigRef='Values.Settings'};AdminPassword=@{SecretRef='VaultAdmin'}};Verify='Tasks/Verify/Verify-Primary.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=$true}
        @{Id='primary-hardening';Script='Tasks/Verify/Verify-Hardening.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Hardening.ps1'}
        @{Id='primary-endpoint';Script='Tasks/Common/Verify-ManagementEndpoint.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Common/Verify-ManagementEndpoint.ps1'}
    )
}
