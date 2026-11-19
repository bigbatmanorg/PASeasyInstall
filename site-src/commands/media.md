# Get-PASMediaInventory / Get-PASMediaSelection

## Get-PASMediaInventory

Classifies installer media in files, folders (recursively, up to four levels) and ZIP bundles. It is read-only:
bundles are listed without being extracted.

```powershell
Get-PASMediaInventory -Path <string[]>
```

Each item has `Component` (`Vault`, `PACLI`, `DR`, `KeyGen`, `PVWA`, `CPM`, `PSM`, `PSMP`, `License`,
`RecoveryKey`, `Prerequisite` or `Unknown`), `Name`, `Version`, `Variant` (for example the PSMP distribution), `Path`,
`Entry` (the path inside a bundle) and `Source`.

Captured with 1.0 against the PAM 15.2 bundle (`Privileged Access Manager Self-Hosted-15.2.zip`, not extracted)
plus the license, recovery key and VC++ runtimes in the same folder:

```powershell
PS> Get-PASMediaInventory -Path C:\Media152 | Format-Table Component,Version,Variant,Name

Component    Version    Variant   Name
---------    -------    -------   ----
License                           license.xml
PVWA         15.2.3               Password Vault Web Access-Rls-v15.2.3.zip
PSMP         15.2.1     Ubuntu22  PrivilegedSessionManagerSSHProxy-Ubuntu22-Intel64-Rls-v15.2.1.zip
CPM          15.2.3               Central Policy Manager-Rls-v15.2.3.zip
Vault        15.2.5.158           Server-Rls-v15.2.5.158.zip
KeyGen       15.2                 PA Key Gen-Rls-v15.2.zip
PSM          15.2.2.45            Privileged Session Manager-Rls-v15.2.2.45.zip
PSMP         15.2.1     SLES15    PrivilegedSessionManagerSSHProxy-SLES15-Intel64-Rls-v15.2.1.zip
DR           15.2.5.158           Disaster Recovery-Rls-v15.2.5.158.zip
PSMP         15.2.1     RHELinux8 PrivilegedSessionManagerSSHProxy-RHELinux8-Intel64-Rls-v15.2.1.zip
PACLI        15.2.5.158           PACLI-Rls-v15.2.5.158.zip
PSMP         15.2.1     Ubuntu24  PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip
PSMP         15.2.1     RHELinux9 PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip
RecoveryKey                       recpub.key
Prerequisite                      VC_redist.x64.exe
Prerequisite                      VC_redist.x86.exe
```

## Get-PASMediaSelection

Picks one item per component: the highest version; for PSMP, Ubuntu 24 first, then RHEL 9. At equal version, a plain
file beats the same installer inside a bundle. The PSMP choice is only the starting point: each PSMP server gets the
package for its own distribution from the same bundle or folder (see [PSMP](../components/psmp.md)).

```powershell
$media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path C:\CyberArk\media)
$media.PSMP.Name    # PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.0.zip
```

Pass the result as `-Media` to [`New-PASDeploymentConfiguration`](new-deploymentconfiguration.md). You can replace any
entry with your own choice: `$media.PSMP = <item>`.
