---
hide:
  - navigation
  - toc
---

# PASeasyInstall

**Build a complete CyberArk PAM self-hosted lab from one Windows controller, in one sitting.** Use plain
PowerShell commands, or point the desktop at your installer media, name your servers, choose a password, and click
**Install**. You get a Vault (or a
replicated Primary + DR pair), PVWA, CPM, PSM, PSMP and an optional Active Directory forest. Each component is
installed, registered, hardened and verified on its own server.

!!! note "Version 2.0.0"
    2.0.0 has a new, simpler command set and module layout. It was tested once end to end in a lab (CyberArk 15.0, Windows Server 2022,
    Ubuntu 24.04); the desktop has not been clicked through yet.
    The 1.0 command names are gone: see the [release notes](release-notes.md).

!!! warning "Made for labs"
    PASeasyInstall is built to stand up **CyberArk PAM labs** quickly: training, demos, proof-of-concepts,
    testing upgrades and integrations. You may point it at anything you like, but **production use is entirely at your
    own risk and responsibility**. PASeasyInstall is a community project and is **not affiliated with, endorsed by or
    supported by CyberArk**. You supply your own licensed CyberArk media. [Why lab first?](lab-first.md)

## Choose how you start

<div class="grid cards" markdown>

-   **[Portable ZIP](getting-started/portable.md)**

    Download one ZIP from GitHub Releases, unzip it on the controller and double-click
    `Start-PASeasyInstall.cmd`. Everything it needs, including the NativeHTMLKit UI runtime, is inside.

-   **[PowerShell Gallery](getting-started/gallery.md)**

    One module: `Install-Module PASeasyInstall`. Then `Start-PASeasyInstall` opens the desktop, or use the
    commands. Updates come with `Update-Module`.

-   **[Command line](commands/index.md)**

    One command per component, for example `Install-PASVault -ComputerName 10.10.0.11 -MediaPath C:\CyberArk\media -Wait`.
    Or save a lab configuration once and rebuild the same lab with `Install-PASLab -Path .\Lab01.json -Wait`.

</div>

## What it looks like

![The Review plan step: six servers, their stages and the lab-mode security deviations listed](assets/screenshots/5-review.png)

*Review plan: everything that will happen, in order, before anything is sent to a server.*

## What you get

| | |
|---|---|
| **Vault** | Primary Vault, or a new **Primary + DR** pair with replication verified by a test Safe. Hardened; in Lab mode RDP is allowed from the controller only. |
| **PVWA** | IIS/.NET prerequisites, installation, a TLS certificate (a self-signed lab certificate in Lab mode), registration, hardening and verification. |
| **CPM** | Installation, registration (with a pinned PVWA certificate in Lab mode) and hardening. The services run as the dedicated CPM user. |
| **PSM** | Workgroup (out-of-domain) PSM with the vendor's required reboots handled for you. No plaintext autologon. |
| **PSMP** | PSM for SSH on Ubuntu 22.04/24.04 or RHEL/Rocky 8/9 (lab-tested on Ubuntu 24.04 and Rocky 9). The SSH key setup comes from a password you type once. |
| **Active Directory** | A new forest with DNS on its own domain controller, for domain-joined lab scenarios. |

Several instances of each component (up to four) and co-located components are chosen in the desktop or in the
configuration. The servers are installed at the same time; the registrations with the Vault run one at a time.
[Components in detail](components/index.md)

## Built to be trusted with your lab

- **Nothing happens until Install.** Planning, validation and media checks are read-only.
- **Durable runs.** Every step is a recorded attempt on the target. If the controller closes, reboots or loses the
  network, the run resumes from the last confirmed step and never blindly reruns an installer.
  [How it works](concepts/durable-runs.md)
- **No secrets on disk.** Passwords live only in memory. They never go into project files, logs or journals.
  [Security model](concepts/security.md)
- **Native desktop, no browser.** The UI is a native window built with
  [NativeHTMLKit](https://nativehtmlkit.github.io/). There is no web server, browser engine or JavaScript.

**Next:** [Requirements](getting-started/requirements.md) · [Your first lab](getting-started/first-lab.md) · [Desktop UI tour](gui/index.md)
