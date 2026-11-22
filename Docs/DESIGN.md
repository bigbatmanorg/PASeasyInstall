# PASeasyInstall 2.0: design in one page

For someone new to the code. Lab tool; see the warning in the README.

## Layout

```text
PASeasyInstall/              core module, no dependencies
  Public/                    25 commands, one file each (the whole command line surface)
  Private/Common             JSON, paths, secrets, small helpers
  Private/Config             configuration (read, validate, compose), credentials, plan, workflow generator
  Private/Media              find and select installer media
  Private/Engine             runs ONE workflow on ONE server: transports, step attempts, journal, locks
  Private/Run                the run controller: all components of a run; the servers at the same time (Lanes.ps1)
  Private/Diagnostics        health, logs, diagnostics export
  Recipes/                   scripts executed ON the servers (Vault, WindowsComponent, LinuxComponent, ActiveDirectory)
  Controllers/               Invoke-PASRunController.ps1, entry script of the detached controller process
PASeasyInstall/Desktop/      desktop window (WPF); calls only the public commands in Backend/Backend.Contract.ps1
```

Names: a **run** is one installation (one controller process, one run id). A **component** is one item of the plan
(vault, dr, pvwa01, ...). A **target** is one engine workflow on one server; a component is usually one target,
the Vault with DR is four (`primary`, `dr`, `primary_final`, `dr_final`). A **step** is one entry of a workflow.
An **attempt** is one execution of a step on the server.

## What happens when you run `Install-PASVault`

1. **Configuration.** The public command builds a configuration hashtable (the same shape `New-PASLabConfiguration`
   produces and `Install-PASLab` reads). No password is in it.
2. **Validation.** `Test-PASConfiguration` checks structure, topology rules and media. `-WhatIf`/`-PlanOnly` stop here.
3. **Plan.** `Get-PASDeploymentPlan` orders the components (AD, joins, Vault, DR, PVWA, CPM, PSM, PSMP) and
   computes `ConfigDigest` and `MediaDigest` (SHA-256 of each installer).
4. **Credentials.** After you confirm, missing accounts and passwords are asked for (`Resolve-PASInstallCredential`).
5. **Detached run controller.** `Start-PASDeployment` writes the run folder, hands the credentials to a new
   `powershell.exe` through a DPAPI envelope file, and returns the run id. The child runs
   `Controllers/Invoke-PASRunController.ps1`, deletes the envelope after reading it, and takes the run lock.
6. **Per-target workflow.** For each component the controller writes its workflow and inventory, then calls
   `Invoke-PASWorkflow` (the engine). The engine takes the target lock on the server and walks the steps.
7. **Step attempt.** A detached step is staged on the server as an attempt folder and started as a **scheduled
   task** (Windows) or a **systemd unit** (Linux). The controller only observes it. If the controller dies, the
   attempt continues and is found again by its id.
8. **Verify.** Every step has a separate, read-only verify script. Success of the installer process alone is
   never accepted.
9. **Journal.** Before dispatch and after every outcome the engine writes the step state to `state.json` and an
   event to `events.jsonl`. `Get-PASRun` and the desktop only read these files.

## Files a run leaves behind

