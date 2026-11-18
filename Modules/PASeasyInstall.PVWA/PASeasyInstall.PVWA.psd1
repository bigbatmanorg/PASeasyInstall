@{
    RootModule='PASeasyInstall.PVWA.psm1'
    ModuleVersion='0.1.0'
    GUID='113dd3f7-d458-5a72-8951-3cf76d71aebc'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Independent PVWA component setup for an existing CyberArk Vault using Core; no UI dependency. Part of PASeasyInstall, intended for building CyberArk PAM labs; production use is at your own risk.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'New-PASPVWAConfiguration',
        'Get-PASPVWAStages',
        'Invoke-PASPVWA'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
