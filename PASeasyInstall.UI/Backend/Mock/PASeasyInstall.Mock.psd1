@{
RootModule='PASeasyInstall.Mock.psm1'
ModuleVersion='0.5.0'
GUID='3c4f0f8e-6a52-4a8e-9d55-2b8f6f0f7a11'
Author='PASeasyInstall'
Description='Dummy UI backend. Same public commands as PASeasyInstall.Orchestrator; simulates plans and runs, touches no servers.'
PowerShellVersion='5.1'
CompatiblePSEditions=@('Desktop','Core')
FunctionsToExport=@('Get-PASMediaInventory','Get-PASMediaSelection','New-PASDeploymentConfiguration','New-PASFreshEnvironment','New-PASExistingVaultComponent','Test-PASEnvironment',
    'Get-PASEnvironmentPlan','Save-PASEnvironment','Start-PASEnvironment','Get-PASEnvironmentSnapshot',
    'Get-PASEnvironmentEvents','Get-PASStageCatalog','Request-PASeasyUICredential')
CmdletsToExport=@()
VariablesToExport=@()
AliasesToExport=@()
}
