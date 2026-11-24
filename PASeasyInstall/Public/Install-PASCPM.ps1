function Install-PASCPM {
    <#
    .SYNOPSIS
    Installs the CyberArk Central Policy Manager (CPM) on a Windows server and registers it with an existing Vault.
    .DESCRIPTION
    Uploads the installer, installs the prerequisites and CPM, sets up the trust to PVWA, registers CPM
    with the Vault, applies the vendor hardening and verifies the result. Install PVWA first: the CPM
    registration needs the PVWA environment in the Vault.

    -MediaPath is the CPM installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the
    newest matching package is used.

    The command validates everything first and asks for confirmation. Only then it asks for what you
    did not pass: the Windows account of the server and the password of the Vault user Administrator.
    With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached
    controller process and keeps running when you close the console. The command returns the run id;
    follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

    Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER ComputerName
    IP address or DNS name of the server to install CPM on.
    .PARAMETER VaultAddress
    IP address or DNS name of the Vault the component registers with.
    .PARAMETER MediaPath
    The CPM installer ZIP, or a folder or CyberArk bundle ZIP that contains it.
    .PARAMETER Name
    Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it.
    Default: MyPAM.
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
    Only the Lab profile was tested; Secure is not qualified.
    .PARAMETER Options
    Further recipe options as a hashtable. They are stored in the configuration (components[].options)
    and win over the defaults. Supported for CPM: installDirectory, cpmUser, vaultPort,
    registrationMode (Clean or Upgrade), hardeningScript.
    .PARAMETER PvwaCertificateFile
    Public certificate file (.cer, no private key) that CPM must trust to reach PVWA over HTTPS
    (options pvwaTrustCertificateFile and pvwaTrustCertificateSHA256; the SHA-256 is computed here).
    Secure profile: a self-signed CA certificate. Lab profile: the self-signed PVWA certificate itself
    is accepted too, as the audited deviation CPM.AllowPinnedLeafTrust. Leave it out when the server
    already trusts the PVWA certificate.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PlanOnly
    Validates the input and returns the plan. Asks nothing and contacts no server.
    .EXAMPLE
    Install-PASCPM -ComputerName 192.0.2.22 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -Wait

    Installs CPM. Asks for the server account and the Vault Administrator password, then shows the progress.
    .EXAMPLE
    $lab = Read-Host -AsSecureString 'Lab password'
    Install-PASCPM -ComputerName 192.0.2.22 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -LabPassword $lab -PvwaCertificateFile C:\Lab\pvwa01.cer

    Lab install that pins the self-signed certificate of the lab PVWA. Returns the run id.
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

        [string]$PvwaCertificateFile = '',

        [switch]$Wait,

        [switch]$PlanOnly
    )

    # Work on a copy: the caller's hashtable is not changed.
    $componentOptions = @{}
    foreach ($key in @($Options.Keys)) {
        $componentOptions[[string]$key] = $Options[$key]
    }
    $securityOverride = @{}
    if ($PvwaCertificateFile) {
        if (-not (Test-Path -LiteralPath $PvwaCertificateFile -PathType Leaf)) {
            throw "Certificate file not found: $PvwaCertificateFile. Export the public certificate of PVWA (or of its CA) as a .cer file and pass that file."
        }
        $certificateFile = (Resolve-Path -LiteralPath $PvwaCertificateFile).ProviderPath
        $componentOptions['pvwaTrustCertificateFile'] = $certificateFile
        $componentOptions['pvwaTrustCertificateSHA256'] = (Get-FileHash -LiteralPath $certificateFile -Algorithm SHA256).Hash
        if ($SecurityProfile -eq 'Lab') {
            $securityOverride['CPM.AllowPinnedLeafTrust'] = $true
        }
    }

    $install = @{
        Type = 'CPM'
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
        SecurityOverride = $securityOverride
        Wait = $Wait
        PlanOnly = $PlanOnly
    }
    return (Invoke-PASComponentInstall @install)
}
