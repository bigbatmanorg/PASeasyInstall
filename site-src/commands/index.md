# Commands

PASeasyInstall is one PowerShell module with 26 commands. Everything [the window](../gui/index.md) does is one
of them. No command prints a password: accounts are passed as `PSCredential`, passwords as `SecureString`, or
they are asked for.

```powershell
Get-Command -Module PASeasyInstall
Get-Help Install-PASLab -Full          # every command has help with examples
Get-Help about_PASeasyInstall          # an overview
```

## A lab in five commands

```powershell
$media = Get-PASMediaInventory -Path D:\CyberArk, D:\Licenses | Get-PASMediaSelection
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Primary -PrimaryAddress 192.0.2.11 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab `
    -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' },
                 @{ Type = 'CPM';  Name = 'CPM01';  Address = '192.0.2.21' })
Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab.json
Install-PASLab -Path .\MyLab.json -Wait
Test-PASHealth -Path .\MyLab.json -VaultCredential (Get-Credential Administrator)
```

## Install

| Command | What it does |
|---|---|
| [`Install-PASLab`](install.md#install-paslab) | Installs everything a lab configuration describes, the servers at the same time |
| [`Install-PASVault`](install.md#install-pasvault) | Installs a Primary Vault, or a Primary and DR Vault pair |
| [`Install-PASPVWA`](install.md#install-paspvwa) | Installs PVWA and registers it with an existing Vault |
| [`Install-PASCPM`](install.md#install-pascpm) | Installs CPM and registers it with an existing Vault |
| [`Install-PASPSM`](install.md#install-paspsm) | Installs PSM and registers it with an existing Vault |
| [`Install-PASPSMP`](install.md#install-paspsmp) | Installs PSM for SSH on a Linux server and registers it with an existing Vault |
| [`Install-PASDomainController`](install.md#install-pasdomaincontroller) | Creates a new Active Directory forest for a lab |

The HTML5 Gateway, PTA, domain joins and the hardening GPOs are installed as part of a lab
(`New-PASLabConfiguration`, then `Install-PASLab`).

## Lab configuration

| Command | What it does |
|---|---|
| [`New-PASLabConfiguration`](configuration.md#new-paslabconfiguration) | Composes the configuration of a lab. Contacts nothing |
| [`Test-PASLabConfiguration`](configuration.md#test-paslabconfiguration) | Checks a configuration, with `-CheckMedia` also the installer files |
| [`Get-PASLabPlan`](configuration.md#get-paslabplan) | Shows what a configuration would install |
| [`Export-PASLabConfiguration`](configuration.md#export-paslabconfiguration) | Saves a configuration as a JSON file (never a password) |
| [`Import-PASLabConfiguration`](configuration.md#import-paslabconfiguration) | Reads a configuration from a JSON file |
| [`Get-PASCredentialRequirement`](configuration.md#get-pascredentialrequirement) | Lists the accounts and passwords a configuration needs |
| [`Get-PASStageCatalog`](configuration.md#get-passtagecatalog) | Lists the installation steps of a component type, in order |

## Media

| Command | What it does |
|---|---|
| [`Get-PASMediaInventory`](media.md#get-pasmediainventory) | Finds the installers, the license and the key in folders, files and ZIP files |
| [`Get-PASMediaSelection`](media.md#get-pasmediaselection) | Picks one installer per component |

## Runs

| Command | What it does |
|---|---|
| [`Get-PASRun`](runs.md#get-pasrun) | Lists the runs of this controller, or shows one run |
| [`Get-PASRunEvent`](runs.md#get-pasrunevent) | The progress events of a run; `-Failed` shows what failed |
| [`Wait-PASRun`](runs.md#wait-pasrun) | Follows a run until it ends |
| [`Resume-PASRun`](runs.md#resume-pasrun) | Continues a run that stopped; `-RetryStep` runs a failed step again |
| [`Stop-PASRun`](runs.md#stop-pasrun) | Gives a run up and releases its locks on the servers |

## Checks and diagnostics

| Command | What it does |
|---|---|
| [`Test-PASPreflight`](checks.md#test-paspreflight) | Checks, without changing anything, that the servers are ready |
| [`Test-PASHealth`](checks.md#test-pashealth) | Checks an installed lab: PVWA sign-in, connected components, DR replication |
| [`Export-PASDiagnostics`](checks.md#export-pasdiagnostics) | Writes a ZIP of one run without passwords |
| [`Get-PASRunLog`](checks.md#get-pasrunlog) | Reads the journal of a run, or the end of a CyberArk log on a server |

## The window

| Command | What it does |
|---|---|
| [`Start-PASeasyInstall`](start-paseasyinstall.md) | Opens the window; `-Backend Mock` for the simulated installer |

## What the commands have in common

- **Nothing happens without a question.** The commands that install or change something check the input first
  and ask for confirmation. `-WhatIf` shows what would happen and asks for nothing; `-Confirm:$false` skips the
  question.
- **Accounts and passwords are asked for** when you do not pass them. To run unattended, pass
  `-CredentialMap` and `-SecretMap`, or with the Lab profile one `-LabPassword`.
  [`Get-PASCredentialRequirement`](configuration.md#get-pascredentialrequirement) lists what a lab needs.
- **`-SecurityProfile`** is `Secure` by default in every command. A lab built from templates needs `Lab`; see
  [Lab and Secure profiles](../concepts/profiles.md). Only the Lab profile was tested.
- **Install commands return a run id.** The installation runs in its own process. `-Wait` follows it.
