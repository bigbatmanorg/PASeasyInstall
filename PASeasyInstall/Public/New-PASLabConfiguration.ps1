function New-PASLabConfiguration {
    <#
    .SYNOPSIS
    Composes the configuration of a lab: the Vault (new Primary, Primary and DR, or an existing Vault)
    and up to 4 each of PVWA, CPM, PSM, PSMP, HTML5 Gateway and one PTA. Nothing is contacted or installed.
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
    Type is PVWA, CPM, PSM, PSMP, HTML5GW or PTA (up to 4 of each, one PTA). PTA needs a RHEL-family server with
    8 GB, a PVWA in the same lab and a PSMP package in the media; its instance may carry VaultTimezone, the
    time zone of the Vault server as a tz database name (default UTC). HTML5GW is the PSM HTML5 Gateway: a
    container on a Linux server (Docker on Ubuntu, Podman on the RHEL family) that may share the server
    of a PSMP; it needs a PVWA in the same lab and the PACLI package in the media.
    Name is the host name of the server; the
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
    PSMP = item; HTML5GW = item; PTA = item; License = item; RecoveryKey = item }. Only the ones the lab
    needs. An item is an object from Get-PASMediaInventory,
    @{ Path = ...; Entry = ... } or a plain file path. Get-PASMediaSelection builds this hashtable.
    .PARAMETER ExecutionMode
    Parallel (default): the servers are installed at the same time; the steps that sign in to the Vault wait
    until the Primary Vault is installed and then run one at a time (PVWA, CPM, PSM and PSMP, PTA last).
    Sequential: one component after the other.
    .PARAMETER PrimaryUsername
    Windows account name for the Primary Vault server, if it differs from -Username.
    .PARAMETER DRUsername
    Windows account name for the DR Vault server, if it differs from the Primary.
    .PARAMETER SecurityProfile
    Secure (default) or Lab. Lab adds the explicit, audited deviations a template-built lab needs:
    self-signed WinRM certificates, RDP to the Vault from the controller, a self-signed PVWA
    certificate that CPM pins.
    Only the Lab profile was tested; Secure is not qualified.
    .PARAMETER AcceptEula
    Confirms that you read and accept the CyberArk end user license agreement of the PSMP, HTML5 Gateway and PTA installers.
    Required when the lab contains a PSMP, an HTML5 Gateway or PTA.
    .PARAMETER DomainMode
    None (default): the servers stay in their workgroup. New: a new Active Directory forest is created on the
    server at -DomainControllerAddress. Existing: an existing domain is used. With New and Existing the
    Windows servers of PVWA, CPM and PSM are joined to the domain before they are installed (they restart
    once). Vault servers are never joined. With New, the CyberArk hardening GPOs of the vendor packages are
    imported into the new domain and applied to the joined servers after the installation. An existing
    domain is not changed: import those GPOs there yourself.
    .PARAMETER DomainName
    DNS name of the domain, for example pam.lab.
    .PARAMETER DomainControllerAddress
    DomainMode New: IPv4 address of the Windows server that becomes the domain controller (it must have a
    static address and nothing else is installed on it). DomainMode Existing: IPv4 address of a DNS server
    of the domain, usually a domain controller.
    .PARAMETER DomainUsername
    Account name without the domain, default Administrator. DomainMode New: the local administrator of the
    new domain controller, who becomes the administrator of the domain. DomainMode Existing: a domain
    account that may join computers.
    .PARAMETER InstallerName
    User name the CyberArk installers record ("who installs"). Default: what the vendor files contain
    ("Windows User"; "CyberArk Vault Image" for the Vault). Letters, digits, spaces and simple punctuation.
    .PARAMETER InstallerCompany
    Company name the CyberArk installers record. Default: what the vendor files contain ("My Company";
    "CyberArk" for the Vault).
    .PARAMETER SkipHardening
    Installs and registers the components but does not run the vendor hardening on any server: not on the
    Vault, not on PVWA, CPM, PSM or PSMP, and no hardening GPOs in a new domain. For tests that need servers
    without the security settings. Only with -SecurityProfile Lab.
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

        [ValidateSet('Parallel', 'Sequential')]
        [string]$ExecutionMode = 'Parallel',

        [AllowEmptyString()]
        [string]$PrimaryUsername = '',

        [AllowEmptyString()]
        [string]$DRUsername = '',

        [ValidateSet('Secure', 'Lab')]
        [string]$SecurityProfile = 'Secure',

        [switch]$AcceptEula,

        [ValidateSet('None', 'New', 'Existing')]
        [string]$DomainMode = 'None',

        [AllowEmptyString()]
        [string]$DomainName = '',

        [AllowEmptyString()]
        [string]$DomainControllerAddress = '',

        [AllowEmptyString()]
        [string]$DomainUsername = '',

        [AllowEmptyString()]
        [string]$InstallerName = '',

        [AllowEmptyString()]
        [string]$InstallerCompany = '',

        [switch]$SkipHardening,

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
