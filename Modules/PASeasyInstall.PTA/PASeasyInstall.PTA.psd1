@{
    RootModule='PASeasyInstall.PTA.psm1'
    ModuleVersion='0.1.0'
    GUID='3698a21d-adea-5713-bf04-85e560ae2731'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Independent PTA component setup for an existing CyberArk Vault using Core; no UI dependency. Part of PASeasyInstall, intended for building CyberArk PAM labs; production use is at your own risk.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'New-PASPTAConfiguration',
        'Get-PASPTAStages',
        'Invoke-PASPTA'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
