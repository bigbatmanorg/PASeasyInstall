@{
    RootModule='PASeasyInstall.Vault.psm1'
    ModuleVersion='0.1.0'
    GUID='9bd5f76f-2e60-5f3d-9d24-4dffe1cfad2b'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Install a fresh Primary CyberArk Vault using the shared durable engine, independently of the GUI. Part of PASeasyInstall, intended for building CyberArk PAM labs; production use is at your own risk.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'New-PASVaultConfiguration',
        'Get-PASVaultStages',
        'Invoke-PASVault'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('CyberArk','PASeasyInstall','PowerShell','Modular')}}
}