**Controller**, `%LOCALAPPDATA%\PASeasyInstall\Runs\<run id>\` (or `$env:PAS_EASY_DATA_ROOT`):

| File | Content |
|---|---|
| `run.json` | status, controller PID and start time, current component (several in a parallel run), message |
| `config.json`, `plan.json` | what the run installs; frozen at start |
| `events.jsonl` | events of the run controller |
| `controller.lock` | the run lock (empty file, held open by the controller) |
| `credentials-<guid>.json` | DPAPI envelope; exists only until the controller has read it |
| `Payloads\<component>\` | frozen recipe copies, `Workflows\<component>.psd1`, `inventory.psd1` |
| `vault-inventory.psd1`, `join-<server>-inventory.psd1` | inventories of the Vault sequence and of domain joins |
| `<target>\state.json`, `<target>\events.jsonl` | journal and events of one engine target |
| `milestones\<name>.json` | published by Vault steps that another target waits for |
| `pvwa-trust-<pvwa>.cer` | PVWA certificate captured for CPM pinning (Lab) |

Beside `Runs\`: `MediaCache\` (installers extracted from bundles) and `ssh\<environment>\` (controller SSH key).

**Windows target**, stage root `C:\ProgramData\PASeasyInstall` (components) or `C:\ProgramData\PAExec` (Vault):
`locks\<server id>\owner.txt` (target lock), `attempts\<attempt id>\` with `task.ps1`, `host.ps1`, `runner.ps1`,
`ownership.ps1`, `contract.txt`, optional `recovery.ps1`, `status.json`, `principal.json`, `stdout.log`;
scheduled task `\PAExec\PAExec-<attempt id>`; `media\<component>\installer.zip`; `components\<component>\`.

**Linux target**: `/opt/paeasyinstall/attempts/<attempt id>/` with `task.sh`, `runner.sh`, `unit.service`,
`contract.txt`, `status.json`, `stdout.log.tail`, `stderr.log.tail`; step inputs in
`/run/paeasyinstall/attempts/<attempt id>/inputs.json` (memory only); systemd unit `paeasy-<attempt id>.service`;
target lock `~/.paeasyinstall/locks/<server id>/owner`; `/opt/paeasyinstall/media/<component>/installer.zip`.

## The three locks (`Private/Engine/Locks.ps1`)

1. **Run lock**: `controller.lock`, an exclusive file handle of the controller process. It ends with the process.
2. **Target lock**: a folder on the server that names the run id. It is **kept when a run fails**, so no other run
   touches a half-installed server. The same run takes it again on resume. `Stop-PASRun` releases it.
3. **Vault lock**: a named mutex on the controller (`Global\PASeasyInstall-Vault-<address>`). One authenticated
   Vault session at a time. Always released in `finally`, never kept after a failure, leaves no files.

## Servers at the same time (`Private/Run/Lanes.ps1`)

A configuration with `execution.mode = Parallel` (the default of `New-PASLabConfiguration`) installs the servers
side by side. `Sequential`, or a configuration without the key, installs one component after the other.

- **Lane**: the work of one server, in plan order. Each lane is a runspace of the controller process with its
  own copy of the module, so remoting sessions are not shared. The Vault with its DR Vault is one lane, the new
  forest is one lane. Components on the same server stay one after the other.
- **Signals** (wait handles inside the controller, set once): `Domain` (forest installed), `Vault` (Vault
  sequence finished), `PvwaRegistered` (first PVWA finished `register`), `Cert:<pvwa>` (PVWA has its
  certificate), `Done:<pvwa>`, `Cancel` (a lane failed).
- **Who waits:** a joined server waits for `Domain` before its join. A component that trusts the PVWA
  certificate (CPM, gateway, PTA) starts when every PVWA has one. A step that signs in to the Vault waits for
  `Vault`; every component except the first PVWA also for `PvwaRegistered`; PTA for every PVWA to be finished.
  Then the step takes the Vault lock, so the registrations run one at a time.
- **A lane fails:** `Cancel` is set. A lane that waits gives up (its target is journalled as `Stopped`, shown as
  Pending); a lane that works finishes the component it is installing. The run ends Failed with the step that
  failed. `Resume-PASRun` starts every lane again; finished steps are only revalidated.
- Gateway registration, PTA trust and the GPOs follow the lanes, in order, as in a sequential run.
- While preparing a component, the lanes of one run share the SSH known-hosts file and the PVWA certificate
  bundle; that short part is guarded by a mutex of the run (`prepare-<run id>`).

## Resume, retry, stop

- **Resume** (`Resume-PASRun`): allowed for Failed, Unknown, Interrupted, LaunchFailed, Blocked. The controller
  refuses if `ConfigDigest` or `MediaDigest` changed. Module files may change (there is no source digest).
  The engine pins a digest of workflow + scripts + inventory per target: PVWA, CPM, PSM, PSMP and AD run from
  the frozen copies in `Payloads\`, Vault targets read the module (see debt). Succeeded steps are only
  revalidated (read-only). A step that was dispatched is reconciled by its attempt id, never started twice.
- **Retry**: a Failed or Unknown step is not repeated on resume. `-RetryStep <step>` or `<component>:<step>`
  names it; a name that matches no Failed/Unknown step is an error. `-RetryFailedPreflight` repeats a failed
  read-only Linux preflight.
- **Status**: `PAExecLocked:` in the error means Blocked, `PAExecUnknown:`/`Unknown:` means Unknown, else Failed.
  A run whose controller process is gone is reported as Interrupted (PID and start time must both match).
- **Stop** (`Stop-PASRun`): refuses a live controller without `-Force`; with it, stops only the process that is
  provably this run's controller. Marks the run Abandoned and releases target locks that still name the run
  (with `-CredentialMap`), or lists the lock folders. Abandoned runs cannot be resumed. Nothing is uninstalled.

## Adding a component recipe

1. Put the on-server scripts in a folder under `Recipes/` (a task script with stages and a read-only verify
   script; follow `WindowsComponent/Task.ps1` + `Verify.ps1` or `LinuxComponent/Task.sh` + `Verify.sh`).
2. Add the type and its stage names to `Get-PASComponentStageNames` and, if needed, to `New-PASComponentWorkflow`
   and `New-PASRuntimeInventory` (`Private/Config/Planning.ps1`). `Get-PASStageCatalog` follows automatically.
3. Add validation rules to `Test-PASConfiguration`, the run order to `Get-PASDeploymentPlan`, the media pattern
   to `Private/Media`, and required credentials to `Get-PASInstallRequirement`.
4. Add `Public/Install-PAS<Type>.ps1` (thin: build the configuration, call `Invoke-PASComponentInstall`), add it
   to `FunctionsToExport`, and add tests (`StageCatalog.Tests.ps1` picks the type up from its list).

## A lab with a domain

Order of a run: forest (`ad`), one join workflow per server (`join-<server>`: DNS, join, restart, local
administrator for the PSM install account, verify), Vault, components, then the GPO phase
(`Private/Config/DomainPolicy.ps1`, recipe `Recipes/ActiveDirectory/Gpo-Task.ps1`): `policy-prepare-<server>` adds
the firewall rule for the management port, `policy-domain` uploads the vendor GPO backups to the domain controller,
imports and links them and moves the servers into `OU=<role>,OU=CyberArk`, `policy-<server>` refreshes the policy
and checks that the GPO is applied and the management rule is still in force. The vendor GPOs ignore local
firewall exceptions that name only a port; the rule therefore names the program (System) too.

## HTML5 Gateway

Component type `HTML5GW`, recipe `Recipes/Html5Gateway` (`Task.sh`, `Verify.sh`: unpack, container engine,
`html5_console.sh install -l` and `run`, health page). After the components, `Invoke-PASGatewayRegistration`
runs `Register-Gateway.ps1` on the first PVWA server (target `register-<gateway id>`,
`Private/Config/GatewayRegistration.ps1`): PACLI retrieves `PVConfiguration.xml` from the Vault, the script adds
`PSMGatewayServers/PSMGatewayServer` and a `PSMGateway` reference to every PSM server, stores the file, reads it
back and restarts the PVWA application pool. PACLI runs from `C:\PASeasyInstallGateway`, a folder closed to
everybody but SYSTEM and the administrators (the PACLI helper refuses `C:\ProgramData`).

## PTA

Component type `PTA`, recipe `Recipes/Pta`. `Task.sh` stages: Extract, Prerequisites (sshpass, unzip, tar; the
CyberArk signing key, which the composer takes out of the PSMP package), Install (`pta_installer.sh`), then a
restart step of the engine, Register (hosts entries, the PVWA certificate into PTA's Java trust stores, SELinux
permissive for the vendor's `ptaAutomaticConfiguration.py`, ports in firewalld, restart of `appmgr`). The root
password of the server reaches the Register step as the run secret `PTARoot-<id>`, which
`Initialize-PASComponentRun` takes from the server's account. After the components, `Invoke-PASPtaTrust` runs
`Trust-Pta.ps1` on the first PVWA server (target `trust-<pta id>`, Lab profile only).

## Known debt

- What was tested, what is experimental and what comes later is in [STATUS.md](STATUS.md).
- The PSM service restart after the last reboot (`Start-PASeasyPsmStoppedService`) was tried on a server but
  never triggered inside a complete run: in the later runs the PSM service stayed up by itself.
- A retried CPM registration uses the vendor's upgrade mode when the credential file of an earlier attempt names
  the CPM user (`Get-PASeasyCpmRegistrationMode` in `Recipes/WindowsComponent/Vendor.ps1`). One state cannot be
  repaired that way and is reported instead (see STATUS.md 3.5).
- Anti-tamper ACL code (owner/ACL checks of staging folders) is duplicated in about 8 places; not consolidated.
- Unused PTA shell branches still exist in `Recipes/LinuxComponent/Task.sh` and `Verify.sh`; PTA has its own
  recipe in `Recipes/Pta` now.
- Install paths are hard-coded (`C:\` drive, `C:\ProgramData\...`, `/opt/paeasyinstall`).
- Vault recipes are read from the module at resume, not from a per-run copy: editing them blocks the resume of
  Vault targets (digest mismatch).
- On-disk and remote names still say `PAExec` / `paeasyinstall` (stage root, task path, lock folders, endpoint name).
- Error-prefix strings `PAExecUnknown:` / `PAExecLocked:` are used for control flow instead of typed errors.
- Much of `Private/` is dense one-line code from 1.0; only new code follows "one statement per line".
