@{
    RootModule           = 'PASeasyInstall.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '19563e11-6fa7-46a9-bfd5-79a4e449afd6'
    Author               = 'PASeasyInstall contributors'
    CompanyName          = 'Community'
    Copyright            = '(c) PASeasyInstall contributors. MIT License.'
    Description          = 'Builds CyberArk PAM self-hosted labs from one Windows PowerShell 5.1 controller: Primary Vault (optionally with DR), PVWA, CPM, PSM, PSMP and an Active Directory lab forest, through a native desktop wizard (Start-PASeasyInstall) or the command line (Invoke-PASeasyInstall). Durable, resumable, hardened installs with live progress. Intended for labs, demos and training; production use is at your own risk. You supply the vendor installation media and license. Not affiliated with or endorsed by CyberArk.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')
    RequiredModules      = @(@{ ModuleName = 'NativeHTMLKit.UI'; ModuleVersion = '0.1.1' })
    FunctionsToExport    = @(
        'Start-PASeasyInstall', 'Invoke-PASeasyInstall',
        'New-PASDeploymentConfiguration', 'Get-PASMediaInventory', 'Get-PASMediaSelection',
        'Test-PASEnvironment', 'Get-PASEnvironmentPlan', 'Save-PASEnvironment', 'Start-PASEnvironment',
        'Get-PASEnvironmentSnapshot', 'Get-PASEnvironmentEvents', 'Get-PASStageCatalog',
        'Resume-PASeasyDeployment', 'Test-PASEnvironmentHealth', 'Export-PASRunData'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('CyberArk', 'PAM', 'Lab', 'Installer', 'PowerShell', 'Vault', 'PVWA', 'CPM', 'PSM', 'PSMP', 'Windows', 'Desktop')
            LicenseUri   = 'https://github.com/bigbatmanorg/PASeasyInstall/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/bigbatmanorg/PASeasyInstall'
            Prerelease   = 'rc1'
            ReleaseNotes = '1.0.0-rc1: first public release candidate. Desktop wizard and CLI for Vault (Primary, Primary + DR), PVWA, CPM, PSM, PSMP and an AD lab forest; sequential or parallel installs; health check (Test-PASEnvironmentHealth) and sanitized run export (Export-PASRunData). Lab-focused; production use at your own risk. The module is not Authenticode-signed (see the documentation for the process-scoped execution policy command). PTA is not part of this release.'
        }
    }
}
