@{
    RootModule='PASeasyInstall.PSMP.psm1'
    ModuleVersion='0.1.0'
    GUID='9214ac12-cbd5-5def-a4d2-e825f13f7386'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Independent PSMP component setup for an existing CyberArk Vault using Core; no UI dependency.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'New-PASPSMPConfiguration',
        'Get-PASPSMPStages',
        'Invoke-PASPSMP'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
