function Install-PASPVWA {
    <#
    .SYNOPSIS
    Installs CyberArk Password Vault Web Access (PVWA) on a Windows server and registers it with an existing Vault.
    .DESCRIPTION
    Uploads the installer, installs the prerequisites and PVWA, binds the HTTPS certificate, registers PVWA
    with the Vault, applies the vendor hardening and verifies the result.

    -MediaPath is the PVWA installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the
    newest matching package is used.

    The command validates everything first and asks for confirmation. Only then it asks for what you
    did not pass: the Windows account of the server and the password of the Vault user Administrator.
    With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached
    controller process and keeps running when you close the console. The command returns the run id;
    follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

    Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER ComputerName
    IP address or DNS name of the server to install PVWA on.
    .PARAMETER VaultAddress
    IP address or DNS name of the Vault the component registers with.
    .PARAMETER MediaPath
    The PVWA installer ZIP, or a folder or CyberArk bundle ZIP that contains it.
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
    Secure (default): WinRM over HTTPS with a trusted certificate, and PVWA uses the certificate you
    name with -CertificateThumbprint. Lab: accepts self-signed WinRM certificates and creates a
    self-signed PVWA certificate. Every lab deviation is listed as a warning.
    .PARAMETER Options
    Further recipe options as a hashtable. They are stored in the configuration (components[].options)
    and win over the defaults. Supported for PVWA: pvwaUrl, tlsCertificateThumbprint,
    createLabCertificate, installDirectory, applicationDirectory, applicationName, vaultPort.
    .PARAMETER PvwaUrl
    HTTPS URL users will open, with one application path, e.g. https://pvwa01.pam.lab/PasswordVault
    (option pvwaUrl). Default: https://<ComputerName>/PasswordVault when -ComputerName is a DNS name,
    otherwise https://<computer name of the server>/PasswordVault.
    .PARAMETER CertificateThumbprint
    Thumbprint of the HTTPS certificate for PVWA. The certificate with its private key must already be
    in the LocalMachine\My store of the server (option tlsCertificateThumbprint). Required with the
    Secure profile. With the Lab profile a self-signed certificate is created when you leave it out.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PlanOnly
    Validates the input and returns the plan. Asks nothing and contacts no server.
    .EXAMPLE
    Install-PASPVWA -ComputerName pvwa01.pam.lab -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -CertificateThumbprint 9F2C6E0B7D1A4C35A8E2B4D6F8091A2B3C4D5E6F -Wait

    Installs PVWA with an existing certificate. Asks for the server account and the Vault Administrator
    password, then shows the progress.
    .EXAMPLE
    $lab = Read-Host -AsSecureString 'Lab password'
    Install-PASPVWA -ComputerName 192.0.2.21 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -LabPassword $lab

    Lab install with a self-signed certificate and one password. Returns the run id.
    .EXAMPLE
    Install-PASPVWA -ComputerName 192.0.2.21 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -PlanOnly

    Validates the input and returns the plan.
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

        [string]$PvwaUrl = '',

        [ValidatePattern('^[A-Fa-f0-9 ]{40,59}$')]
        [string]$CertificateThumbprint = '',

        [switch]$Wait,

        [switch]$PlanOnly
    )

    # Work on a copy: the caller's hashtable is not changed.
    $componentOptions = @{}
    foreach ($key in @($Options.Keys)) {
        $componentOptions[[string]$key] = $Options[$key]
    }
    if ($PvwaUrl) {
        $componentOptions['pvwaUrl'] = $PvwaUrl
    }
    if ($CertificateThumbprint) {
        $componentOptions['tlsCertificateThumbprint'] = ($CertificateThumbprint -replace '\s', '')
        # An existing certificate and a generated lab certificate exclude each other.
        $componentOptions['createLabCertificate'] = $false
    }
    if ($SecurityProfile -eq 'Secure' -and -not $componentOptions.ContainsKey('tlsCertificateThumbprint')) {
        throw 'The Secure profile needs the HTTPS certificate of PVWA: install it in LocalMachine\My on the server and pass -CertificateThumbprint. For a lab with a self-signed certificate use -SecurityProfile Lab.'
    }

    $install = @{
        Type               = 'PVWA'
        Cmdlet             = $PSCmdlet
        ComputerName       = $ComputerName
        VaultAddress       = $VaultAddress
        MediaPath          = $MediaPath
        Name               = $Name
        Credential         = $Credential
        VaultAdminPassword = $VaultAdminPassword
        LabPassword        = $LabPassword
        SecurityProfile    = $SecurityProfile
        Options            = $componentOptions
        Wait               = $Wait
        PlanOnly           = $PlanOnly
    }
    return (Invoke-PASComponentInstall @install)
}
