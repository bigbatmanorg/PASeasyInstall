# Proves the Safe created by ReplicationPrimary reaches the DR Vault (PAREP0213I followed by PADR0010I).
@{
    SchemaVersion=1; Name='Safe replication test - DR'; Target='dr'; Root='../..'
    Steps=@( @{Id='test-safe-replication';Script='Tasks/VaultDR/Wait-Replication.ps1';DependsOn=@('test-safe-created');Inputs=@{Settings=@{ConfigRef='Values.Settings'};Restart=$true;Minutes=15;RunId=@{RuntimeRef='RunId'};TestSafe=$true};Verify='Tasks/Verify/Verify-DR.ps1';TimeoutSeconds=1800} )
}
