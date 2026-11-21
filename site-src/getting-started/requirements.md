# Requirements

## Controller

| | |
|---|---|
| Operating system | Windows Server 2019/2022/2025 or Windows 10/11, 64-bit |
| PowerShell | **Windows PowerShell 5.1** (built in). PowerShell 7 can run the desktop in Mock mode, but real installations need 5.1. |
| .NET | .NET Framework 4.7.2 or later (4.8 recommended) |
| UI runtime | [NativeHTMLKit](https://nativehtmlkit.github.io/). It is bundled in the portable ZIP, and installed automatically as a dependency from the Gallery. |
| OpenSSH client | Built into Windows. Needed only for PSMP (Linux) targets. |
| Disk | About 10 GB free for the media cache and run journals |

The controller's address matters. A hardened Vault accepts management connections (WinRM, and RDP in Lab mode)
**only from the controller address** you enter on the [Servers](../gui/servers.md) step.

## Target servers

| Role | Operating system | Lab sizing (minimum that worked) | Vendor recommendation |
|---|---|---|---|
| Vault / DR | Windows Server 2022, **not** domain-joined | 2 vCPU, 4 GB RAM, 100 GB | see CyberArk server specifications |
| PVWA | Windows Server 2022 | 2 vCPU, 4 GB RAM | |
| CPM | Windows Server 2022 | 2 vCPU, 4 GB RAM | |
| PSM | Windows Server 2022 (workgroup or domain member) | 2 vCPU, 4 GB RAM | 8 GB+ |
| PSMP | Ubuntu 22.04/24.04 or RHEL/Rocky 8/9 | 2 vCPU, 4 GB RAM, 40 GB | |
| AD domain controller | Windows Server 2022 | 2 vCPU, 4 GB RAM | |

Lab sizing is what PASeasyInstall was exercised with. It is fine for a lab and below what CyberArk recommends for
production.

**Each Windows target needs:**

- WinRM over HTTPS (TCP 5986) reachable from the controller, and a local Administrator account. See
  [Server prerequisites](../servers/prerequisites.md).
- A unique hostname and IP address. Static IP addresses are strongly recommended, because the Vault firewall and
  the components reference addresses.

**Each Linux (PSMP) target needs:**

- SSH reachable from the controller as `root`, or as the account you enter. Allow password login once (PASeasyInstall then
  installs its own key), or authorise the controller key yourself.
- `unzip` installed. Ubuntu cloud images do not include it: `apt-get install -y unzip`.

## Network

| From | To | Port | Purpose |
|---|---|---|---|
| Controller | Windows targets | TCP 5986 (WinRM HTTPS) | installation and management |
| Controller | PSMP | TCP 22 | installation |
| Controller | Vault | TCP 1858 | verification (PACLI) |
| Components | Vault / DR | TCP 1858 | registration and normal operation |
| DR | Primary Vault | TCP 1858 | replication |
| CPM / you | PVWA | TCP 443 | API and web access |

## Media

Supply the CyberArk PAM Self-Hosted media yourself. PASeasyInstall recognises it by file name:

- **The full bundle ZIP** (for example `Privileged Access Manager Self-Hosted_15.0_*.zip`). It is read in place
  without extracting everything, and only the selected installers are extracted.
- **Or single component ZIPs:** `Server-Rls-v15.0.zip`, `PACLI-Rls-v15.0.zip`, `Disaster Recovery-Rls-v15.0.zip`,
  `Password Vault Web Access-Rls-v15.0.zip`, `Central Policy Manager-Rls-v15.0.zip`,
  `Privileged Session Manager-Rls-v15.0.zip`, `PrivilegedSessionManagerSSHProxy-<distribution>-Intel64-Rls-v15.0.zip`.
- **For a Vault: `Vault Ansible Role-Rls-v15.0.zip`** (it is inside the full bundle). PASeasyInstall takes PAKeyGen, the
  response templates and the VC++ 2013 runtime from it. Without it the validation reports the Vault media files as missing.
- **`license.xml`**, and the **public** recovery key `recpub.key`. A keys ZIP is accepted, but only `recpub.key`
  is ever read from it.
- **VC++ redistributables** (`VC_redist.x64.exe`, `VC_redist.x86.exe`): needed for the Vault. They are taken from the CPM, PVWA or PSM
  package when one of them is part of the lab. Only for a Vault on its own, put the two files into the same folder.

Put everything in one folder (for example `C:\CyberArk\media`) and add that folder on the first step of the desktop.
