# PASeasyInstall

**Build a CyberArk PAM self-hosted lab from one Windows controller.** PASeasyInstall installs a Vault (or a
replicated Primary and DR pair), PVWA, CPM, PSM, PSMP and an Active Directory lab forest on servers you provide.
Each component is installed, registered, hardened and verified on its own server.

📖 **Documentation: <https://bigbatmanorg.github.io/PASeasyInstall/>**

> [!WARNING]
> **Made for labs.** PASeasyInstall is built to stand up CyberArk PAM **labs** quickly: training, demos,
> proof-of-concepts, testing upgrades and integrations. Production use is entirely at your own risk and
> responsibility. This is a community project, **not affiliated with, endorsed by or supported by CyberArk**. You
> supply your own licensed CyberArk installation media and license.

> [!NOTE]
> **Version 2.0.0 is a rewrite of the command set and the module layout.** It was tested once end to end in a lab
> (CyberArk 15.0, Windows Server 2022, Ubuntu 24.04); the desktop has not been clicked through yet. The 1.0 command names are gone; see the
> [release notes](https://bigbatmanorg.github.io/PASeasyInstall/release-notes/) for the mapping.

![The Review plan step of the PASeasyInstall desktop](Docs/screenshots/integrated/5-review.png)

There are two ways to use it. Both run the same code.

## 1. PowerShell commands

```powershell
Install-Module PASeasyInstall -Scope CurrentUser
```

The module has no dependencies. It needs Windows PowerShell 5.1.

**One Vault:**

```powershell
Install-PASVault -ComputerName 192.0.2.11 -MediaPath D:\CyberArkMedia -Wait
```

The command checks the input and asks for confirmation. Then it asks for the Windows account of the server and for
the two Vault passwords to set. It installs and hardens the Vault and shows the progress. Add `-WhatIf` to see what
would happen: nothing is asked and nothing is contacted.

**Then a PVWA for that Vault:**

```powershell
Install-PASPVWA -ComputerName 192.0.2.21 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -Wait
```

CPM, PSM, PSMP and a domain controller work the same way: `Install-PASCPM`, `Install-PASPSM`, `Install-PASPSMP`,
`Install-PASDomainController`. With `-SecurityProfile Lab` you may give one password for everything:
`-LabPassword (Read-Host -AsSecureString 'Lab password')`.

**A whole lab from one configuration:**

```powershell
$media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path D:\CyberArkMedia)
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode PrimaryDR `
    -PrimaryAddress 192.0.2.11 -DRAddress 192.0.2.12 -ControllerAddress 192.0.2.10 `
    -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' },
                 @{ Type = 'CPM';  Name = 'CPM01';  Address = '192.0.2.22' }) `
    -Media $media -SecurityProfile Lab
Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab.json

Test-PASLabConfiguration -Path .\MyLab.json -CheckMedia    # is it complete?
(Get-PASLabPlan -Path .\MyLab.json).Items | Format-Table Id, Type, Address, Media   # what would be installed, in which order
Test-PASPreflight -Path .\MyLab.json                       # are the servers reachable and ready?
Install-PASLab -Path .\MyLab.json -Wait                    # install
```

The configuration file never contains a password.

## 2. The desktop

```powershell
Start-PASeasyInstall
```

`Start-PASeasyInstall` is part of the same module. Its window only calls the commands above. It is drawn with WPF,
which is part of Windows, so nothing else has to be installed. Four steps build a lab: media
folder, the lab to build, servers and password, review and install. Each installation then has a page with live
progress, retry and a lab check. Nothing is sent to a server before you press **Install** on the last step.
`Start-PASeasyInstall -Config .\MyLab.json` reopens a saved lab file.
`Start-PASeasyInstall -Backend Mock` shows the same window with a simulated installation.

**Portable ZIP:** download `PASeasyInstall-<version>-portable.zip` from
[Releases](https://github.com/bigbatmanorg/PASeasyInstall/releases), unblock it, extract it, and double-click
`Start-PASeasyInstall.cmd`. The module is inside and needs nothing else. Nothing is installed.

Full tour with screenshots: [Desktop UI](https://bigbatmanorg.github.io/PASeasyInstall/gui/).

## Commands

| Command | What it does |
|---|---|
| `Install-PASVault` | Installs a Primary Vault, or a Primary and DR Vault pair. |
| `Install-PASPVWA` | Installs PVWA on a Windows server and registers it with an existing Vault. |
| `Install-PASCPM` | Installs CPM on a Windows server and registers it with an existing Vault. |
| `Install-PASPSM` | Installs PSM on a Windows server and registers it with an existing Vault. |
| `Install-PASPSMP` | Installs PSM for SSH (PSMP) on a Linux server and registers it with an existing Vault. |
| `Install-PASDomainController` | Creates a new Active Directory forest for a lab. |
| `Install-PASLab` | Installs everything a lab configuration describes. |
| `New-PASLabConfiguration` | Composes the configuration of a lab. Contacts nothing. |
| `Test-PASLabConfiguration` | Checks a configuration: structure, topology rules and, with `-CheckMedia`, the installer files. |
| `Get-PASLabPlan` | Shows what a configuration would install: components, servers, installers, order. |
| `Export-PASLabConfiguration` | Saves a configuration as a JSON file (never a password). |
| `Import-PASLabConfiguration` | Reads a configuration from a JSON file. |
| `Get-PASMediaInventory` | Finds CyberArk installer media in files, folders and ZIP bundles. Read-only. |
| `Get-PASMediaSelection` | Picks one installer per component from the inventory. |
| `Get-PASCredentialRequirement` | Lists the server accounts and passwords a configuration needs. |
| `Get-PASStageCatalog` | Lists the installation stages of a component type, in order. |
| `Get-PASRun` | Lists the runs of this controller, or shows one run with its components and events. |
| `Get-PASRunEvent` | Returns the progress events of a run, oldest first. `-Failed` shows only failures. |
| `Wait-PASRun` | Follows a run until it ends and returns the final run. |
| `Resume-PASRun` | Continues a run that stopped. `-RetryStep` executes a failed step again. |
| `Stop-PASRun` | Gives a run up: marks it Abandoned and releases its locks on the servers. |
| `Test-PASPreflight` | Checks, without changing anything, that the controller and the servers are ready. |
| `Test-PASHealth` | Checks an installed lab: PVWA login, connected components, DR replication. |
| `Export-PASDiagnostics` | Writes a sanitized ZIP of one run for support or documentation. |
| `Get-PASRunLog` | Reads the controller journal of a run, or the tail of a CyberArk log on a lab server. |

Every command has full help: `Get-Help Install-PASVault -Full`. Overview: `Get-Help about_PASeasyInstall`.

## When something fails

An installation is a **run**. It executes in its own controller process and has a run id.

```powershell
Get-PASRun                                   # all runs, newest first
Get-PASRun -RunId <id>                       # one run: status, components, latest events
Get-PASRunEvent -RunId <id> -Failed          # what failed
Get-PASRunLog -RunId <id>                    # the controller journal of the run
Test-PASPreflight -Path .\MyLab.json         # is a server unreachable or not ready?
```

Correct the cause on the server. Then continue the same run:

```powershell
Resume-PASRun -RunId <id>                          # finished components are checked again, the rest is installed
Resume-PASRun -RunId <id> -RetryStep cpm01:install # also execute this failed step again
```

A step that ended Failed or Unknown is never repeated on its own. You name it with `-RetryStep` after you looked
at the server. If you will not continue the run (for example after you rebuilt the servers), give it up:

```powershell
Stop-PASRun -RunId <id> -CredentialMap $creds      # marks it Abandoned and releases its server locks
Export-PASDiagnostics -RunId <id>                  # sanitized ZIP for a bug report
```

More: [Troubleshooting](https://bigbatmanorg.github.io/PASeasyInstall/troubleshooting/).

## What it installs

| Component | |
|---|---|
| Vault | A new Primary Vault, or a **Primary + DR** pair with replication verified by a test Safe |
| PVWA | Prerequisites, installation, TLS (a self-signed certificate in Lab mode), registration, hardening |
| CPM | Installation, registration (trusting the PVWA certificate it is pinned to in Lab mode), hardening |
| PSM | Workgroup PSM, with the vendor's reboots handled; no plaintext autologon |
| PSMP | PSM for SSH on Ubuntu 22.04/24.04 or RHEL-family 8/9 |
| Active Directory | A new forest with DNS |

You can install up to four instances of each component and put components together on one server. Components
are installed one after the other. PTA and the PSM HTML5 Gateway can be part of a lab from 2.0.4 on (see `Docs/STATUS.md`).

## How it works

A Windows PowerShell 5.1 controller drives the vendor's own installers on the targets over WinRM HTTPS (Windows)
and SSH (Linux).

- Every step is a recorded attempt on the server, verified by a separate check. An interrupted run resumes from
  what actually happened on the server. An installer is never rerun blindly.
- Passwords live only in memory.
- The desktop is a native Windows window (WPF). There is no browser, web server or JavaScript, and no
  module besides PASeasyInstall.

What works now, what is experimental and what comes later is in [Docs/STATUS.md](Docs/STATUS.md).
The mental model, the files a run leaves behind and the known debt are in [Docs/DESIGN.md](Docs/DESIGN.md).
More in [Concepts](https://bigbatmanorg.github.io/PASeasyInstall/concepts/).

## Execution policy

PASeasyInstall is not code-signed. Under the default `RemoteSigned` policy nothing extra is needed. For a portable
ZIP, run `Unblock-File` on the ZIP before extracting it. Where `AllSigned` is enforced, run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

That allows unsigned code for the current PowerShell window only. Details:
[Execution policy](https://bigbatmanorg.github.io/PASeasyInstall/getting-started/execution-policy/).

## Repository layout

```text
PASeasyInstall/                 the core module (no dependencies)
  Public/                       one file per exported command (25)
  Private/Common|Config|Media   helpers, configuration and planning, installer media
  Private/Engine                transports, step attempts, journals, locks
  Private/Run                   run controller, events, the Install-* plumbing
  Private/Diagnostics           health, logs, diagnostics export
  Recipes/                      scripts that run on the servers: Vault, WindowsComponent, LinuxComponent, ActiveDirectory
  Controllers/                  entry script of the detached run controller process
PASeasyInstall/Desktop/         the desktop window (WPF: XAML and PowerShell); calls only the public commands
Start-PASeasyInstall.ps1        opens the desktop from a source checkout
Tests/, Tools/                  Pester tests and build/check tools
Docs/                           DESIGN.md, third-party licenses, README screenshots
site-src/, zensical.toml        documentation site (https://bigbatmanorg.github.io/PASeasyInstall/)
```

## Development

```powershell
.\Tools\Check-Source.ps1                          # parser, both manifests, export list == Public folder
.\Tools\Invoke-CITests.ps1                        # Check-Source, then the Pester 5 suite CI runs
Invoke-Pester -Path .\Tests                       # every test; some are Windows-only
.\Start-PASeasyInstall.ps1 -Backend Mock          # the desktop with a simulated installation, no servers needed
.\Tools\Build-PortableRelease.ps1                 # both Gallery packages and the portable ZIP, under .\dist
```

Documentation site: `pip install zensical==0.1.1`, then `zensical serve` (preview) or `zensical build`.
Contributor rules are in [AGENTS.md](AGENTS.md).

## License

MIT, see [LICENSE](LICENSE). Bundled third-party code: `Docs/THIRD_PARTY_*_LICENSE.txt` (MIT). CyberArk and CyberArk
product names are trademarks of CyberArk Software Ltd., used here only to describe what this tool installs.
