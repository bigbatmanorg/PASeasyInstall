@{
    RootModule='PASeasyInstall.DR.psm1'
    ModuleVersion='0.1.0'
    GUID='8cd767a0-d698-59d1-a0a2-41eb9dbe6239'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='DR add-on for a new Primary Vault deployment. Existing Primary attach is deliberately unsupported. Part of PASeasyInstall, intended for building CyberArk PAM labs; production use is at your own risk.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'Add-PASDRConfiguration',
        'Get-PASDRStages',
        'Invoke-PASVaultPair'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
