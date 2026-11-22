@{
    RootModule           = 'PASeasyInstall.psm1'
    ModuleVersion        = '2.0.4'
    GUID                 = '19563e11-6fa7-46a9-bfd5-79a4e449afd6'
    Author               = 'PASeasyInstall contributors'
    CompanyName          = 'Community'
    Copyright            = '(c) PASeasyInstall contributors. MIT License.'
    Description          = 'Builds CyberArk PAM self-hosted labs from one Windows PowerShell 5.1 controller with plain commands: Install-PASVault (Primary Vault, optionally with DR), Install-PASPVWA, Install-PASCPM, Install-PASPSM, Install-PASPSMP, Install-PASDomainController, or a whole lab from one configuration file with Install-PASLab. Installs are durable and resumable (Get-PASRun, Wait-PASRun, Resume-PASRun, Stop-PASRun). Start-PASeasyInstall opens a desktop window that does the same in four steps. The module has no dependencies: the window is drawn with WPF, which is part of Windows. Intended for labs, demos and training; production use is at your own risk. You supply the vendor installation media and license. Not affiliated with or endorsed by CyberArk.'
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
        'Test-PASPreflight', 'Test-PASHealth', 'Export-PASDiagnostics', 'Get-PASRunLog',
        # Desktop window
        'Start-PASeasyInstall'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('CyberArk', 'PAM', 'Lab', 'Installer', 'PowerShell', 'Vault', 'PVWA', 'CPM', 'PSM', 'PSMP', 'Windows', 'Desktop')
            LicenseUri   = 'https://github.com/bigbatmanorg/PASeasyInstall/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/bigbatmanorg/PASeasyInstall'
            ReleaseNotes = '2.0.4: a lab can have an Active Directory domain (New-PASLabConfiguration -DomainMode New creates the forest, joins the PVWA, CPM and PSM servers and applies the CyberArk hardening GPOs; -DomainMode Existing joins a domain you have); new component types PTA and HTML5GW (PSM HTML5 Gateway); Test-PASPreflight verifies the root password of a Linux server; Test-PASHealth needs no DNS record for the PVWA name; retrying a CPM registration no longer creates a second CPM user; -InstallerName and -InstallerCompany; the window starts an installation in the background. 2.0.3: every Install-* command first checks within seconds that each server answers, and stops with the servers that do not (a wrong address no longer leaves an installation waiting); Test-PASPreflight -ConnectivityOnly. Desktop: the Servers step is a plain form with the account and password of every server and the Vault passwords, and Next checks the servers before the plan is shown. 2.0.2: Start-PASeasyInstall opens the window in its own process, so it also works from an interactive console (2.0.1 failed there with an OSArchitecture error) and the prompt stays free. 2.0.1: one module again. The desktop window is part of this module: Start-PASeasyInstall opens it, and there is no separate PASeasyInstall.UI module. The window is new: four steps (media, lab, servers, install), a page per installation with progress, retry and a lab check. The VC++ runtimes for the Vault are taken from the CPM, PVWA or PSM package. 2.0.0: a new, simple command set. Install-PASVault, Install-PASPVWA, Install-PASCPM, Install-PASPSM, Install-PASPSMP and Install-PASDomainController install one component from the prompt; Install-PASLab installs a whole lab from a configuration (New-/Test-/Export-/Import-PASLabConfiguration, Get-PASLabPlan); Get-PASRun, Get-PASRunEvent, Wait-PASRun, Resume-PASRun and Stop-PASRun follow and control a run; Test-PASPreflight (new), Test-PASHealth, Export-PASDiagnostics and Get-PASRunLog check and diagnose. Breaking since 1.0: the 1.0 command names are gone and the module requires no other module. Tested with PAM 15.0 and 15.2. Intended for labs; production use is at your own risk. See https://bigbatmanorg.github.io/PASeasyInstall/release-notes/'
        }
    }
}
