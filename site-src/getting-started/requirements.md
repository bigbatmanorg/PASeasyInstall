# Requirements

## The controller

The computer you run PASeasyInstall on.

| | |
|---|---|
| Operating system | Windows 10/11 or Windows Server 2019/2022/2025, 64-bit. Tested from Windows Server 2022. |
| PowerShell | **Windows PowerShell 5.1**, which is part of Windows. PowerShell 7 is not supported. |
| Other software | None. The window is drawn with WPF, which is part of the .NET Framework on Windows. The OpenSSH client of Windows is used for Linux servers. |
| Disk | About 10 GB free: installers taken out of a big ZIP are kept in a cache, and every installation keeps its journal. |
| Session | Start installations from a local session (console or remote desktop), not from a remote PowerShell session. See [Troubleshooting](../troubleshooting/index.md#the-controller-could-not-be-started-windows-dpapi). |

The address of the controller matters. A hardened Vault accepts management connections only from the controller
address of the lab. The window fills it in; you can change it under **Advanced** on the Servers step.

## The servers

Empty, freshly installed machines. PASeasyInstall does not create them.

| For | Operating system | Size that worked in the lab |
|---|---|---|
| Vault, DR Vault | Windows Server 2022, **not** member of a domain | 2 CPUs, 4 GB, 100 GB disk |
| PVWA | Windows Server 2022 | 2 CPUs, 4 GB (6 GB together with CPM) |
| CPM | Windows Server 2022 | 2 CPUs, 4 GB; can share the PVWA server |
| PSM | Windows Server 2022 | 2 CPUs, 4 GB |
| PSM for SSH | Ubuntu 22.04/24.04 or RHEL/Rocky 8/9 | 2 CPUs, 2 to 4 GB, 40 GB disk |
| HTML5 Gateway | Linux with Docker (Ubuntu) or Podman (RHEL family); can share the PSM for SSH server | 4 GB together with PSM for SSH |
| PTA | RHEL, Rocky or Alma 8.8+ or 9.3+ | 4 CPUs, **8 GB**, 80 GB disk |
| Domain controller (new domain) | Windows Server 2022 | 2 CPUs, 3 to 4 GB |

These sizes are enough for a lab and below what CyberArk recommends for production. Only Windows Server 2022,
Ubuntu 24.04 and Rocky Linux 9 were tested.

Every server needs a unique computer name and a fixed address. What else each server needs is on
[Server prerequisites](../servers/prerequisites.md). In short:

- **Windows:** WinRM over HTTPS (port 5986) reachable from the controller, and a local administrator.
- **Linux:** SSH (port 22) reachable from the controller, and root able to sign in with its password once.

## Network

| From | To | Port | For |
|---|---|---|---|
| Controller | Windows servers | TCP 5986 (WinRM over HTTPS) | installation |
| Controller | Linux servers | TCP 22 (SSH) | installation |
| Controller | PVWA | TCP 443 | the lab check |
| Components | Vault | TCP 1858 | registration and normal work |
| DR Vault | Primary Vault | TCP 1858 | replication |
| CPM, browsers | PVWA | TCP 443 | web portal and API |
| Browsers | HTML5 Gateway | TCP 443 | sessions in the browser |

## Your CyberArk media

Download CyberArk PAM Self-Hosted from CyberArk yourself. PASeasyInstall recognises the files by their names:

- **The one big ZIP** (for example `Privileged Access Manager Self-Hosted-15.2.zip`). It is looked into without
  unpacking it; only the installers that are used are taken out, into the cache of the controller.
- **Or the separate ZIPs**: `Server-Rls-...zip`, `PACLI-Rls-...zip`, `Disaster Recovery-Rls-...zip`,
  `Password Vault Web Access-Rls-...zip`, `Central Policy Manager-Rls-...zip`,
  `Privileged Session Manager-Rls-...zip`, `PrivilegedSessionManagerSSHProxy-<distribution>-Intel64-Rls-...zip`,
  `HTML5 Gateway-Rls-...zip`, `PTA-Installer-Rls-...zip`.
- **For a Vault also `Vault Ansible Role-Rls-...zip`** (it is inside the big ZIP). The key generator and the
  response file templates come from it.
- **`license.xml`**, your Vault license.
- **`recpub.key`**, the recovery *public* key of your operator keys. A ZIP of the keys is accepted; only
  `recpub.key` is read from it.
- **The Visual C++ runtimes** for the Vault (`VC_redist.x64.exe`, `VC_redist.x86.exe`). They are taken from the
  PVWA, CPM or PSM package when the lab has one of them. Only a Vault on its own needs the two files as well.

The files do **not** have to be in one folder. Give the window, or `Get-PASMediaInventory`, every folder and
file where a part lies. A folder is searched four levels deep.

!!! note "Versions"
    When several versions of an installer are found, the highest one is used. The gateway package inside the
    15.2 big ZIP is cut short and cannot be installed; see [HTML5 Gateway](../components/html5gw.md#media).
