# Final DR replication test, after primary created the test Safe.
@{SchemaVersion=1;Name='DR final replication test';Target='dr_final';Root='..';Steps=@(
        @{Id='test-safe-replication';Script='Tasks/VaultDR/Wait-Replication.ps1';DependsOn=@('test-safe-created');Mode='Detached';Inputs=@{Settings=@{ConfigRef='Values.Settings'};Restart=$true;Minutes=15;RunId=@{RuntimeRef='RunId'};TestSafe=$true};Verify='Tasks/Verify/Verify-DR.ps1';Critical=$true;TimeoutSeconds=3600;Publishes=@('dr-ready')}
    )
}
