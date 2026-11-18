# Release notes

<!-- TODO(parent): replace with the real version number/date when 1.0.0-rc1 is published. -->

## 1.0 (first public release)

**Supported in this release:** Vault (Primary, or Primary + DR), PVWA, CPM, PSM, PSMP and Active Directory (new
forest), installed from a Windows PowerShell 5.1 controller through the desktop or the command line.

- New six-step desktop: media detection (including inside the CyberArk bundle ZIP), several instances per component,
  co-location, and one-server-at-a-time or parallel installation.
- One configuration for a whole lab (`New-PASDeploymentConfiguration`), run as a coordinated set of durable runs.
- Linux targets: the SSH key is set up from the server password you type once.
- Distributed as a portable ZIP (GitHub Releases) and as a PowerShell Gallery module.

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
