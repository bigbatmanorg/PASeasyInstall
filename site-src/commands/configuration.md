# Lab configuration commands

A lab configuration describes a whole lab: the Vault, the component servers and the installer media. It is a hashtable in memory and a JSON file on disk. It never contains a password. These commands contact no server.

Generated from the command help.

| Command | Purpose |
|---|---|
| [`New-PASLabConfiguration`](#new-paslabconfiguration) | Composes the configuration of a lab: the Vault (new Primary, Primary and DR, or an existing Vault) and any number of PVWA, CPM, PSM and PSMP servers. Nothing is contacted or installed. |
| [`Test-PASLabConfiguration`](#test-paslabconfiguration) | Checks a lab configuration: structure, topology rules and, with -CheckMedia, the installer files. |
| [`Get-PASLabPlan`](#get-paslabplan) | Shows what a configuration would install: one item per component with its server, installer and order. |
| [`Export-PASLabConfiguration`](#export-paslabconfiguration) | Saves a lab configuration as a JSON file. The file never contains a password. |
| [`Import-PASLabConfiguration`](#import-paslabconfiguration) | Reads a lab configuration from a JSON file and returns it as an ordered hashtable. |
| [`Get-PASCredentialRequirement`](#get-pascredentialrequirement) | Lists the server accounts and passwords a lab configuration needs before it can be installed. |
| [`Get-PASStageCatalog`](#get-passtagecatalog) | Lists the installation stages of a component type, in the order they run. |

## New-PASLabConfiguration

Composes the configuration of a lab: the Vault (new Primary, Primary and DR, or an existing Vault) and any number of PVWA, CPM, PSM and PSMP servers. Nothing is contacted or installed.

Returns the configuration as an ordered hashtable. Check it with Test-PASLabConfiguration, look at
the result with Get-PASLabPlan, save it with Export-PASLabConfiguration and install it with
Install-PASLab. The configuration never contains a password.

The only thing this command may write is a copy of an installer that you selected inside a ZIP
bundle: it is extracted once into the media cache under the data folder of this controller.

| Parameter | Meaning |
|---|---|
| `-Environment` | Name of the environment (letters, digits, dot, dash, underscore; at most 64 characters). |
| `-VaultMode` | Primary: install a new Primary Vault. PrimaryDR: install a new Primary and a DR Vault. Existing: use a Vault that is already installed (-ExistingVaultAddress) and install components only. |
| `-Instances` | The component servers: @( @{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21'; Username = '' } ). Type is PVWA, CPM, PSM or PSMP (up to 4 of each). Name is the host name of the server; the component id in the configuration is its lower-case form. Instances with the same address share one server, named after the first instance. Username is optional. Linux instances may carry IdentityFile and KnownHostsFile; otherwise the key of this controller under &lt;data folder&gt;\ssh\&lt;environment&gt; is used (created and authorised on the first install). |
| `-ControllerAddress` | IPv4 address of this controller as the Vault servers see it. Needed for a new Vault. |
| `-PrimaryAddress` | Address of the server that becomes the Primary Vault (VaultMode Primary or PrimaryDR). |
| `-DRAddress` | Address of the server that becomes the DR Vault (VaultMode PrimaryDR). |
| `-ExistingVaultAddress` | Address of the existing Vault (VaultMode Existing). |
| `-Username` | Default Windows account name for the servers. Default: Administrator. |
| `-LinuxUsername` | Default Linux account name. Default: root (PSMP is installed as root). |
| `-Media` | The installers to use: @{ Vault = item; PACLI = item; DR = item; PVWA = item; CPM = item; PSM = item; PSMP = item; License = item; RecoveryKey = item }. An item is an object from Get-PASMediaInventory, @{ Path = ...; Entry = ... } or a plain file path. Get-PASMediaSelection builds this hashtable. |
| `-ExecutionMode` | Kept for compatibility. Only Sequential exists: components are installed one after the other. |
| `-PrimaryUsername` | Windows account name for the Primary Vault server, if it differs from -Username. |
| `-DRUsername` | Windows account name for the DR Vault server, if it differs from the Primary. |
| `-SecurityProfile` | Secure (default) or Lab. Lab adds the explicit, audited deviations a template-built lab needs: self-signed WinRM certificates, RDP to the Vault from the controller, a self-signed PVWA certificate that CPM pins. |
| `-AcceptEula` | Confirms that you read and accept the CyberArk end user license agreement of the PSMP installer. Required when the lab contains a PSMP. |
| `-InstallerName` | User name the CyberArk installers record ("who installs"). Default: what the vendor files contain ("Windows User"; "CyberArk Vault Image" for the Vault). Letters, digits, spaces and simple punctuation. |
| `-InstallerCompany` | Company name the CyberArk installers record. Default: what the vendor files contain ("My Company"; "CyberArk" for the Vault). |
| `-DataRoot` | Data folder of this controller (media cache, SSH keys). Default: %LOCALAPPDATA%\PASeasyInstall. |

```powershell
$media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path D:\CyberArkMedia)
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode PrimaryDR -PrimaryAddress 192.0.2.11 -DRAddress 192.0.2.12 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab `
    -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' }, @{ Type = 'CPM'; Name = 'CPM01'; Address = '192.0.2.21' })
Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab.json
```

A Primary and DR Vault plus PVWA and CPM on one shared server, saved as MyLab.json.

```powershell
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Existing -ExistingVaultAddress 192.0.2.11 -Media $media `
    -Instances @(@{ Type = 'PSM'; Name = 'PSM01'; Address = '192.0.2.23' })
Test-PASLabConfiguration -Configuration $cfg -CheckMedia
```

A PSM server for a Vault that already exists, then validated.

## Test-PASLabConfiguration

Checks a lab configuration: structure, topology rules and, with -CheckMedia, the installer files.

Returns one object with Valid (true or false), Issues (what must be corrected), Warnings and the
normalized Configuration. Lab security deviations appear as warnings that start with
"SECURITY DEVIATION". No server is contacted and nothing is changed.

To check the servers themselves (reachable, WinRM, disk space) use Test-PASPreflight.

| Parameter | Meaning |
|---|---|
| `-Path` | Configuration file (JSON). |
| `-Configuration` | Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration. |
| `-CheckMedia` | Also checks that the installer file of every component exists. |

```powershell
Test-PASLabConfiguration -Path .\MyLab.json -CheckMedia | Format-List Valid, Issues, Warnings
```

```powershell
if (-not (Test-PASLabConfiguration -Configuration $cfg).Valid) { 'Not ready yet' }
```

## Get-PASLabPlan

Shows what a configuration would install: one item per component with its server, installer and order.

A dry run. Returns the plan with Name, Items, DomainJoins and Warnings. Each item has Id, Name, Type,
Host, Address, Os, Media and DependsOn; the items are listed in installation order. No server is
contacted and nothing is changed.

With -ResolveMedia the exact installer files are resolved and hashed too (plan properties Media and
MediaDigest). That reads every installer once and can take a few minutes.

| Parameter | Meaning |
|---|---|
| `-Path` | Configuration file (JSON). |
| `-Configuration` | Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration. |
| `-ResolveMedia` | Also resolves and hashes the installer files that would be used. |

```powershell
(Get-PASLabPlan -Path .\MyLab.json).Items | Format-Table Id, Type, Address, Media, DependsOn
```

```powershell
Get-PASLabPlan -Configuration $cfg -ResolveMedia | Select-Object -ExpandProperty Media
```

## Export-PASLabConfiguration

Saves a lab configuration as a JSON file. The file never contains a password.

Validates the configuration first; a configuration with issues is not saved. An existing file is
only replaced with -Force. The file is written completely or not at all. Returns the full path.

Read the file again with Import-PASLabConfiguration, or pass it to Install-PASLab -Path.

| Parameter | Meaning |
|---|---|
| `-Configuration` | Configuration object, as returned by New-PASLabConfiguration. |
| `-Path` | File to write, e.g. .\MyLab.json. The folder is created when it does not exist. |
| `-Force` | Replaces an existing file. |

```powershell
Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab.json
```

```powershell
$cfg | Export-PASLabConfiguration -Path D:\Labs\MyLab.json -Force
```

## Import-PASLabConfiguration

Reads a lab configuration from a JSON file and returns it as an ordered hashtable.

The result can be changed in memory (for example $cfg.hosts.pvwa01.address = '192.0.2.31') and then
passed to Test-PASLabConfiguration, Get-PASLabPlan, Install-PASLab or Export-PASLabConfiguration.
The file is only read and parsed; use Test-PASLabConfiguration to validate it.

| Parameter | Meaning |
|---|---|
| `-Path` | Configuration file (JSON), as written by Export-PASLabConfiguration or the desktop wizard. |

```powershell
$cfg = Import-PASLabConfiguration -Path .\MyLab.json
```

```powershell
$cfg = Import-PASLabConfiguration .\MyLab.json
$cfg.name = 'MyLab2'
Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab2.json
```

Copies a configuration under a new environment name.

## Get-PASCredentialRequirement

Lists the server accounts and passwords a lab configuration needs before it can be installed.

Returns one object per requirement with:
Kind    Credential (an account with its password) or Secret (a password only)
Key     the key to use in -CredentialMap or -SecretMap of Install-PASLab and Resume-PASRun
HostId  the server id in the configuration (empty for secrets)
User    the account name the configuration expects
Os      Windows or Linux
Label   a description to show when asking for it

Secrets are VaultAdmin (Vault Administrator password), VaultMaster and DRPassword (new Vault and
DR), ADSafeMode (new domain) and DomainJoinPassword. A Linux server is listed when the controller
key still has to be authorised there with the password of the account.
Nothing is contacted and nothing is asked.

| Parameter | Meaning |
|---|---|
| `-Path` | Configuration file (JSON). |
| `-Configuration` | Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration. |

```powershell
Get-PASCredentialRequirement -Path .\MyLab.json | Format-Table Kind, Key, User, Label
```

```powershell
$creds = @{}
Get-PASCredentialRequirement -Configuration $cfg | Where-Object Kind -eq 'Credential' | ForEach-Object {
    $creds[$_.Key] = Get-Credential -UserName $_.User -Message $_.Label
}
```

Collects the server accounts into a hashtable for Install-PASLab -CredentialMap.

## Get-PASStageCatalog

Lists the installation stages of a component type, in the order they run.

Returns one object per stage with Component, Stage and Order. The stage names are the step ids you
see as Stage in Get-PASRunEvent and that Resume-PASRun -RetryStep accepts.

The list is read from what the installer really runs: the Vault and DR workflow files of the
module, and the step list the workflow generator uses for PVWA, CPM, PSM, PSMP and AD.
Not listed, because they depend on the run: the extra passes and restarts of a PSM stage
(&lt;stage&gt;-pass2, &lt;stage&gt;-reboot), the upload of a certificate pinned by CPM (pvwa-trust-certificate)
and the steps the controller performs itself (ssh-bootstrap, media-select).

| Parameter | Meaning |
|---|---|
| `-Component` | Vault, DR, PVWA, CPM, PSM, PSMP or AD. Default: all of them. |

```powershell
Get-PASStageCatalog -Component Vault | Format-Table Order, Stage
```

```powershell
'PVWA', 'CPM' | Get-PASStageCatalog | Format-Table Component, Order, Stage
```
