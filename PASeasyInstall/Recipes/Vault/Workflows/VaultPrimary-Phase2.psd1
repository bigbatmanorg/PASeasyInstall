# Final verification of primary/DR test Safe; runs after DR replication ready.
@{SchemaVersion=1;Name='Primary final replication test';Target='primary_final';Root='..';Steps=@(
        @{Id='create-test-safe';Script='Tasks/Vault/New-TestSafe.ps1';DependsOn=@('dr-replicating');Mode='Detached';RequiresVaultSession=$true;Inputs=@{Settings=@{ConfigRef='Values.Settings'};AdminPassword=@{SecretRef='VaultAdmin'};RunId=@{RuntimeRef='RunId'}};Verify='Tasks/Verify/Verify-TestSafe.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=$true;Critical=$true;TimeoutSeconds=10800;Publishes=@('test-safe-created')}
    )
}
