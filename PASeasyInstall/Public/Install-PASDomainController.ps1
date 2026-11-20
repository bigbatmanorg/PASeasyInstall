function Install-PASDomainController {
    <#
    .SYNOPSIS
    Creates a new Active Directory forest for a lab on a Windows server (first domain controller).
    .DESCRIPTION
    Installs the AD DS role on -ComputerName, promotes the server to the first domain controller of a
    new forest named -DomainName, restarts it and verifies the domain. Use it to give a PAM lab its own
    directory; it is not meant to add a domain controller to an existing domain.

    After the promotion the local Administrator of the server is the domain Administrator, with the
    same password.

    The command validates everything first and asks for confirmation. Only then it asks for what you
    did not pass: the Windows account of the server and the Directory Services Restore Mode password.
    With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached
    controller process and keeps running when you close the console. The command returns the run id;
    follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

    Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER ComputerName
    IP address or DNS name of the Windows server that becomes the domain controller.
    .PARAMETER DomainName
    DNS name of the new forest root domain, e.g. pam.lab.
    .PARAMETER NetBiosName
    NetBIOS name of the domain. Default: the first label of -DomainName in upper case (PAM for pam.lab).
    .PARAMETER Name
    Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it.
    .PARAMETER Credential
    Local administrator of the server. Asked for when missing. The default account name is
    Administrator; to use another account pass it here.
    .PARAMETER SafeModePassword
    Directory Services Restore Mode (DSRM) password to set. Asked for when missing.
    .PARAMETER LabPassword
    One password for the server account and the DSRM password. Only with -SecurityProfile Lab.
    .PARAMETER SecurityProfile
    Secure (default): WinRM over HTTPS with a trusted certificate. Lab: accepts self-signed WinRM
    certificates. Every lab deviation is listed as a warning.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PlanOnly
    Validates the input and returns the plan. Asks nothing and contacts no server.
    .EXAMPLE
    Install-PASDomainController -ComputerName 192.0.2.10 -DomainName pam.lab -Wait

    Creates the forest pam.lab. Asks for the server account and the DSRM password, then shows the progress.
    .EXAMPLE
    $lab = Read-Host -AsSecureString 'Lab password'
    Install-PASDomainController -ComputerName 192.0.2.10 -DomainName pam.lab -SecurityProfile Lab -LabPassword $lab

    Lab install with one password. Returns the run id.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$DomainName,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string]$NetBiosName = '',

        [string]$Name = 'MyPAM',

        [pscredential]$Credential,

        [securestring]$SafeModePassword,

        [securestring]$LabPassword,

        [ValidateSet('Secure', 'Lab')]
        [string]$SecurityProfile = 'Secure',

        [switch]$Wait,

        [switch]$PlanOnly
    )

    $domain = $DomainName.Trim()
    $netbios = $domain.Split('.')[0].ToUpperInvariant()
    $component = @{ id = 'ad'; type = 'AD'; host = 'dc01'; variant = 'NewForest' }
    if ($NetBiosName) {
        $netbios = $NetBiosName
        $component['options'] = @{ domainNetbios = $NetBiosName }
    }

    # The Lab profile accepts the self-signed WinRM certificate of a freshly installed server.
    $overrides = @{}
    if ($SecurityProfile -eq 'Lab') {
        $overrides['WinRM.SkipCACheck'] = $true
        $overrides['WinRM.SkipCNCheck'] = $true
    }

    # A configuration with one server (dc01) and one component (ad). No Vault is installed: the vault
    # block only carries the standard secret names.
    $configuration = [ordered]@{
        schemaVersion     = 2
        name              = $Name.Trim()
        mediaRoot         = ''
        controllerAddress = ''
        security          = @{ profile = $SecurityProfile; overrides = $overrides }
        vault             = @{
            address         = ''
            adminUser       = 'Administrator'
            secretRef       = 'VaultAdmin'
            masterSecretRef = 'VaultMaster'
            drSecretRef     = 'DRPassword'
            existing        = $true
        }
        activeDirectory   = @{
            mode               = 'Create'
            host               = 'dc01'
            domain             = $domain
            join               = @()
            joinUser           = ($netbios + '\Administrator')
            createTestAccounts = $false
        }
        hosts             = @{
            dc01 = @{
                address       = $ComputerName.Trim()
                os            = 'Windows'
                user          = (Get-PASAccountName -Credential $Credential -Default 'Administrator')
                credentialRef = 'dc01'
            }
        }
        components        = @($component)
        media             = @{}
        options           = @{}
    }

    $credentialMap = @{}
    if ($Credential) {
        $credentialMap['dc01'] = $Credential
    }
    $secretMap = @{}
    if ($SafeModePassword) {
        $secretMap['ADSafeMode'] = $SafeModePassword
    }
    $install = @{
        Configuration = $configuration
        Cmdlet        = $PSCmdlet
        Action        = "Create the Active Directory forest $domain (environment '$Name')"
        Target        = $ComputerName.Trim()
        CredentialMap = $credentialMap
        SecretMap     = $secretMap
        LabPassword   = $LabPassword
        PlanOnly      = $PlanOnly
        Wait          = $Wait
    }
    return (Invoke-PASInstallCommand @install)
}
