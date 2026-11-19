# Release notes

## 1.0.0 (first public release)

**Supported in this release:** Vault (Primary, or Primary + DR), PVWA, CPM, PSM, PSMP and Active Directory (new
forest), installed from a Windows PowerShell 5.1 controller through the desktop or the command line.

- New six-step desktop: media detection (including inside the CyberArk bundle ZIP), several instances per component,
  co-location, and one-server-at-a-time or parallel installation.
- One configuration for a whole lab (`New-PASDeploymentConfiguration`), run as a coordinated set of durable runs.
- Linux targets: the SSH key is set up from the server password you type once.
- Distributed as a portable ZIP (GitHub Releases) and as a PowerShell Gallery module.

### Tested

Each line is a complete installation on a clean server, run with the 1.0 release candidates and checked to the end
(services running and the component logged on to the Vault).

| CyberArk PAM | Component | Server OS | Started from |
|---|---|---|---|
| 15.0 | Vault + DR (pair) | Windows Server 2022 | Desktop |
| 15.0 | PVWA, CPM, PSM | Windows Server 2022 | Desktop |
| 15.0 | PSMP | Ubuntu 24.04 | Desktop |
| 15.2 (Vault 15.2.5.158) | Active Directory (new forest) | Windows Server 2022 | Command line |
| 15.2 | Vault | Windows Server 2022 | Command line |
| 15.2 (PVWA/CPM 15.2.3) | PVWA + CPM on one server | Windows Server 2022 | Command line |
| 15.2 (PSM 15.2.2.45) | PSM, into an existing Vault | Windows Server 2022 | Command line (Gallery module) |
| 15.2 (PSMP 15.2.1) | PSMP, into an existing Vault | Ubuntu 24.04 | Command line (Gallery module) |
| 15.2 (PSMP 15.2.1) | PSMP, into an existing Vault | Rocky Linux 9.8, SELinux enforcing | Command line (portable ZIP) |

Also tested: closing the controller in the middle of a PSM installation and resuming the same run (one vendor
installation, no repeat), and on 15.0 a CPM password change, DR replication, and a brokered PSMP session with
its recording. The controller was Windows Server 2022 with Windows PowerShell 5.1.

### Not in this release

- **PTA (Privileged Threat Analytics).** The code stays in the repository for future work, but it is not offered
  in the desktop or in the public commands.
- Reopening a saved project in the desktop. The project file is used by the command line
  ([`Invoke-PASeasyInstall`](commands/invoke-paseasyinstall.md)).
- Resuming a failed unit from the desktop. Use [`Resume-PASeasyDeployment`](commands/resume.md).
- Active Directory from the desktop (command line only).

## Roadmap

- PTA, once it can be qualified on hardware that meets the vendor's sizing (16 GB RAM, 8 vCPU, 500 GB disk).
- Domain-joined component servers chosen from the desktop.
- Reopen and resume projects in the desktop.
