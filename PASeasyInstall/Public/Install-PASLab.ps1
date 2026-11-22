function Install-PASLab {
    <#
    .SYNOPSIS
    Installs everything a lab configuration describes: Vault, DR, PVWA, CPM, PSM, PSMP, HTML5 Gateway, PTA, Active Directory.
    .DESCRIPTION
    Takes a configuration file (written by Export-PASLabConfiguration or saved by the desktop wizard)
    or a configuration object (from New-PASLabConfiguration). The servers are installed at the same
    time. A step that registers a component with the Vault waits until the Vault is installed; the
    registrations then run one at a time: every PVWA, every CPM, then the other components. A
    configuration with execution.mode Sequential installs one component after the other instead:
    Active Directory, domain joins, Vault and DR, then PVWA, CPM, PSM, PSMP.

    The command validates the configuration and the installer media and asks for confirmation. Only
    then it asks for every server account and password that -CredentialMap, -SecretMap or -LabPassword
    do not supply. With -WhatIf nothing is asked and nothing is contacted. Get-PASCredentialRequirement
    lists what a configuration needs; Get-PASLabPlan shows what would be installed.

    The installation runs in a detached controller process and keeps running when you close the
    console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait.
    A run that stopped is continued with Resume-PASRun.

    Passwords are kept in memory only. They are never written to the configuration, a log or a command
    line. PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER Path
    Configuration file (JSON).
    .PARAMETER Configuration
    Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration.
    .PARAMETER CredentialMap
    Server accounts: @{ <server id> = PSCredential }. The server ids are the keys of "hosts" in the
    configuration. Servers that are missing here are asked for.
    .PARAMETER SecretMap
    Passwords as SecureString: @{ VaultAdmin = ...; VaultMaster = ...; DRPassword = ...;
    ADSafeMode = ...; DomainJoinPassword = ... }. Only the ones the configuration needs; missing ones
    are asked for.
    .PARAMETER LabPassword
    One password for every server and every secret that is not supplied otherwise. Only for a
    configuration with the Lab security profile.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PollSeconds
    With -Wait: seconds between two progress checks. Default 15.
    .EXAMPLE
    Install-PASLab -Path .\MyLab.json -Wait

    Asks for the accounts and passwords the lab needs, installs it and shows the progress.
    .EXAMPLE
    $lab = Read-Host -AsSecureString 'Lab password'
    $id = Install-PASLab -Path .\MyLab.json -LabPassword $lab
    Get-PASRun -RunId $id

    Starts the installation with one lab password and looks at the run.
    .EXAMPLE
    $creds = @{ vault01 = (Get-Credential Administrator); pvwa01 = (Get-Credential Administrator) }
    $secrets = @{ VaultAdmin = (Read-Host -AsSecureString 'Vault Administrator'); VaultMaster = (Read-Host -AsSecureString 'Vault Master') }
    Install-PASLab -Configuration $cfg -CredentialMap $creds -SecretMap $secrets -Confirm:$false

    Unattended start with everything supplied.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Configuration', ValueFromPipeline)]
        $Configuration,

        [hashtable]$CredentialMap = @{},

        [hashtable]$SecretMap = @{},

        [securestring]$LabPassword,

        [switch]$Wait,

        [ValidateRange(1, 600)]
        [int]$PollSeconds = 15
    )

    process {
        $description = 'the given configuration'
        if ($Path) {
            # Read the file here so that the same code path handles both parameter sets.
            $source = Resolve-PASConfigurationInput -Path $Path
            $description = $source.Config
            $Configuration = Import-PASLabConfiguration -Path $source.Config
        }
        $install = @{
            Configuration = $Configuration
            Cmdlet = $PSCmdlet
            Action = "Install the CyberArk lab described by $description"
            CredentialMap = $CredentialMap
            SecretMap = $SecretMap
            LabPassword = $LabPassword
            Wait = $Wait
            PollSeconds = $PollSeconds
        }
        return (Invoke-PASInstallCommand @install)
    }
}
