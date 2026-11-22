# Release notes

## 2.0.6

- **A server waits for the Vault only when it has nothing else to do.** PVWA and PSM for SSH now harden first
  and register with the Vault as their last step. CPM and PSM still register before their hardening: CPM's
  hardening needs a registered CPM, and for PSM the vendor's stage script reports a registration on a hardened
  server as failed.
- **A CPM on its own server starts at once.** PVWA creates its HTTPS certificate as its first step, so a CPM,
  PSM, HTML5 Gateway or PTA on another server copies it about a minute into the run and installs at the same
  time. Before, such a CPM waited until PVWA was installed.
- **Registrations follow the vendor's order:** every PVWA, then every CPM, then PSM, PSM for SSH and the rest,
  one at a time.
- **PSM trusts PVWA.** The vendor's PSM registration calls the PVWA API. In a lab the PSM server now trusts the
  PVWA certificate, so that call works; before, the registration ended with a warning that the API gateway
  connection could not be set up.
- **Installation without hardening.** `New-PASLabConfiguration -SkipHardening` (Lab profile), or the switch
  *Apply the vendor hardening* in the Advanced view of the Servers step, installs and registers everything but
  leaves out the vendor hardening on the Vault, PVWA, CPM, PSM and PSM for SSH and the hardening GPOs. For tests.
- **Window, Media step:** drag and drop is gone (a dropped folder could freeze the window). Folders and files
  are added by path or with the pickers, as many as needed; the page shows which place holds which installer,
  the licence and the keys, and what the chosen lab still misses.
- **Window:** CPM on the PVWA server or on its own server in every lab, not only in Custom. The PowerShell
  commands of an installation stand above the activity log (Advanced). The simulated installer shows the
  servers side by side.
- **PSM for SSH on Ubuntu** waits for the system's own package jobs before it installs its package.
- **Documentation** rewritten: README and the whole site, with pictures of the current window.

Measured on clean servers (CyberArk 15.2): Vault, PVWA, CPM on its own server, PSM and PSM for SSH in 19
minutes; a Full lab with DR without hardening in 21 minutes; both checked Healthy.

## 2.0.5

- **The window is a native Windows window (WPF). NativeHTMLKit is gone.** `Start-PASeasyInstall` needs nothing
  but Windows PowerShell 5.1: no second module to install, nothing bundled in the portable ZIP (0.4 MB). The
  screens and what they do are the same, in a new dark design. Every call to the installer runs in the
  background, so the window never stops reacting. It was tested by script on real servers, but not yet seen on
  a real desktop; please report what looks wrong.

- **The servers are installed at the same time.** Every server of a lab starts at once: upload, checks,
  prerequisites and the installation itself run side by side. A step that signs in to the Vault waits until the
  Vault is installed and the first PVWA is registered, and then the registrations run one at a time, so the
  Vault administrator is never used twice at once. A Full lab with DR (CyberArk 15.2) took 23 minutes instead of
  41. This is the default of new lab configurations; `New-PASLabConfiguration -ExecutionMode Sequential` keeps
  the old order. When one server fails, the others finish the component they are installing and the run stops;
  `Resume-PASRun` continues all of them.
- **The Vault installation no longer stops when Windows re-enables its update services.** Windows can switch
  "Windows Update" and "Background Intelligent Transfer Service" back on while the hardened Vault server
  restarts. A new step (`hardening-services`) disables them again before the hardening is verified.

- **The window says at once that it is checking the servers.** After **Next** on the Servers step the button
  is disabled immediately and a message shows which of the two parts is running: looking whether the servers
  answer, then signing in to each. Before, nothing changed for some seconds.
- **The Advanced switch is shown only where it does something**: on the Custom lab, the Servers step, the
  review and the installation page.
- **The step count of a component no longer changes during an installation.** A step, the restart it asked
  for and its continuation count as one step, and only the steps of the step list are counted (PSM showed up to
  17 of 10; a lab showed 65 steps at the start and 82 at the end). `Get-PASStageCatalog` also lists the steps of
  a domain join.
- **The window has its own icon.**

## 2.0.4

- **A lab with an Active Directory domain.** `New-PASLabConfiguration -DomainMode New -DomainName pam.lab
  -DomainControllerAddress <ip>` creates a new forest on one more server, joins the PVWA, CPM and PSM servers
  before they are installed, and at the end imports the CyberArk hardening GPOs of the vendor packages, links
  them and applies them to the joined servers. `-DomainMode Existing` joins the servers to a domain you already
  have (its GPOs are not touched). The window has the choice on the Lab step. Vault servers are never joined.
- **PTA.** A new component type `PTA` (in the window: PTA) installs Privileged Threat Analytics on a RHEL-family
  server with 8 GB with the vendor's installer, connects it to the Vault and to PVWA with the vendor's automatic
  configuration tool, and the lab check lists it. It needs a PVWA in the same lab, a PSMP package in the media
  folder (for the CyberArk package signing key) and the root password of the PTA server. Vault syslog forwarding
  to PTA is not set up yet.
- **PSM HTML5 Gateway.** A new component type `HTML5GW` (in the window: HTML5 Gateway) installs the gateway as a
  container with the vendor's script on a Linux server, also next to a PSMP, makes PVWA trust and know it, and
  checks its health page. It needs a PVWA in the same lab and the PACLI package in the media folder.
- **The server check verifies the root password of a Linux server.** `Test-PASPreflight` (and **Next** on the
  Servers step of the window) signs in with the password the way the first installation does, so a wrong
  password is named before anything is installed. The check still changes nothing: no key is authorised.
- **The lab check needs no DNS record or hosts entry.** When the PVWA name does not resolve on the controller,
  `Test-PASHealth` and *Check the lab* connect to the PVWA address of the configuration and send the server
  name, so the PVWA presents the certificate of that name.
- **Retrying a CPM registration no longer creates a second CPM user.** When an earlier attempt on that server
  already created the CPM user, `Resume-PASRun -RetryStep <cpm>:register` registers again with the existing
  user (the vendor's upgrade mode). If the vendor tool then reports that it could not finish the CPM
  environment, the step fails and says so.
- **"Who installs".** `New-PASLabConfiguration -InstallerName -InstallerCompany` (and two fields in the
  Advanced view of the window) set the user and company name the CyberArk installers record. Default: the
  CyberArk values, as before.
- **Window:** pressing *Install* no longer freezes the window while the installation starts. A Vault that is
  installed on its own takes the VC++ runtimes from a CPM, PVWA or PSM package of the media folder.
- A step that succeeded after a resume no longer shows the error text of its first try.
- The PVWA lab certificate step waits until Windows uses the new certificate (it could fail with *certificate
  chain is not trusted on the target* directly after creating it).

## 2.0.3

- **A wrong address no longer leaves an installation waiting.** Every `Install-*` command first checks, within
  seconds, that each server answers on its management port, and stops with the list of servers that do not.
  `Test-PASPreflight -ConnectivityOnly` does only that check.
- **Desktop, Servers step:** a plain form with the account and password of every server and the Vault passwords.
  The single "lab password" is gone from the window. **Next** checks the servers (do they answer, does the account
  work, is the server ready) and only then shows the plan; problems are named with the reason.
- The window remembers the accounts of the installation it started while it stays open, so *Try again* and
  *Check the lab* do not ask again.

## 2.0.2

- **`Start-PASeasyInstall` works from an interactive console.** In 2.0.1 it failed there with *The property
  'OSArchitecture' cannot be found* (the console's line editor PSReadLine and NativeHTMLKit 0.1.2 do not get along
  in one process). The window now opens in its own process, the prompt stays free, and a window that cannot start
  says why.

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
