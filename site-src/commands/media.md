# Media commands

Find the CyberArk installers, the license and the recovery key in files, folders and ZIP files. Both commands
only read. Give `Get-PASMediaInventory` every folder and file where a part lies; they do not have to be in one
place.

The text of every command below is its own help (`Get-Help <command> -Full`).

| Command | What it does |
|---|---|
| [`Get-PASMediaInventory`](#get-pasmediainventory) | Finds CyberArk installer media in files, folders and ZIP bundles. Read-only. |
| [`Get-PASMediaSelection`](#get-pasmediaselection) | Picks one installer per component from the output of Get-PASMediaInventory. |

## Get-PASMediaInventory

Finds CyberArk installer media in files, folders and ZIP bundles. Read-only.

Recognises the installers by file name. Folders are searched four levels deep. A ZIP bundle (the CyberArk distribution ZIP that contains the installer ZIPs) is looked into through its directory only; nothing is extracted.

Returns one object per installer with Component, Name, Version, Variant, Path, Entry, Source and Container. Component is Vault, PACLI, DR, KeyGen, PVWA, CPM, PSM, PSMP, HTML5GW, PTA, License, RecoveryKey, Prerequisite, Unknown, or Missing for a path that does not exist. Entry is the path inside a bundle and empty for a plain file. Variant is the Linux distribution of a PSMP package.

| Parameter | Meaning |
|---|---|
| `-Path` | One or more files or folders to look at. |

```powershell
Get-PASMediaInventory -Path D:\CyberArkMedia | Format-Table Component, Version, Variant, Name
```

```powershell
'D:\CyberArkMedia', 'D:\Licenses\license.xml' | Get-PASMediaInventory | Where-Object Component -eq 'Unknown'
```

Shows the files that were not recognised.

## Get-PASMediaSelection

Picks one installer per component from the output of Get-PASMediaInventory.

Returns a hashtable @{ &lt;Component&gt; = &lt;inventory item&gt; } with one entry for each of Vault, PACLI, DR, KeyGen, PVWA, CPM, PSM, PSMP, HTML5GW, PTA, License and RecoveryKey that was found. It is the form the -Media parameter of New-PASLabConfiguration expects.

Per component the highest version wins. PSMP prefers the Ubuntu 24 package, then RHEL 9, then RHEL 8 (at install time the package that matches the server is used if it lies next to it). A plain PAM license is preferred to a Conjur license. At equal versions a plain file is preferred to the same installer inside a bundle, which would have to be extracted first.

To use another file than the one that was chosen, replace the entry before you pass the selection on: `$media.HTML5GW = <inventory item>`.

| Parameter | Meaning |
|---|---|
| `-Inventory` | Objects returned by Get-PASMediaInventory. |

```powershell
$media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path D:\CyberArkMedia)
```

```powershell
$media = Get-PASMediaInventory -Path D:\CyberArkMedia | Get-PASMediaSelection
$media.GetEnumerator() | ForEach-Object { '{0,-12} {1}' -f $_.Key, $_.Value.Name }
```

Shows which file was chosen for each component.
