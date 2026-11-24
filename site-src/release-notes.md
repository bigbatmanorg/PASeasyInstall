# Release notes

## 2.0.16

- **Install the lab is at the top of the Install step.** The button was below the plan, the lab shortcuts and the
  lab file card, so with a larger lab it was only reached by scrolling and easy to miss. It now comes right under
  the time estimate (and under the warning when the servers will not be hardened), above the plan.

## 2.0.15

- **PSM hardening tries again up to three times after a LanmanServer timeout.** Right after the hardening
  restart, the vendor's hardening can give up waiting 30 seconds for the Server service (LanmanServer), although
  the service restarted and the admin share was hardened; the step then failed and needed **Fix**. When that is
  the only error in the vendor's hardening log, the hardening stage now runs again by itself, up to three times
  with 30 seconds between tries (2.0.12 to 2.0.14 tried once, 2.0.11 and older not at all). Any other
  hardening error still stops the step at once.

## 2.0.14

- **Choose a folder... opens the same dialog as Choose files...** On the Media step, folders were picked in the
  small old folder tree of Windows. Now both buttons open Windows' own file dialog (with the address bar, search
  and recent places); for a folder it shows **Select Folder**, and it starts in the same folder as the file
  dialog. Should that dialog not be available, the old folder tree is used as before.

## 2.0.13

A clean-up release: what is in the repository is what the tool uses. Nothing changes in how a lab is installed.

- **Dead code removed.** The PSM for SSH recipe (`Recipes/LinuxComponent`) still carried an older PTA
  installation that nothing called any more; PTA has its own recipe (`Recipes/Pta`) since 2.0.4. About 600
  lines of shell code are gone; the PSM for SSH steps are unchanged.
- **Obsolete helper files removed:** an old agent prompt and structure check for lab validation, a one-time
  source reformatter, and duplicate copies of the third-party license texts and their provenance record (the
  license texts still ship with the module; the README names the projects).
- **The PSM for SSH server check no longer names SLES 15.** Its message listed SLES 15 as supported, but the
  installation steps accept only Ubuntu 22.04/24.04 and RHEL/Rocky 8/9; a SLES server is now refused at the
  check with the right list.
- **Documentation brought up to date** with the code: the Vault steps of a run also run from copies kept with
  the run (an update of PASeasyInstall does not change a started run), the full text of the *locked by run*
  message, when PSM counts as registered (after its last pass), the Vault choices of the window in the README,
  the lab validation folder and the development section of the README.

## 2.0.12

From the owner's lab run of 2026-11-24 (2.0.11, nine servers).

- **Trying one step again leaves the finished servers alone.** After PSM stopped in its hardening, *Try this
  step again* started every server again: each one checked its finished steps, the Vault line went back to
  *Configure primary* and PTA trust was done again. Now a server that this run installed and verified is not
  contacted again, and an integration that finished (gateway registration, PTA trust) is not done again. Only the
  failed server and what waited for it go on. (2.0.8 did this already; a later change had taken it out.)
- **Next on the Servers step works the first time.** When the lab file was saved and Next was clicked while the
  window was still laying out the plan for the save, two plans ran at once: both unpacked the Vault media into
  the same cache (*Vault media could not be checked: Cannot create a file when that file already exists*) and
  the second one found nothing to continue with (*The expression after '&' in a pipeline element produced an
  object that was not valid*). The plans now run one after the other, and the media cache tolerates two checks
  at the same time.
- **Save the lab file saves.** In the same situation the save was lost: the second plan took the place of the
  save, so no file was written. The save now always gets its plan, and a save while the servers are being
  checked writes the configuration of that check.
- **PSM hardening survives a slow Server service.** The vendor's admin share hardening restarts the Server
  service (LanmanServer) and waits 30 seconds. When the restart takes longer, the vendor marks its hardening
  failed although the share is hardened; running it again succeeds. PASeasyInstall now does that once by
  itself, and only when that timeout is the only error in the vendor's hardening log.
- **The lab shortcuts on the review page are collapsed:** the box shows how many there are, *Show the list*
  opens it.

## 2.0.11

