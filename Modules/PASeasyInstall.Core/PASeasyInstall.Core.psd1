@{
    RootModule='PASeasyInstall.Core.psm1'
    ModuleVersion='2.0.0'
    GUID='e3386dda-0c8c-5199-b482-0d8868b5e6a4'
    Author='PASeasyInstall contributors'
    CompanyName='Community'
    Copyright='Copyright (c) 2026 PASeasyInstall contributors'
    Description='Shared PowerShell installation engine: secure transports, frozen workflows, event journals, recovery, and read-only diagnostics. No GUI dependency.'
    PowerShellVersion='5.1'
    CompatiblePSEditions=@('Desktop','Core')
    FunctionsToExport=@(
        'Initialize-PASeasyController','New-PASeasyConfig','Test-PASeasyConfig','Get-PASeasyPlan',
        'Start-PASeasyDeployment','Resume-PASeasyDeployment',
        'Get-PASeasyRun','Get-PASeasyRuns','Get-PASeasyLog',
        'Get-PASeasyLogSources','Get-PASeasyComponentStatus',
        'Test-PASeasyDeployment','Get-PASDeploymentEvents','Get-PASDeploymentSnapshot'
    )
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{
        Tags=@('CyberArk','PowerShell','PAM','Automation','NativeHTMLKit')
        LicenseUri='https://opensource.org/licenses/MIT'
        ProjectUri='https://github.com/bigbatmanorg/PASeasyInstall'
        ReleaseNotes='Modular UI-first refactor of v2: durable Windows/Linux deployment, immutable plans, resume and reboot recovery, serialized Vault sessions, and optional NativeHTMLKit UI. See project documentation for qualified versions, scenarios and limitations.'
    }}
}
