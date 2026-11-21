@{
RootModule='PASeasyInstall.Mock.psm1'
ModuleVersion='2.0.0'
GUID='3c4f0f8e-6a52-4a8e-9d55-2b8f6f0f7a11'
Author='PASeasyInstall'
Description='Simulator backend for the PASeasyInstall desktop. Uses the real PASeasyInstall module for media, configuration, validation and plans, and simulates the installation run. Contacts no server.'
PowerShellVersion='5.1'
CompatiblePSEditions=@('Desktop')
FunctionsToExport=@('Get-PASMediaInventory','Get-PASMediaSelection','New-PASLabConfiguration','Test-PASLabConfiguration',
    'Get-PASLabPlan','Get-PASCredentialRequirement','Export-PASLabConfiguration','Import-PASLabConfiguration',
    'Install-PASLab','Get-PASRun','Get-PASRunEvent','Get-PASStageCatalog','Resume-PASRun','Stop-PASRun','Export-PASDiagnostics',
    'Test-PASPreflight','Test-PASHealth')
CmdletsToExport=@()
VariablesToExport=@()
AliasesToExport=@()
}
