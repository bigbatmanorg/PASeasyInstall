# Independent read-only acceptance of the DR Vault (no target changes).
@{
    SchemaVersion=1; Name='DR Vault acceptance (read-only)'; Target='dr'; Root='../..'
    Steps=@(
        @{Id='dr-replication';Script='Tasks/Verify/Verify-DR.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-DR.ps1'}
        @{Id='dr-standby';Script='Tasks/Verify/Verify-Standby.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Standby.ps1'}
        @{Id='dr-hardening';Script='Tasks/Verify/Verify-Hardening.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Verify/Verify-Hardening.ps1'}
        @{Id='dr-endpoint';Script='Tasks/Common/Verify-ManagementEndpoint.ps1';Inputs=@{Settings=@{ConfigRef='Values.Settings'}};Verify='Tasks/Common/Verify-ManagementEndpoint.ps1'}
    )
}
