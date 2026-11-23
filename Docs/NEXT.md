# What is left to do

Work list for the next sessions, written on 2026-11-22 after release 2.0.3 and updated the same day after the
small fixes. Start at the top. Part 1 is what is left of the small fixes; Part 2 is the four big pieces;
Part 3 is improvements that are not needed for the lab to work.

Read first: [`AGENTS.md`](../AGENTS.md) (rules of this repository), [`STATUS.md`](STATUS.md) (what works, what
was tested), [`DESIGN.md`](DESIGN.md) (how a run works).

## How to work

**Keep it simple.** Every piece below comes down to the same four things:

1. deploy the server role or service;
2. connect it to the Vault (and PVWA where needed);
3. verify that the service runs and is registered;
4. show it in the window.

Do not build frameworks, option matrices or abstractions for cases nobody asked for. One way to do each thing,
readable by somebody who did not write it. When the vendor ships an automation script or an answer file, use it.

**Every task is finished only when:**

- it ran on real lab servers, from clean operating systems, without a manual step;
- the unit tests and `Tools\Check-Source.ps1` pass;
- `STATUS.md` says what was tested and with which CyberArk version; this file has the task ticked or removed;
- nothing that was not run is described as working.

**Where things are**

| What | Where |
|---|---|
| Commands | `PASeasyInstall/Public` (one file per command) |
| Run controller, steps, journals | `PASeasyInstall/Private/Run`, `Private/Engine` |
| What runs on the servers | `PASeasyInstall/Recipes/<family>` |
| Window | `PASeasyInstall/Desktop`: `Model.ps1` (data), `Views.ps1` (screens), `App.ps1` (window and events) |
| What the window may call | `PASeasyInstall/Desktop/Backend/Backend.Contract.ps1`; keep the Mock in step |
| Scripted walk through the window | `PASeasyInstall/Desktop/SelfTest.ps1` (scenario file; headless or real window) |

**Testing.** Unit tests need Windows PowerShell 5.1 and Pester 5. Lab servers, addresses, snapshots and the
test harness are described in the private lab notes of the workstation, not in this repository.
A stopped run cannot be continued after the module was changed (it pins its recipe files): when a lab run shows
a defect, fix it, reset that server and start a new run.
The window can be driven without a mouse and without a desktop session: `App.ps1 -Backend Live -SelfTest
<scenario.json>` presses the buttons through UI Automation and saves every screen as a PNG file. That is how
the real installs through the window were tested.

**Releasing.** Bump `ModuleVersion` in `PASeasyInstall/PASeasyInstall.psd1`, add the release notes
(`site-src/release-notes.md` and `ReleaseNotes` in the manifest), merge to `main`, push tag `v<version>`.
The Release workflow publishes the GitHub release and the PowerShell Gallery package. Publish only when the
owner says so.

---

## Part 1: small fixes (do these first)

Done on 2026-11-22 (released in 2.0.4; see [STATUS.md](STATUS.md) for what was tested): the server
check verifies the Linux root password; the lab check works without name resolution; a retried CPM registration
uses the existing CPM user; the two excluded tests run in CI again; the window starts an installation in the
background; a reconciled step loses its old error text; a Vault on its own finds the VC++ runtimes in a package
of the media selection; "who installs" values. What is left:

### 1.1 Check by hand what was only tested by script

Needs a person at a Windows desktop, or a real interactive session.

- [ ] The window is WPF since 2026-11-22 and was never seen on a real desktop: every check below is open again.
      Look also at the icon in the title bar and the taskbar, and at keyboard use (Tab, Enter, Esc).
- [ ] `Start-PASeasyInstall` typed into an interactive Windows PowerShell console opens the window.
- [ ] The Servers form: a wrong address and a wrong password are named within seconds; correct entries lead to
      the plan (2.0.3). A wrong Linux root password is named too (2026-11-22, by script only).
- [ ] The Media step: several folders and files added with the pickers and by typed path (drag and drop was
      removed on 2026-11-22: a dropped folder froze the window on a real desktop).