PTA is connected after an installation, and it no longer delays PSM. Tested in the lab on 2026-11-24 with a
full lab of nine servers (Vault, DR Vault, PVWA, CPM, PSM, PSM for SSH, HTML5 Gateway, PTA and the controller).

- **PTA shows as connected.** PVWA reaches PTA under the host name that PTA registers in the Vault: the name in
  PTA's own certificate, which is the real computer name of the PTA server. When that name differed from the
  name entered in the window (for example `labpta01` against `pta01`), PVWA could not resolve it, PVWA System
  Health showed PTA as not connected and the lab check said *No PTA is registered in the Vault*. The PTA trust
  step now adds the hosts entry for the name in the certificate on the first PVWA server, and its check makes a
  real HTTPS call to PTA by that name, as PVWA does.
- **PTA registers last.** The vendor's PTA configuration holds the Vault for about three minutes. PTA now waits
  until PSM and PSM for SSH have registered, so PSM (which still has its hardening after the registration, and
  which the HTML5 Gateway registration waits for) is no longer held up. A PSM that fails does not hold PTA back.
- **The lab check names the cause.** When the Vault knows a PTA but PVWA cannot reach it, the lab check says so,
  with PVWA's error, instead of *No PTA is registered in the Vault*.
- **A step that succeeded is no longer reported as Unknown.** When a step's worker on the server wrote its
  result and ended in the very moment the controller looked at it, the controller could see the old status and
  no process, and stopped the run as *Unknown* (seen once in the lab, on a PSM install pass after its restart).
  The controller now reads the status again before it decides that a step was interrupted (Windows and Linux).
- **PSM finishes its registration before PTA starts.** The PSM registration is a vendor checkpoint that runs up
  to three times; PTA now waits for the last of them.
- **Stop the installation works.** The button of the installation page (Advanced) stopped nothing: it called
  `Stop-PASRun` without `-Force`, which refuses a running installation. It now ends the installation, and its
  question says what that means: the installation cannot be continued, and the servers stay locked until they
  are restored.
- **Documentation rewritten** against the code, with new screenshots of a real installation. The demo video is
  gone.

## 2.0.10

Recovery after a failed or stopped installation, tested in the lab on 2026-11-24.

- **Releasing the locks after a reset works for PSM for SSH too.** `Stop-PASRun -ReleaseLocksAfterReset`
  signs in to a Linux server restored from a snapshot with the password of `-CredentialMap` again, as an
  installation does. Before, it could only warn, because the restored server no longer trusted the controller key.
- **A run that is blocked by an unfinished run says so.** On a Linux server that another run of this controller
  still holds (and has hardened), a new run now stops *Blocked* with `locked by run <run id>` and how to resume
  or release that run, instead of *Password sign-in failed*.
- **Tested in the lab:** the first PVWA failing in the middle of the installation (CPM and PSM give up at
  once, the Vault is finished, a plain *Continue* installs the rest), and the Primary Vault failing in a lab with
  a DR Vault (the DR Vault, PVWA and PSM stop where they need the Vault, nothing waits, *Continue* installs
  everything including the DR replication test).
- The message of a continued run says what happens: finished steps are checked again, read-only.

## 2.0.9

Lab-stabilized release, validated on Proxmox with CyberArk 15.2 in eight scenarios (window in a real desktop,
Primary + DR, PSMP + HTML5 Gateway + PTA, new AD domain, two PVWAs and two CPMs, interrupted checks, a failed PTA
with resume, forced stop). 696 Pester tests pass on Windows PowerShell 5.1.

- **Primary + DR labs finish again.** Since 2.0.8 the DR Vault could replicate the test Safe before its final
  check started, and that check then waited 15 minutes and failed. Every Primary + DR lab was affected.
- **PSM post-install no longer fails at random.** About a minute after the Remote Desktop restart, Windows can
  switch Network Level Authentication on again, after the vendor's *Disable NLA* step has checked it (seen in
  3 of 5 lab installations). PASeasyInstall now sets it back as the vendor intends and checks the result.
- **The HTML5 Gateway registration and the PTA trust run as soon as their own servers are ready**, not at the
  very end and not after the DR Vault. They wait for the Vault without a 3-minute limit, and for everything
  else installed on the first PVWA server.
