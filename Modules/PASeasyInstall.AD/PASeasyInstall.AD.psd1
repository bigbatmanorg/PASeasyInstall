@{
    RootModule='PASeasyInstall.AD.psm1'
    ModuleVersion='0.1.0'
    GUID='e2f229b5-480e-5ebe-bc42-64defb9bb8cd'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Optional Active Directory deployment and read-only planning without CyberArk Vault installation. Part of PASeasyInstall, intended for building CyberArk PAM labs; production use is at your own risk.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'New-PASADConfiguration',
        'Get-PASADStages',
        'Invoke-PASAD'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
