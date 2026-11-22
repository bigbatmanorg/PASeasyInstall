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
  Private/Run                the run controller: all components of a run, one after the other
  Private/Diagnostics        health, logs, diagnostics export
  Recipes/                   scripts executed ON the servers (Vault, WindowsComponent, LinuxComponent, ActiveDirectory)
  Controllers/               Invoke-PASRunController.ps1, entry script of the detached controller process
PASeasyInstall/Desktop/      desktop window; calls only the public commands in Backend/Backend.Contract.ps1
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
| `run.json` | status, controller PID and start time, current component, message |
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

## Known debt

- What was tested, what is experimental and what comes later is in [STATUS.md](STATUS.md).
- The PSM service restart after the last reboot (`Start-PASeasyPsmStoppedService`) was tried on a server but
  never triggered inside a complete run: in the later runs the PSM service stayed up by itself.
- A retried CPM registration uses the vendor's upgrade mode when the credential file of an earlier attempt names
  the CPM user (`Get-PASeasyCpmRegistrationMode` in `Recipes/WindowsComponent/Vendor.ps1`). One state cannot be
  repaired that way and is reported instead (see STATUS.md 3.5).
- Anti-tamper ACL code (owner/ACL checks of staging folders) is duplicated in about 8 places; not consolidated.
- PTA shell branches still exist in `Recipes/LinuxComponent/Task.sh` and `Verify.sh`, although PTA was removed
  from the PowerShell code.
- Install paths are hard-coded (`C:\` drive, `C:\ProgramData\...`, `/opt/paeasyinstall`).
- Vault recipes are read from the module at resume, not from a per-run copy: editing them blocks the resume of
  Vault targets (digest mismatch).
- On-disk and remote names still say `PAExec` / `paeasyinstall` (stage root, task path, lock folders, endpoint name).
- Error-prefix strings `PAExecUnknown:` / `PAExecLocked:` are used for control flow instead of typed errors.
- Much of `Private/` is dense one-line code from 1.0; only new code follows "one statement per line".
