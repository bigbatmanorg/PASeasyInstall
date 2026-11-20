# Commands

PASeasyInstall is one PowerShell module with 25 commands. Everything the desktop does is one of them. Commands never
print passwords. Credentials are passed as `PSCredential` and `SecureString` objects only, or asked for.

```powershell
Install-Module PASeasyInstall -Scope CurrentUser
Get-Command -Module PASeasyInstall
Get-Help Install-PASVault -Full
Get-Help about_PASeasyInstall
```

| Command | Purpose |
|---|---|
| [`Install-PASVault`](install.md#install-pasvault) | Install a Primary Vault, or a Primary and DR Vault pair |
| [`Install-PASPVWA`](install.md#install-paspvwa) | Install PVWA and register it with an existing Vault |
| [`Install-PASCPM`](install.md#install-pascpm) | Install CPM and register it with an existing Vault |
| [`Install-PASPSM`](install.md#install-paspsm) | Install PSM and register it with an existing Vault |
| [`Install-PASPSMP`](install.md#install-paspsmp) | Install PSM for SSH on a Linux server |
| [`Install-PASDomainController`](install.md#install-pasdomaincontroller) | Create a new Active Directory forest for a lab |
| [`Install-PASLab`](install.md#install-paslab) | Install everything a lab configuration describes |
| [`New-PASLabConfiguration`](configuration.md#new-paslabconfiguration) | Compose the configuration of a lab |
| [`Test-PASLabConfiguration`](configuration.md#test-paslabconfiguration) | Check a configuration (optionally with the installer files) |
| [`Get-PASLabPlan`](configuration.md#get-paslabplan) | Show what a configuration would install, in which order |
| [`Export-PASLabConfiguration`](configuration.md#export-paslabconfiguration) | Save a configuration as JSON (never a password) |
| [`Import-PASLabConfiguration`](configuration.md#import-paslabconfiguration) | Read a configuration from JSON |
| [`Get-PASCredentialRequirement`](configuration.md#get-pascredentialrequirement) | List the accounts and passwords a configuration needs |
| [`Get-PASStageCatalog`](configuration.md#get-passtagecatalog) | List the stages of a component type |
| [`Get-PASMediaInventory`](media.md#get-pasmediainventory) | Find installers, license and keys in files, folders and bundle ZIPs |
| [`Get-PASMediaSelection`](media.md#get-pasmediaselection) | Pick one installer per component |
| [`Get-PASRun`](runs.md#get-pasrun) | List the runs, or show one run with its components and events |
| [`Get-PASRunEvent`](runs.md#get-pasrunevent) | The progress events of a run (`-Failed`: only failures) |
| [`Wait-PASRun`](runs.md#wait-pasrun) | Follow a run until it ends |
| [`Resume-PASRun`](runs.md#resume-pasrun) | Continue a run that stopped (`-RetryStep`: repeat a failed step) |
| [`Stop-PASRun`](runs.md#stop-pasrun) | Give a run up and release its locks on the servers |
| [`Test-PASPreflight`](checks.md#test-paspreflight) | Check that the controller and the servers are ready |
| [`Test-PASHealth`](checks.md#test-pashealth) | Check that an installed lab works |
| [`Export-PASDiagnostics`](checks.md#export-pasdiagnostics) | Write a sanitized ZIP of one run |
| [`Get-PASRunLog`](checks.md#get-pasrunlog) | Read the run journal or a CyberArk log on a lab server |

The desktop is a separate module with one command: [`Start-PASeasyInstall`](start-paseasyinstall.md).

## One component

```powershell
Install-PASVault -ComputerName 10.10.0.11 -MediaPath C:\CyberArk\media -Wait
Install-PASPVWA  -ComputerName 10.10.0.21 -VaultAddress 10.10.0.11 -MediaPath C:\CyberArk\media -SecurityProfile Lab -Wait
```

## A complete lab from a script

```powershell
$inventory = Get-PASMediaInventory -Path C:\CyberArk\media
$media     = Get-PASMediaSelection -Inventory $inventory

$instances = @(
  @{ Type = 'PVWA'; Name = 'PAS-PVWA'; Address = '10.10.0.21' }
  @{ Type = 'CPM';  Name = 'PAS-CPM';  Address = '10.10.0.22' }
  @{ Type = 'PSM';  Name = 'PAS-PSM';  Address = '10.10.0.23' }
  @{ Type = 'PSMP'; Name = 'PAS-PSMP'; Address = '10.10.0.31' }
)
$cfg = New-PASLabConfiguration -Environment Lab01 -VaultMode PrimaryDR `
        -PrimaryAddress 10.10.0.11 -DRAddress 10.10.0.12 -ControllerAddress 10.10.0.10 `
        -Instances $instances -Media $media -SecurityProfile Lab -AcceptEula

Test-PASLabConfiguration -Configuration $cfg -CheckMedia
Get-PASLabPlan -Configuration $cfg
Export-PASLabConfiguration -Configuration $cfg -Path C:\Labs\Lab01.json

Test-PASPreflight -Path C:\Labs\Lab01.json
Install-PASLab -Path C:\Labs\Lab01.json -Wait   # asks for the passwords, follows the progress
```

## Old names (1.0)

The 1.0 commands are gone. The mapping is in the [release notes](../release-notes.md#command-mapping-10-to-20).
