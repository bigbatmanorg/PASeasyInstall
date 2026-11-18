@{
    RootModule='PASeasyInstall.PSM.psm1'
    ModuleVersion='0.1.0'
    GUID='023c6efc-0ff8-5246-b046-6e0ec9739ba6'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Independent PSM component setup for an existing CyberArk Vault using Core; no UI dependency.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'New-PASPSMConfiguration',
        'Get-PASPSMStages',
        'Invoke-PASPSM'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
