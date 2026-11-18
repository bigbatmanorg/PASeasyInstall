@{
    RootModule='PASeasyInstall.CPM.psm1'
    ModuleVersion='0.1.0'
    GUID='ff2c45b7-1d63-59e9-8f3b-d17eef0bdf32'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Independent CPM component setup for an existing CyberArk Vault using Core; no UI dependency. Part of PASeasyInstall, intended for building CyberArk PAM labs; production use is at your own risk.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'New-PASCPMConfiguration',
        'Get-PASCPMStages',
        'Invoke-PASCPM'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