- [ ] The window at its smallest size (480 x 340) and in a remote desktop session.
- [ ] Press *Install* and move the window while "Starting the installation..." is shown: it must stay usable
      (2026-11-22, measured by script only).
- [ ] Advanced view of the Servers step: the two "Who installs" fields.

Fix what does not work. Nothing to build if all pass.

### 1.2 Left over from the small fixes

- [ ] The two tests that were excluded from CI (`ControllerLease.Tests.ps1`, `VaultPadrStandby.Tests.ps1`) pass
      on the Windows Server controller, repeatedly; the exclusion list is empty. Whether they pass on a
      GitHub-hosted runner shows with the first CI run of this branch. If `ControllerLease` fails there, move it
      to `Tests/ci-exclude-hosted.txt`.
- [ ] Install a Vault on its own from the bundle ZIP, without VC++ runtime files in the media folder, once on a
      server (the lookup is unit-tested only).
- [ ] Install CPM, PSM and a Vault once with `-InstallerName` / `-InstallerCompany` (only PVWA was installed
      with them).
- [ ] CPM retry, the one case that cannot be repaired (STATUS.md 3.5): provoke it once through a run, to see the
      message of the step. Cutting the registration about one second after the credential file appears hits it.
- [ ] Old versions: 2.0.0 (no window) and 2.0.1 (does not start from an interactive console) are still listed on
      the PowerShell Gallery. Ask the owner whether to unlist them.
- [x] Release these changes as 2.0.4 (2026-11-22).

---

## Part 2: the big pieces

In this order. Each one: get it working from the prompt first, then add it to the window.

### 2.1 Active Directory and domain-joined components

