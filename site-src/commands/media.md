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

```powershell
PS> Get-PASMediaInventory -Path C:\CyberArk\media | Format-Table Component,Version,Variant,Name

Component    Version Variant  Name
---------    ------- -------  ----
Vault        15.0             Server-Rls-v15.0.zip
PACLI        15.0             PACLI-Rls-v15.0.zip
DR           15.0             Disaster Recovery-Rls-v15.0.zip
PVWA         15.0             Password Vault Web Access-Rls-v15.0.zip
CPM          15.0             Central Policy Manager-Rls-v15.0.zip
PSM          15.0             Privileged Session Manager-Rls-v15.0.zip
PSMP         15.0    Ubuntu24 PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.0.zip
PSMP         15.0    RHEL9    PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.0.zip
License                       license.xml
RecoveryKey                   recpub.key
...
```

<!-- TODO(parent): replace with real captured output from the release build (columns/rows above are illustrative). -->

## Get-PASMediaSelection

Picks one item per component: the highest version; for PSMP, Ubuntu 24 first, then RHEL 9. At equal version, a plain
file beats the same installer inside a bundle.

```powershell
$media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path C:\CyberArk\media)
$media.PSMP.Name    # PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.0.zip
```

Pass the result as `-Media` to [`New-PASDeploymentConfiguration`](new-deploymentconfiguration.md). You can replace any
entry with your own choice: `$media.PSMP = <item>`.
