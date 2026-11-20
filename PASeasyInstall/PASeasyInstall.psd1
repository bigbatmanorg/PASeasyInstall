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
        'Resume-PASeasyDeployment', 'Test-PASEnvironmentHealth', 'Export-PASRunData', 'Close-PASDeployment'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('CyberArk', 'PAM', 'Lab', 'Installer', 'PowerShell', 'Vault', 'PVWA', 'CPM', 'PSM', 'PSMP', 'Windows', 'Desktop')
            LicenseUri   = 'https://github.com/bigbatmanorg/PASeasyInstall/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/bigbatmanorg/PASeasyInstall'
            ReleaseNotes = '1.0.0: first public release. Builds CyberArk PAM labs (Vault, Primary + DR, PVWA, CPM, PSM, PSMP, Active Directory) from a desktop wizard or the command line; tested with PAM 15.0 and 15.2. Intended for labs; production use is at your own risk. See https://bigbatmanorg.github.io/PASeasyInstall/release-notes/'
        }
    }
}