**Done on 2026-11-22** (released in 2.0.4): `New-PASLabConfiguration -DomainMode New|Existing`, the domain
controller sets its own DNS, PVWA/CPM/PSM servers are joined before they are installed, the PSM install account
becomes a local administrator of the PSM server, and a lab that creates its domain imports the vendor's hardening
GPOs and applies them to the joined servers (owner's request of 2026-11-22). One lab with a new forest and joined
PVWA, CPM and PSM installed unattended and is healthy. The window has the choice and the extra server line.

**Left** (details in [STATUS.md](STATUS.md) 3.2):

- [ ] Run the window with a new domain against real servers (only the simulated installation was walked).
- [ ] Try `-DomainMode Existing` against a domain that was not created by this tool. The hardening GPOs are
      imported only into a domain the lab creates (owner's decision of 2026-11-22); an existing domain is not changed.
- [ ] Use the vendor's in-domain hardening variants on joined servers (`CPM_In_Domain_Hardening.ps1`, PVWA without
      its INF step), so that the local template and the GPO do not both set the same things.
- [ ] A GPO for a server that holds PSM together with CPM ("Unified" backup in the PSM package).
- [ ] `registerpsmwithdomain`: PSM is registered with local PSMConnect users, as in a workgroup. Domain users for
      PSM were not needed for a healthy lab and are not set up.
- [ ] `Test-PASHealth` should also look at the services, not only at the Vault's "logged on" flag.

### 2.2 HTML5 Gateway

**Done on 2026-11-22** (released in 2.0.4): component type `HTML5GW` (container with the vendor script,
Docker on Ubuntu), the lab PVWA certificate in its trust folder, registration in the PVWA configuration, the
health page as verification, one more component in the window. Results and limits: [STATUS.md](STATUS.md) 3.4.

**Left**

- [ ] Open a PSM session in a browser through the gateway (by hand; see STATUS.md 3.4 for what the browser needs).
- [ ] Ask the owner for a complete 15.2 gateway package; then let the media selection skip a package that is cut short.
- [ ] Run it on a RHEL-family server (Podman).
- [ ] Optional custom gateway certificates for lab interoperability, without adding a production profile.
- [ ] Add a gateway to a lab that is installed already.

### 2.3 Stability and repeatable lab automation

**Only disposable lab environments are in scope.** A production-supported deployment and a Secure/production
profile are not planned. Stabilize dependency ordering, verifier-only recovery, safe cancellation and resume,
clear progress reporting, and reproducible Proxmox lab scenario evidence before the next public release.
See [LAB-STABILIZATION.md](LAB-STABILIZATION.md) and `LabValidation/`.

### 2.4 PTA

**Done on 2026-11-22** (released in 2.0.4): component type `PTA`. A lab with Vault, PVWA and PTA on a
RHEL-family server with 8 GB installed unattended, PTA is connected to the Vault and the lab check reports it.
How it works and what it needs: [STATUS.md](STATUS.md) 3.3 and [DESIGN.md](DESIGN.md).

The method, for the record (found with the help of the `CyberArk-VMware-Lab` project): the installer application
on port 8443 takes the configuration by REST. The vendor ships a script that does it,
`/opt/pta/utility/internal/ptaAutomaticConfiguration.py`, with the values in environment variables
(`rootPassword`, `vault_ip`, `vault_timezone`, `vault_adminUser`, `vault_adminPassword`, `pvwa_host`). The sign-in
only works while SELinux is permissive. The address is `/installer/api/installation` without a slash at the end;
with the slash 15.2 answers 404, which looked like a missing call on 2026-11-21.

**Left**

- [ ] Vault syslog forwarding to PTA (`dbparm.ini` with `AllowNonStandardFWAddresses` and a `[SYSLOG]` section
      using `Syslog\PTA.xsl`, Vault restart; on PTA a plain TCP listener on 11514). The Vault recipes for it were
      removed in commit `b3bffad`; `CyberArk-VMware-Lab` has a working example in
      `Scripts/Configure-VaultSyslogToPTA.ps1`. Then check in the PTA web page that events arrive.
- [ ] Run the window with PTA against real servers (only the simulated installation was walked).
- [ ] Remove the unused PTA branches from `Recipes/LinuxComponent/Task.sh` and `Verify.sh`.
- [ ] RHEL 8, and memory under load (lower the heap sizes with `changeComponentResource.sh` if 8 GB are too small).

---

## Part 2.5: install the servers at the same time

**Done on 2026-11-22** (owner's request of that day): `execution.mode = Parallel`, the default of new lab
configurations. One lane per server, signals for the domain, the Vault and the first PVWA, and the Vault lock as
the queue for the registrations. Results: [PARALLEL.md](PARALLEL.md) and [STATUS.md](STATUS.md).

**Left**

- [ ] The step that stopped once with "SSH observation timed out" (PARALLEL.md, "Open"): find the cause.
- [ ] Let the registrations start when the Primary Vault is ready instead of waiting for the DR Vault.
- [ ] Two of each component, and a lab with DR and a new domain, in parallel.
- [ ] PSM in the vendor's order (register after hardening): the vendor's stage script reports a failure although
      the registration worked (PARALLEL.md, second round). Find the cause.
- [ ] `-SkipHardening` for the single `Install-*` commands (today only `New-PASLabConfiguration` and the window).
- [ ] The server check (`Test-PASPreflight`) signs in to one server after the other: five servers took almost
      five minutes from the window on 2026-11-22. Check the servers at the same time.
- [ ] `Install-PASLab` needed 108 seconds before the run started (five servers, 15.2 bundle). Find out where
      the time goes (media digests are the first suspect).

---

## Part 3: improvements (not needed for the lab to work)

Written on 2026-11-22 after release 2.0.4, from a look at what a complete lab would still want. None of this
blocks using the tool. In the order of usefulness.

### 3.1 A lab that does something after the installation

Today the last step of a run is "the component is connected". Nothing proves that a password is managed or that
a session opens.

- [ ] Sample content: one safe, one Windows account and one Linux account of the lab servers, and a CPM password
      change on each.
- [ ] A PSM session and a PSMP session to those accounts as a verification step.
- [ ] Directory integration: when the lab creates a domain, connect the Vault and PVWA to it (LDAP), so that
      domain users can sign in to PVWA.
- [ ] PSM with domain users on a joined server (`registerpsmwithdomain`, also listed in 2.1).

### 3.2 Vault events for PTA

Listed in 2.4 (Vault syslog forwarding). Without it PTA is installed and connected but sees no Vault events.

### 3.3 Credential providers

- [ ] Central Credential Provider (CCP): an IIS application and a provider on a Windows server. The only common
      self-hosted component without a component type.
- [ ] Credential Provider agent (CP) on a Windows or Linux server, when somebody needs it.

### 3.4 Changing a lab that exists

Every run assumes clean servers.

- [ ] Add a component to an installed lab (the gateway case is listed in 2.2).
- [ ] Upgrade a lab (15.0 to 15.2).
- [ ] Remove a component.

### 3.5 A stronger lab check

- [ ] `Test-PASHealth` looks at the services of each component, not only at the Vault's "logged on" flag (also
      listed in 2.1).
- [ ] After 3.1: the lab check can verify a password and open a test session.

### 3.6 DR beyond replication

- [ ] Run a failover to the DR Vault and back, once, and write down what the components do.

### 3.7 Tests

- [ ] `KeyGeneration.Tests.ps1` ("captures true zero and nonzero exit statuses") failed once on the Windows
      controller on 2026-11-22 while other work ran there, and passed when it was run alone.
- [ ] `ControllerBootstrap.Tests.ps1` failed once on the GitHub-hosted runner on 2026-11-22 (status
      `LaunchFailed` instead of `Failed` after 1.5 seconds: the controller process could not be started) and
      passed when the job was run again. Find out why, or move it to `Tests/ci-exclude-hosted.txt`.

---

### 3.8 Left open after 2.0.7 (owner's test on the two-network lab, 2026-11-23)

- **The window was not run against real servers with the 2.0.7 changes** (gateway on its own server, Save on the
  Servers step, the new status texts): simulated installer and unit tests only.
- **A failing first PVWA, Primary Vault in a lab with DR, or domain controller** is covered by unit tests of the
  signals, not by a lab run. (A failing Vault without DR happened by accident in the lab and behaved as designed.)
- **The gateway is installed even when PSM fails**; only its registration in PVWA is left out. It could be
  skipped entirely.
- **Verify of the Primary Vault takes about two minutes** after the restart that follows hardening: it waits
  until the four Vault services run. Nothing waits longer than needed, but everything that registers waits for it.
- **`Stop-PASRun` now retains locks by default**, even with `-CredentialMap`. Only `-ReleaseLocksAfterReset`
  permits cleanup after target VM reset/rebuild. The window must never silently offer unsafe cleanup.
- **Server check:** an HTML5 Gateway server is still judged like a PSMP server (same distributions, so it fits).
  Memory and disk of the other Linux servers are not checked.
- **Media scan:** only a ZIP whose end is missing is found. A ZIP that is damaged in the middle is found when it
  is unpacked on the server.

### 3.9 Left open after 2.0.9

- **2.0.8 and the lab-stabilized changes were run in the lab on 2026-11-23** (eight scenarios, all passing after
  the fixes released as 2.0.9). The gateway is no longer entered into PVWA at the very end.
- **A failed server cannot be tried again while the run is still going.** The buttons come when every other
  server is finished. Trying one server again inside a running run needs a second controller for one lane.
- **Releasing a PSM for SSH lock after a reset** (`Stop-PASRun -ReleaseLocksAfterReset`) uses only the
  controller key, which a reset server no longer trusts: it warns instead of releasing (the reset server has no
  lock, so nothing is left behind). It should fall back to the password of `-CredentialMap`.
- **A run against a locked, already hardened PSMP** fails at the password sign-in before it reaches the lock,
  so its message names the password, not the lock.
- **The server check takes 4 to 7 minutes for three Windows servers** (the window stays responsive).
- **Every Linux check is a detached systemd job** since 2.0.9: safer after a lost connection, about 4 seconds
  per finished Linux step when a run is continued.
- **CPM registration damaged in transit** in the two-node lab: see PARALLEL.md, fourth round. If it comes back
  with the NIC offloads off, look at the CPM server's `Casos.Debug.log` and at the path between the nodes.

## Not on this list

- Cluster and distributed Vaults: out of scope by the owner's decision.
- More combinations (three or four instances of a component, PSMP on RHEL 8, SLES and Ubuntu 22): test them when
  somebody needs them.
- Tidying of code carried over from 1.0 (old internal names, dense code): only where a task above touches it.
