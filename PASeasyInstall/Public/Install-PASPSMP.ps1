function Install-PASPSMP {
    <#
    .SYNOPSIS
    Installs the CyberArk PSM for SSH proxy (PSMP) on a Linux server and registers it with an existing Vault.
    .DESCRIPTION
    Signs in to the Linux server with SSH as root, uploads the installer package that matches the
    distribution of the server, installs and registers PSMP, applies the hardening and verifies the
    result. Install PVWA first: the PSMP registration needs the PVWA environment in the Vault.

    SSH uses a key of this controller, kept under <data folder>\ssh\<Name>. On the first install the key
    is created and the root password is used once to authorise it on the server; the password is not
    stored. With the Lab profile the host key of the server is trusted on first use (logged as a
    deviation). With the Secure profile the host key must already be in the known_hosts file there.

    -MediaPath is the PSMP installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the
    newest matching package is used.

    The command validates everything first and asks for confirmation. Only then it asks for what you
    did not pass: the root password of the server and the password of the Vault user Administrator.
    With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached
    controller process and keeps running when you close the console. The command returns the run id;
    follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

    Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER ComputerName
    IP address or DNS name of the server to install PSMP on.
    .PARAMETER VaultAddress
    IP address or DNS name of the Vault the component registers with.
    .PARAMETER MediaPath
    The PSMP installer ZIP, or a folder or CyberArk bundle ZIP that contains it.
    .PARAMETER Name
    Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it.
    .PARAMETER Credential
    The root account of the Linux server and its password. Asked for when missing. PSMP is installed
    as root; another account is refused.
    .PARAMETER VaultAdminPassword
    Password of the Vault user Administrator, used to register the component. Asked for when missing.
    .PARAMETER LabPassword
    One password for the server account and the Vault Administrator. Only with -SecurityProfile Lab.
    .PARAMETER SecurityProfile
    Secure (default): the SSH host key of the server must already be known. Lab: the host key is
    trusted on first use. Every lab deviation is listed as a warning.
    .PARAMETER Options
    Further recipe options as a hashtable. They are stored in the configuration (components[].options)
    and win over the defaults. Supported for PSMP: serverId, signingKeyFingerprint.
    .PARAMETER AcceptEula
    Confirms that you read and accept the CyberArk end user license agreement of the PSMP installer.
    Required: without it the configuration is not valid.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PlanOnly
    Validates the input and returns the plan. Asks nothing and contacts no server.
    .EXAMPLE
    Install-PASPSMP -ComputerName 192.0.2.25 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -AcceptEula -SecurityProfile Lab -Wait

    Installs PSMP in a lab. Asks for the root password and the Vault Administrator password, then
    shows the progress.
    .EXAMPLE
    Install-PASPSMP -ComputerName psmp01.pam.lab -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -AcceptEula -WhatIf

    Validates the input and says what would be installed. Nothing is asked or contacted.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$VaultAddress,

        [Parameter(Mandatory)]
        [string]$MediaPath,

        [string]$Name = 'MyPAM',

        [pscredential]$Credential,

        [securestring]$VaultAdminPassword,

        [securestring]$LabPassword,

        [ValidateSet('Secure', 'Lab')]
        [string]$SecurityProfile = 'Secure',

        [hashtable]$Options = @{},

        [switch]$AcceptEula,

        [switch]$Wait,

        [switch]$PlanOnly
    )

    # Work on a copy: the caller's hashtable is not changed.
    $componentOptions = @{}
    foreach ($key in @($Options.Keys)) {
        $componentOptions[[string]$key] = $Options[$key]
    }

    $install = @{
        Type = 'PSMP'
        Cmdlet = $PSCmdlet
        ComputerName = $ComputerName
        VaultAddress = $VaultAddress
        MediaPath = $MediaPath
        Name = $Name
        Credential = $Credential
        VaultAdminPassword = $VaultAdminPassword
        LabPassword = $LabPassword
        SecurityProfile = $SecurityProfile
        Options = $componentOptions
        AcceptEula = $AcceptEula
        Wait = $Wait
        PlanOnly = $PlanOnly
    }
    return (Invoke-PASComponentInstall @install)
}
