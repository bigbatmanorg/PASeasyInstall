function Install-PASPSM {
    <#
    .SYNOPSIS
    Installs the CyberArk Privileged Session Manager (PSM) on a Windows server and registers it with an existing Vault.
    .DESCRIPTION
    Uploads the installer, installs the prerequisites (Remote Desktop Session Host) and PSM, registers PSM
    with the Vault, applies the vendor hardening and verifies the result. The server restarts several
    times; the run continues by itself. Install PVWA first: the PSM registration needs the PVWA
    environment in the Vault.

    -MediaPath is the PSM installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the
    newest matching package is used.

    The command validates everything first and asks for confirmation. Only then it asks for what you
    did not pass: the Windows account of the server and the password of the Vault user Administrator.
    With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached
    controller process and keeps running when you close the console. The command returns the run id;
    follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

    Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER ComputerName
    IP address or DNS name of the server to install PSM on.
    .PARAMETER VaultAddress
    IP address or DNS name of the Vault the component registers with.
    .PARAMETER MediaPath
    The PSM installer ZIP, or a folder or CyberArk bundle ZIP that contains it.
    .PARAMETER Name
    Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it.
    .PARAMETER Credential
    Local administrator of the server (or a domain account that is administrator there). Asked for
    when missing. The default account name is Administrator; to use another account pass it here.
    .PARAMETER VaultAdminPassword
    Password of the Vault user Administrator, used to register the component. Asked for when missing.
    .PARAMETER LabPassword
    One password for the server account and the Vault Administrator. Only with -SecurityProfile Lab.
    .PARAMETER SecurityProfile
    Secure (default): WinRM over HTTPS with a trusted certificate. Lab: accepts self-signed WinRM
    certificates. Every lab deviation is listed as a warning.
    .PARAMETER Options
    Further recipe options as a hashtable. They are stored in the configuration (components[].options)
    and win over the defaults. Supported for PSM: installDirectory, vaultPort.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PlanOnly
    Validates the input and returns the plan. Asks nothing and contacts no server.
    .EXAMPLE
    Install-PASPSM -ComputerName 192.0.2.23 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -Wait

    Installs PSM. Asks for the server account and the Vault Administrator password, then shows the progress.
    .EXAMPLE
    $lab = Read-Host -AsSecureString 'Lab password'
    $id = Install-PASPSM -ComputerName 192.0.2.23 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia\PSM.zip -SecurityProfile Lab -LabPassword $lab
    Wait-PASRun -RunId $id

    Lab install from a renamed installer ZIP with one password; the run is followed afterwards.
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

        [switch]$Wait,

        [switch]$PlanOnly
    )

    # Work on a copy: the caller's hashtable is not changed.
    $componentOptions = @{}
    foreach ($key in @($Options.Keys)) {
        $componentOptions[[string]$key] = $Options[$key]
    }

    $install = @{
        Type = 'PSM'
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
        Wait = $Wait
        PlanOnly = $PlanOnly
    }
    return (Invoke-PASComponentInstall @install)
}
