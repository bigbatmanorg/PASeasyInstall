# Creates a new deterministic Safe (named from this verification run ID) on the primary.
@{
    SchemaVersion=1; Name='Safe replication test - primary'; Target='primary'; Root='../..'
    Steps=@( @{Id='create-test-safe';Script='Tasks/Vault/New-TestSafe.ps1';Mode='Detached';RequiresVaultSession=$true;Inputs=@{Settings=@{ConfigRef='Values.Settings'};AdminPassword=@{SecretRef='VaultAdmin'};RunId=@{RuntimeRef='RunId'}};Verify='Tasks/Verify/Verify-TestSafe.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=$true;Publishes=@('test-safe-created')} )
}
