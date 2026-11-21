# Release notes

## 2.0.1

- **One module again.** The desktop window is part of `PASeasyInstall`: `Install-Module PASeasyInstall`, then
  `Start-PASeasyInstall`. There is no separate `PASeasyInstall.UI` module (it was never published to the Gallery).
  The commands still need nothing else; only `Start-PASeasyInstall` needs NativeHTMLKit and offers to install it.
- `PASeasyInstall` 2.0.0 on the Gallery has the commands but not the window; use 2.0.1.

## 2.0.0

!!! note "Lab-tested on 2026-11-21, Lab profile only"
    2.0.0 installed whole labs from clean servers without manual steps, with CyberArk 15.0 and 15.2, on
    Windows Server 2022, Ubuntu 24.04 and Rocky Linux 9: Vault, DR Vault, PVWA, CPM, PSM and PSMP, also two
    instances of each component. The desktop installed a Full lab (15.2) on real servers, including a stop with
    an error and *Try again*. Not tested: the Secure profile and domain-joined components. What works, what is
    experimental and what comes later is in `Docs/STATUS.md` of the repository.

2.0.0 keeps what 1.0 installs and how it installs it (the recipes that run on the servers are unchanged). It
replaces the command set and simplifies the controller.

### What is new

- **New desktop:** rewritten directly on the NativeHTMLKit SDK. Four steps (media, lab, servers, install), a page per
  installation with progress, retry and a lab check, an **Advanced** switch, a compact window with a dim colour scheme.
- **VC++ runtimes** for the Vault are taken from the CPM, PVWA or PSM package; they no longer have to be downloaded
  when one of those is part of the lab.
- **One command per component:** `Install-PASVault`, `Install-PASPVWA`, `Install-PASCPM`, `Install-PASPSM`,
  `Install-PASPSMP`, `Install-PASDomainController`. `Install-PASLab` installs a whole lab from one configuration.
- **Run commands:** `Get-PASRun`, `Get-PASRunEvent`, `Wait-PASRun`, `Resume-PASRun`, `Stop-PASRun`.
- **`Test-PASPreflight`** (new): checks the controller and the servers without changing anything.
- **`Resume-PASRun -RetryStep`**: execute a named failed step again after you inspected the server.
- **The desktop** shows the run id and, when a run stops, the commands to continue. `-Config` reopens a saved
  project.
- **Active Directory** can be installed from a command (`Install-PASDomainController`) like every other component.

### Breaking changes

- **The commands have no dependencies.** Only `Start-PASeasyInstall` needs NativeHTMLKit. (2.0.0 planned a separate
  `PASeasyInstall.UI` module for the desktop; 2.0.1 keeps everything in one module.)
- **All 1.0 command names are gone.** See the mapping below. There are no aliases.
- **No parallel installation.** Components are installed one after the other. `execution.mode = Parallel` in an old
  project file is accepted with a warning and runs sequentially.
- **Locks are simpler.** The controller-side environment claims and the coordination folder
  (`C:\ProgramData\PASeasyInstall-Coordination`) are gone. There are three locks: run lock, target lock, Vault lock.
  The message "Unreconciled resource" no longer exists. See [Coordination and locks](concepts/coordination.md).
- **A failed step is not repeated on resume.** Name it with `-RetryStep`.
- **No source digest.** Updating the module no longer invalidates a run that you want to resume.
- **Run file names changed:** `run-v2.json`, `plan-v2.json` and `events-v2.jsonl` are now `run.json`, `plan.json`
  and `events.jsonl`. Runs started with 1.0 cannot be resumed with 2.0.
- **Desktop:** `-Advanced` and `-Theme` are gone (one theme). `-Backend Orchestrator` is now `-Backend Live`.
- **Portable ZIP:** the launcher `Invoke-PASeasyInstall.cmd` is gone; use `PASeasyInstall-Shell.cmd` and the
  commands.
- **PTA** is not included. Its PowerShell code was removed.

### Command mapping 1.0 to 2.0

| 1.0 | 2.0 |
|---|---|
| `Start-PASeasyInstall` | `Start-PASeasyInstall` (same module, new window) |
| `Invoke-PASeasyInstall -Config <file>` | `Install-PASLab -Path <file>` |
| `Invoke-PASeasyInstall -Config <file> -PlanOnly` | `Get-PASLabPlan -Path <file>` |
| `Invoke-PASeasyInstall -Resume <id>` | `Resume-PASRun -RunId <id>` |
| `New-PASDeploymentConfiguration` | `New-PASLabConfiguration` |
| `Test-PASEnvironment` | `Test-PASLabConfiguration` |
| `Get-PASEnvironmentPlan` | `Get-PASLabPlan` |
| `Save-PASEnvironment` | `Export-PASLabConfiguration` |
| (reading a project file) | `Import-PASLabConfiguration` |
| `Start-PASEnvironment` | `Install-PASLab` |
| `Get-PASEnvironmentSnapshot -RunId <id>` | `Get-PASRun -RunId <id>` |
| `Get-PASEnvironmentEvents` | `Get-PASRunEvent` |
| `Resume-PASeasyDeployment` | `Resume-PASRun` |
| `Close-PASDeployment` | `Stop-PASRun` |
| `Test-PASEnvironmentHealth` | `Test-PASHealth` |
| `Export-PASRunData` | `Export-PASDiagnostics` |
| `New-PASFreshEnvironment`, `New-PASExistingVaultComponent`, the per-component `Invoke-PAS<X>` and `New-PAS<X>Configuration` commands | `Install-PASVault`, `Install-PASPVWA`, `Install-PASCPM`, `Install-PASPSM`, `Install-PASPSMP`, `Install-PASDomainController` |
| `Get-PASMediaInventory`, `Get-PASMediaSelection`, `Get-PASStageCatalog` | unchanged |
| (new) | `Wait-PASRun`, `Test-PASPreflight`, `Get-PASCredentialRequirement`, `Get-PASRunLog` |

Parameter changes to note: `-Config` is now `-Path` on the lab commands (`-Config` still works on `Test-PASHealth`),
and `Stop-PASRun` has no `-Reason`.

## 1.0.0 (first public release)

**Supported in this release:** Vault (Primary, or Primary + DR), PVWA, CPM, PSM, PSMP and Active Directory (new
forest), installed from a Windows PowerShell 5.1 controller through the desktop or the command line.

- New six-step desktop: media detection (including inside the CyberArk bundle ZIP), several instances per component,
  co-location, and one-server-at-a-time or parallel installation (parallel was removed in 2.0).
- One configuration for a whole lab, run as a coordinated set of durable runs.
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

- Reopening a saved project in the desktop (added in 2.0: `Start-PASeasyInstall -Config`).
- Resuming a failed run from the desktop. Use the resume command at the prompt (2.0: `Resume-PASRun`).
- Active Directory from the desktop (command line only; 2.0: `Install-PASDomainController`).

## Roadmap

- An end-to-end lab test of 2.0.0.
- Domain-joined component servers chosen from the desktop.
- Resume a run from the desktop.