- **A step whose check was cut off can be finished.** When the connection drops while a check is being started
  (for example on a PSMP or PTA server), the run stops as *Unknown*, as before. *Try this step again*
  (`Resume-PASRun -RetryStep`) now repeats only that check, never the installation, once the old check has
  been shown not to be running.
- **A continued run looks at the finished servers again, read-only.** It checks every finished step instead of
  skipping whole servers (2.0.8). Nothing is installed again; a check that no longer passes stops the run.
- **DR replication shows its progress**: phase and elapsed time of the wait (for example *Waiting for the test
  Safe, 390 of 900 seconds*) instead of a line that looks frozen for up to 15 minutes.
- **Every dependency is checked before anything is installed.** A wait for something that no server produces,
  or a real deadlock, stops the run at once with its name.
- **`Stop-PASRun -Force` keeps the server locks.** A stopped controller does not prove that the work on the
  servers has stopped. After you reset the lab servers, release the locks with
  `Stop-PASRun -ReleaseLocksAfterReset -CredentialMap ...`.
- **PSM for SSH**: the package installation (`unzip`) is its own step, *prepare-tools*, after the read-only
  server check.
- **Window:** one way to choose the lab: Primary Vault or Primary + DR and the number of each component. The
  ready-made labs (Starter, Standard, Full) are gone; an existing Vault and the domain are in Advanced.

## 2.0.8

- **The Primary Vault is finished when it is ready.** Its replication test safe is created right after it is
  installed, not after the DR Vault; before, the Vault line stayed on *Verify primary* until the DR Vault
  replicated. The DR Vault is finished when the safe has arrived there.
- **The Primary is ready about two minutes earlier.** After the restart that follows hardening, the
  installation starts the two "delayed start" Vault services itself instead of waiting for Windows to do it.
  Everything that registers with the Vault starts that much earlier.
- **Trying a failed step again leaves the finished servers alone.** A continued run starts only the servers
  that are not installed and verified yet. Before, every server and the Vault were looked at again, which took
  about a minute and looked like a new installation.
- **Window:** the line of a failed server says that it can be tried again when the other servers are finished.
  The line of an HTML5 Gateway says that its entry in PVWA comes after PVWA and PSM.

## 2.0.7

- **A server that fails stops only what depends on it.** Before, one failed server made every server that was
  waiting for its turn give up. Now a failed PTA, CPM, PSM, PSM for SSH, gateway or DR Vault stops nothing
  else; only a failed Primary Vault, first PVWA or new domain controller stops what needs it. The run still
  ends Failed and names what failed and what was not installed because of it.
- **The DR Vault is installed next to the Primary Vault**, not after it, and the other servers register as
  soon as the Primary is ready instead of waiting for the DR Vault.
- **The server check knows what a server is for.** A PTA server that is not RHEL, Rocky or Alma, or has less
  than 8 GB, is reported before anything is installed. Before, a PTA pointed at an Ubuntu server passed the
  check and failed during the installation.
- **CPM on a server that cannot resolve the PVWA name.** The CPM Scanner service calls PVWA under its computer
  name and ended at once when that name did not resolve, so the CPM check failed (servers in different
  networks without DNS). In a lab the CPM and PSM servers now get a hosts entry for every PVWA name they cannot
  resolve.
- **A damaged package is found before the installation.** A package that is not a complete ZIP file (cut off
  during the download, also one inside the big bundle) is marked `Damaged` by `Get-PASMediaInventory` and shown
  on the Media step. `Get-PASMediaSelection` and the window use another copy of that component when there is
  one, even an older one, and say so; with no other copy the configuration is refused with that reason.
- **A failed step on a Linux server shows its reason**, not only "Bash task failed with code 3".
- **Window:** the HTML5 Gateway can have a server of its own (a switch on the Lab step, like the one for CPM).
  **Save the lab file** is on the Servers step and on the Install step for everybody, not only in the Advanced
  view. After *Continue*, a server shows *Checking what is already installed* instead of the name of a step it
  only looks at again, and a server that was not continued says why.

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
