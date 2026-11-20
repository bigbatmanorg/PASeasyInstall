function Install-PASVault {
    <#
    .SYNOPSIS
    Installs a CyberArk Primary Vault, or a Primary and DR Vault pair, on servers you provide.
    .DESCRIPTION
    Installs and hardens the Primary Vault on -ComputerName. With -DRComputerName a DR Vault is installed
    on a second server in the same run and replication is verified. A DR Vault can only be installed
    together with a new Primary Vault: adding DR to a Vault that already exists is not supported.

    The installer media (Vault server, PACLI, for DR the Disaster Recovery package, license, recovery
    public key, VC++ runtimes) is looked up in -MediaPath by file name. Get-PASMediaInventory shows what
    is recognised there.

    The command validates everything first and asks for confirmation. Only then it asks for what you
    did not pass: the Windows account of each server and the Vault passwords. With -WhatIf nothing is
    asked and nothing is contacted. The installation runs in a detached controller process and keeps
    running when you close the console. The command returns the run id; follow the run with Wait-PASRun
    or Get-PASRun, or use -Wait.

    Passwords are kept in memory only. They are never written to a file, a log or a command line.
    PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER ComputerName
    IP address or DNS name of the server that becomes the Primary Vault. A dedicated Windows server
    that is not a domain member.
    .PARAMETER DRComputerName
    IP address or DNS name of the server that becomes the DR Vault. Leave it out for a Primary only.
    .PARAMETER MediaPath
    Folder that holds the CyberArk Vault installer media.
    .PARAMETER ControllerAddress
    IPv4 address of this controller as the Vault servers see it. The hardened Vault firewall is opened
    for it. Default: the local address that routes to -ComputerName.
    .PARAMETER Name
    Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it.
    .PARAMETER Credential
    Local administrator of the Primary Vault server. Asked for when missing. The default account name
    is Administrator; to use another account pass it here.
    .PARAMETER DRCredential
    Local administrator of the DR server. The account name must be the same as on the Primary; the
    password may differ. Asked for when missing.
    .PARAMETER VaultAdminPassword
    Password to set for the Vault user Administrator. Printable ASCII without double quotes.
    .PARAMETER MasterPassword
    Password to set for the Vault user Master. Printable ASCII without double quotes.
    .PARAMETER DRPassword
    Password to set for the Vault DR user. Only with -DRComputerName.
    .PARAMETER LabPassword
    One password for every server account and every Vault password. Only with -SecurityProfile Lab.
    .PARAMETER SecurityProfile
    Secure (default): WinRM over HTTPS with a trusted certificate, no RDP to the hardened Vault.
    Lab: accepts self-signed WinRM certificates and keeps RDP from the controller to the Vault open.
    Every lab deviation is listed as a warning.
    .PARAMETER LicenseFile
    Vault license (.xml). Default: the license found in -MediaPath.
    .PARAMETER RecoveryPublicKey
    Recovery public key file (recpub.key), or the folder that contains it. Default: the key found in
    -MediaPath.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PlanOnly
    Validates the input and returns the plan. Asks nothing and contacts no server.
    .EXAMPLE
    Install-PASVault -ComputerName 192.0.2.11 -MediaPath D:\CyberArkMedia -Wait

    Installs a Primary Vault with the Secure profile. Asks for the server account and the two Vault
    passwords, then shows the progress.
    .EXAMPLE
    $lab = Read-Host -AsSecureString 'Lab password'
    Install-PASVault -ComputerName 192.0.2.11 -DRComputerName 192.0.2.12 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -LabPassword $lab

    Installs a Primary and DR pair in a lab with one password for everything. Returns the run id.
    .EXAMPLE
    Install-PASVault -ComputerName 192.0.2.11 -MediaPath D:\CyberArkMedia -WhatIf

    Validates the input and says what would be installed. Nothing is asked or contacted.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ComputerName,

        [string]$DRComputerName = '',

        [Parameter(Mandatory)]
        [string]$MediaPath,

        [string]$ControllerAddress = '',

        [string]$Name = 'MyPAM',

        [pscredential]$Credential,

        [pscredential]$DRCredential,

        [securestring]$VaultAdminPassword,

        [securestring]$MasterPassword,

        [securestring]$DRPassword,

        [securestring]$LabPassword,

        [ValidateSet('Secure', 'Lab')]
        [string]$SecurityProfile = 'Secure',

        [string]$LicenseFile = '',

        [string]$RecoveryPublicKey = '',

        [switch]$Wait,

        [switch]$PlanOnly
    )

    $withDR = [bool]$DRComputerName.Trim()
    if (-not $withDR -and ($DRCredential -or $DRPassword)) {
        throw '-DRCredential and -DRPassword need -DRComputerName (the server that becomes the DR Vault).'
    }
    if (-not (Test-Path -LiteralPath $MediaPath -PathType Container)) {
        throw "Media folder not found: $MediaPath. -MediaPath is the folder that holds the CyberArk Vault installer media."
    }
    $mediaFolder = (Resolve-Path -LiteralPath $MediaPath).ProviderPath

    # Primary and DR use the same local account name (their passwords may differ).
    $user = Get-PASAccountName -Credential $Credential -Default 'Administrator'
    $drUser = Get-PASAccountName -Credential $DRCredential -Default $user
    if ($withDR -and $drUser -ne $user) {
        throw "Primary and DR must use the same local account name (found '$user' and '$drUser'). Use the same account on both servers; the passwords may differ."
    }
    if (-not $ControllerAddress) {
        $ControllerAddress = Get-PASControllerAddressFor -ComputerName $ComputerName.Trim()
    }

    # Installer media: one package per kind from the folder; explicit files win.
    $media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path $mediaFolder)
    if ($LicenseFile) {
        if (-not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) {
            throw "License file not found: $LicenseFile"
        }
        $media['License'] = (Resolve-Path -LiteralPath $LicenseFile).ProviderPath
    }
    if ($RecoveryPublicKey) {
        $keyFile = $RecoveryPublicKey
        if (Test-Path -LiteralPath $keyFile -PathType Container) {
            $keyFile = Join-Path $keyFile 'recpub.key'
        }
        if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
            throw "Recovery public key not found: $keyFile. Pass the recpub.key file or the folder that contains it. Never pass the private recovery key."
        }
        $media['RecoveryKey'] = (Resolve-Path -LiteralPath $keyFile).ProviderPath
    }

    $vaultMode = 'Primary'
    if ($withDR) {
        $vaultMode = 'PrimaryDR'
    }
    $configuration = New-PASComposedConfiguration @{
        Environment       = $Name
        VaultMode         = $vaultMode
        PrimaryAddress    = $ComputerName.Trim()
        DRAddress         = $DRComputerName.Trim()
        ControllerAddress = $ControllerAddress.Trim()
        Username          = $user
        Media             = $media
        SecurityProfile   = $SecurityProfile
    }
    if (-not $configuration.mediaRoot) {
        # No Vault package was recognised by name: let the Vault media check search the folder itself.
        $configuration.mediaRoot = $mediaFolder
    }

    # Server ids of the composed configuration: vault01 (Primary) and dr01 (DR).
    $credentialMap = @{}
    if ($Credential) {
        $credentialMap['vault01'] = $Credential
    }
    if ($DRCredential) {
        $credentialMap['dr01'] = $DRCredential
    }
    $secretMap = @{}
    if ($VaultAdminPassword) {
        $secretMap['VaultAdmin'] = $VaultAdminPassword
    }
    if ($MasterPassword) {
        $secretMap['VaultMaster'] = $MasterPassword
    }
    if ($DRPassword) {
        $secretMap['DRPassword'] = $DRPassword
    }

    $action = "Install the CyberArk Primary Vault (environment '$Name')"
    $target = $ComputerName.Trim()
    if ($withDR) {
        $action = "Install the CyberArk Primary Vault and the DR Vault (environment '$Name')"
        $target = $ComputerName.Trim() + ' and ' + $DRComputerName.Trim()
    }
    $install = @{
        Configuration = $configuration
        Cmdlet        = $PSCmdlet
        Action        = $action
        Target        = $target
        CredentialMap = $credentialMap
        SecretMap     = $secretMap
        LabPassword   = $LabPassword
        PlanOnly      = $PlanOnly
        Wait          = $Wait
    }
    return (Invoke-PASInstallCommand @install)
}
