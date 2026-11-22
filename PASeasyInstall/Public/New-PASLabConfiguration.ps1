function New-PASLabConfiguration {
    <#
    .SYNOPSIS
    Composes the configuration of a lab: the Vault (new Primary, Primary and DR, or an existing Vault)
    and any number of PVWA, CPM, PSM and PSMP servers. Nothing is contacted or installed.
    .DESCRIPTION
    Returns the configuration as an ordered hashtable. Check it with Test-PASLabConfiguration, look at
    the result with Get-PASLabPlan, save it with Export-PASLabConfiguration and install it with
    Install-PASLab. The configuration never contains a password.

    The only thing this command may write is a copy of an installer that you selected inside a ZIP
    bundle: it is extracted once into the media cache under the data folder of this controller.
    .PARAMETER Environment
    Name of the environment (letters, digits, dot, dash, underscore; at most 64 characters).
    .PARAMETER VaultMode
    Primary: install a new Primary Vault. PrimaryDR: install a new Primary and a DR Vault.
    Existing: use a Vault that is already installed (-ExistingVaultAddress) and install components only.
    .PARAMETER Instances
    The component servers: @( @{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21'; Username = '' } ).
    Type is PVWA, CPM, PSM or PSMP (up to 4 of each). Name is the host name of the server; the
    component id in the configuration is its lower-case form. Instances with the same address share
    one server, named after the first instance. Username is optional.
    Linux instances may carry IdentityFile and KnownHostsFile; otherwise the key of this controller
    under <data folder>\ssh\<environment> is used (created and authorised on the first install).
    .PARAMETER ControllerAddress
    IPv4 address of this controller as the Vault servers see it. Needed for a new Vault.
    .PARAMETER PrimaryAddress
    Address of the server that becomes the Primary Vault (VaultMode Primary or PrimaryDR).
    .PARAMETER DRAddress
    Address of the server that becomes the DR Vault (VaultMode PrimaryDR).
    .PARAMETER ExistingVaultAddress
    Address of the existing Vault (VaultMode Existing).
    .PARAMETER Username
    Default Windows account name for the servers. Default: Administrator.
    .PARAMETER LinuxUsername
    Default Linux account name. Default: root (PSMP is installed as root).
    .PARAMETER Media
    The installers to use: @{ Vault = item; PACLI = item; DR = item; PVWA = item; CPM = item; PSM = item;
    PSMP = item; License = item; RecoveryKey = item }. An item is an object from Get-PASMediaInventory,
    @{ Path = ...; Entry = ... } or a plain file path. Get-PASMediaSelection builds this hashtable.
    .PARAMETER ExecutionMode
    Kept for compatibility. Only Sequential exists: components are installed one after the other.
    .PARAMETER PrimaryUsername
    Windows account name for the Primary Vault server, if it differs from -Username.
    .PARAMETER DRUsername
    Windows account name for the DR Vault server, if it differs from the Primary.
    .PARAMETER SecurityProfile
    Secure (default) or Lab. Lab adds the explicit, audited deviations a template-built lab needs:
    self-signed WinRM certificates, RDP to the Vault from the controller, a self-signed PVWA
    certificate that CPM pins.
    .PARAMETER AcceptEula
    Confirms that you read and accept the CyberArk end user license agreement of the PSMP installer.
    Required when the lab contains a PSMP.
    .PARAMETER InstallerName
    User name the CyberArk installers record ("who installs"). Default: what the vendor files contain
    ("Windows User"; "CyberArk Vault Image" for the Vault). Letters, digits, spaces and simple punctuation.
    .PARAMETER InstallerCompany
    Company name the CyberArk installers record. Default: what the vendor files contain ("My Company";
    "CyberArk" for the Vault).
    .PARAMETER DataRoot
    Data folder of this controller (media cache, SSH keys). Default: %LOCALAPPDATA%\PASeasyInstall.
    .EXAMPLE
    $media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path D:\CyberArkMedia)
    $cfg = New-PASLabConfiguration -Environment MyLab -VaultMode PrimaryDR -PrimaryAddress 192.0.2.11 -DRAddress 192.0.2.12 `
        -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab `
        -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' }, @{ Type = 'CPM'; Name = 'CPM01'; Address = '192.0.2.21' })
    Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab.json

    A Primary and DR Vault plus PVWA and CPM on one shared server, saved as MyLab.json.
    .EXAMPLE
    $cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Existing -ExistingVaultAddress 192.0.2.11 -Media $media `
        -Instances @(@{ Type = 'PSM'; Name = 'PSM01'; Address = '192.0.2.23' })
    Test-PASLabConfiguration -Configuration $cfg -CheckMedia

    A PSM server for a Vault that already exists, then validated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Environment,

        [Parameter(Mandatory)]
        [ValidateSet('Primary', 'PrimaryDR', 'Existing')]
        [string]$VaultMode,

        [object[]]$Instances = @(),

        [AllowEmptyString()]
        [string]$ControllerAddress = '',

        [AllowEmptyString()]
        [string]$PrimaryAddress = '',

        [AllowEmptyString()]
        [string]$DRAddress = '',

        [AllowEmptyString()]
        [string]$ExistingVaultAddress = '',

        [string]$Username = 'Administrator',

        [string]$LinuxUsername = 'root',

        [hashtable]$Media = @{},

        [ValidateSet('Sequential')]
        [string]$ExecutionMode = 'Sequential',

        [AllowEmptyString()]
        [string]$PrimaryUsername = '',

        [AllowEmptyString()]
        [string]$DRUsername = '',

        [ValidateSet('Secure', 'Lab')]
        [string]$SecurityProfile = 'Secure',

        [switch]$AcceptEula,

        [AllowEmptyString()]
        [string]$InstallerName = '',

        [AllowEmptyString()]
        [string]$InstallerCompany = '',

        [string]$DataRoot = ''
    )

    # The composer itself is the private function New-PASDeploymentConfiguration (Private\Config\Composition.ps1).
    $arguments = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        $arguments[$key] = $PSBoundParameters[$key]
    }
    if (-not $DataRoot) {
        $arguments.Remove('DataRoot')
    }
    return (New-PASDeploymentConfiguration @arguments)
}
