@{
    RootModule           = 'PASeasyInstall.psm1'
    ModuleVersion        = '2.0.0'
    GUID                 = '19563e11-6fa7-46a9-bfd5-79a4e449afd6'
    Author               = 'PASeasyInstall contributors'
    CompanyName          = 'Community'
    Copyright            = '(c) PASeasyInstall contributors. MIT License.'
    Description          = 'Builds CyberArk PAM self-hosted labs from one Windows PowerShell 5.1 controller with plain commands: Install-PASVault (Primary Vault, optionally with DR), Install-PASPVWA, Install-PASCPM, Install-PASPSM, Install-PASPSMP, Install-PASDomainController, or a whole lab from one configuration file with Install-PASLab. Installs are durable and resumable (Get-PASRun, Wait-PASRun, Resume-PASRun, Stop-PASRun). This module has no dependencies; the optional desktop wizard is the separate module PASeasyInstall.UI. Intended for labs, demos and training; production use is at your own risk. You supply the vendor installation media and license. Not affiliated with or endorsed by CyberArk.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')
    # One entry per file in the Public folder. Keep both identical.
    FunctionsToExport    = @(
        # Install
        'Install-PASVault', 'Install-PASPVWA', 'Install-PASCPM', 'Install-PASPSM', 'Install-PASPSMP',
        'Install-PASDomainController', 'Install-PASLab',
        # Configuration of a whole lab
        'New-PASLabConfiguration', 'Test-PASLabConfiguration', 'Get-PASLabPlan',
        'Export-PASLabConfiguration', 'Import-PASLabConfiguration',
        'Get-PASMediaInventory', 'Get-PASMediaSelection', 'Get-PASCredentialRequirement', 'Get-PASStageCatalog',
        # Runs
        'Get-PASRun', 'Get-PASRunEvent', 'Wait-PASRun', 'Resume-PASRun', 'Stop-PASRun',
        # Checks and diagnostics
        'Test-PASPreflight', 'Test-PASHealth', 'Export-PASDiagnostics', 'Get-PASRunLog'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('CyberArk', 'PAM', 'Lab', 'Installer', 'PowerShell', 'Vault', 'PVWA', 'CPM', 'PSM', 'PSMP', 'Windows', 'Desktop')
            LicenseUri   = 'https://github.com/bigbatmanorg/PASeasyInstall/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/bigbatmanorg/PASeasyInstall'
            ReleaseNotes = '2.0.0: one self-contained module with a new, simple command set. Install-PASVault, Install-PASPVWA, Install-PASCPM, Install-PASPSM, Install-PASPSMP and Install-PASDomainController install one component from the prompt; Install-PASLab installs a whole lab from a configuration (New-/Test-/Export-/Import-PASLabConfiguration, Get-PASLabPlan); Get-PASRun, Get-PASRunEvent, Wait-PASRun, Resume-PASRun and Stop-PASRun follow and control a run; Test-PASPreflight (new), Test-PASHealth, Export-PASDiagnostics and Get-PASRunLog check and diagnose. Breaking: the 1.0 command names are gone and the module no longer requires NativeHTMLKit.UI. The desktop wizard moved to the separate module PASeasyInstall.UI, which only calls these commands. Tested with PAM 15.0 and 15.2. Intended for labs; production use is at your own risk. See https://bigbatmanorg.github.io/PASeasyInstall/release-notes/'
        }
    }
}
