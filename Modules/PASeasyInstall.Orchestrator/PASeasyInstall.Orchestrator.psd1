@{
    RootModule='PASeasyInstall.Orchestrator.psm1'
    ModuleVersion='1.0.0'
    GUID='693f89a1-6f88-5475-98e8-4a7e76db2dad'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Description='Component composition (media inventory, multi-instance deployments, sequential or parallel execution), dry-run plan, saved configuration and run snapshot commands. No UI dependency. Part of PASeasyInstall, intended for building CyberArk PAM labs; production use is at your own risk.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@('New-PASFreshEnvironment','New-PASExistingVaultComponent',
        'Get-PASMediaInventory','Get-PASMediaSelection','New-PASDeploymentConfiguration',
        'Test-PASEnvironment','Get-PASEnvironmentPlan','Save-PASEnvironment','Start-PASEnvironment',
        'Get-PASEnvironmentSnapshot','Get-PASEnvironmentEvents','Get-PASStageCatalog',
        'Test-PASEnvironmentHealth','Export-PASRunData')
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
}
