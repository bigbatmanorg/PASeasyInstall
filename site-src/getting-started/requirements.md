# Requirements

## What was tested

| | |
|---|---|
| CyberArk PAM Self-Hosted | 15.0 and 15.2 |
| Controller | Windows Server 2022 |
| Windows servers | Windows Server 2022 |
| Linux servers | Ubuntu 24.04 (PSM for SSH, HTML5 Gateway), Rocky Linux 9 (PTA; PSM for SSH once) |
| Security profile | Lab only |

Other versions listed below are accepted by the code but were not tested. A full lab of nine machines (Vault,
DR Vault, PVWA, CPM on its own server, PSM, PSM for SSH, HTML5 Gateway, PTA, and the controller) installed in
about 19 minutes through the window.

## The controller

The Windows computer you run PASeasyInstall on.

| | |
|---|---|
| Operating system | 64-bit Windows with Windows PowerShell 5.1, for example Windows Server 2022 or Windows 10/11. |
| PowerShell | **Windows PowerShell 5.1**, which is part of Windows. PowerShell 7 cannot run installations. |
| Other software | None. The window is drawn with WPF, which is part of Windows. For Linux servers the OpenSSH client of Windows (`ssh.exe`) is used. |
| Disk | Several GB free: installers taken out of a big ZIP are kept in a cache under `%LOCALAPPDATA%\PASeasyInstall`, next to the journal of every installation. |
| Session | Start installations from a local session (console or remote desktop), not from a remote PowerShell session. See [Troubleshooting](../troubleshooting/index.md#the-controller-could-not-be-started-windows-dpapi). |

The address of the controller matters: a hardened Vault accepts management connections only from the
controller address of the lab. The window fills it in. To change it, switch on **Advanced** and edit
**Address of this computer** on the Servers step.

## The servers

Freshly installed machines. PASeasyInstall does not create them.

| For | Operating system | Size that worked in the lab |
|---|---|---|
| Vault, DR Vault | Windows Server 2022, **not** member of a domain | 2 CPUs, 4 GB, 100 GB disk |
| PVWA | Windows Server 2022 | 2 CPUs, 4 GB (6 GB together with CPM) |
| CPM | Windows Server 2022; can share the PVWA server | 2 CPUs, 4 GB |
| PSM | Windows Server 2022 | 2 CPUs, 4 GB |
| PSM for SSH | Ubuntu 22.04/24.04 or RHEL, Rocky, Alma 8/9 | 2 CPUs, 2 to 4 GB, 40 GB disk |
| HTML5 Gateway | Linux; it runs as a container (Docker on Ubuntu, Podman on the RHEL family). Can share the PSM for SSH server | 4 GB together with PSM for SSH |
| PTA | RHEL, Rocky or Alma 8.8+ or 9.3+, a server of its own | 4 CPUs, **8 GB**, 80 GB disk |
| Domain controller (new domain) | Windows Server 2022 | 2 CPUs, 3 to 4 GB |

These sizes are enough for a lab and below what CyberArk recommends for production. All servers are
installed at the same time, so the host of your virtual machines needs the memory for all of them at once.

Every server needs a unique computer name and a fixed address. What else each one needs is on
[Server prerequisites](../servers/prerequisites.md). In short:

- **Windows:** WinRM over HTTPS (port 5986) reachable from the controller, and a local administrator.
- **Linux:** SSH (port 22) reachable from the controller, root able to sign in with its password once, and
  `jq` installed.

## Network

| From | To | Port | For |
|---|---|---|---|
| Controller | Windows servers | TCP 5986 (WinRM over HTTPS) | installation |
| Controller | Linux servers | TCP 22 (SSH) | installation |
| Controller | PVWA | TCP 443 | the lab check |
| Components, PTA | Vault | TCP 1858 | registration and normal work |
| DR Vault | Vault | TCP 1858 | replication |
| CPM, PSM, browsers | PVWA | TCP 443 | web portal and API |
| PVWA | PTA | TCP 443 | PTA in PVWA |
| Browsers | HTML5 Gateway | TCP 443 | sessions in the browser |

Linux servers also need their package sources while they are installed: missing tools such as `unzip`, and
Docker or Podman for the HTML5 Gateway, are installed from them.

## Your CyberArk media

Download CyberArk PAM Self-Hosted from CyberArk yourself, with your own account and license.
PASeasyInstall recognises the files by their names:

- **The one big ZIP** (for example `Privileged Access Manager Self-Hosted-15.2.zip`). It is looked into without
  unpacking it; only the installers a lab uses are taken out, into the cache of the controller.
- **Or the separate ZIPs**: `Server-Rls-...zip`, `PACLI-Rls-...zip`, `Disaster Recovery-Rls-...zip`,
  `Password Vault Web Access-Rls-...zip`, `Central Policy Manager-Rls-...zip`,
  `Privileged Session Manager-Rls-...zip`, `PrivilegedSessionManagerSSHProxy-<distribution>-...zip`,
  `HTML5 Gateway-Rls-...zip`, `PTA-Installer-Rls-...zip`.
- **For a new Vault also the `Vault Ansible Role` ZIP** (it is inside the big ZIP). The key generator and the
  response file templates of the Vault come from it.
- **`license.xml`**, your Vault license.
- **`recpub.key`**, the recovery *public* key of your operator keys.
- **The Visual C++ runtimes** for the Vault (`VC_redist.x64.exe`, `VC_redist.x86.exe`). They are taken from the
  CPM, PVWA or PSM package when one of them is in the media. Only a lab with no such package needs the two files
  as well.

Some components need a package of another one: PTA needs the PSM for SSH package (it holds the CyberArk package
signing key), and the HTML5 Gateway needs the PACLI package.

The files do **not** have to be in one folder. Give the window, or `Get-PASMediaInventory`, every folder and
file where a part lies. A folder is searched four levels deep. Nothing is unpacked, moved or changed while the
media is looked through.

!!! note "Several copies, damaged packages"
    When several versions of an installer are found, the highest one is used. A package that is not a complete
    ZIP file is marked as damaged and is not used when another copy is there. If the only copy is damaged, the
    Media step says so: download it again, or add another place that holds a good copy. In the test lab the
    HTML5 Gateway package inside one 15.2 bundle was damaged; a 15.0 gateway package, added as a second place,
    installed and worked.
