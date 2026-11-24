# PASeasyInstall 2.0: design in one page

For someone new to the code. Lab tool; see the warning in the README. The user documentation is the site
(`site-src/`); what was tested in the lab is in [VALIDATION.md](VALIDATION.md).

## Layout

```text
PASeasyInstall/              core module, no dependencies
  Public/                    26 commands, one file each (the whole command line surface; FunctionsToExport)
  Private/Common             JSON, paths, secrets (DPAPI hand-off), small helpers
  Private/Config             configuration (read, validate, compose), credentials, plan, workflow generator,
                             domain GPOs, gateway registration, PTA trust
  Private/Media              find and select installer media
  Private/Engine             runs ONE workflow on ONE server: transports, step attempts, journal, locks
  Private/Run                the run controller: all components of a run; the servers at the same time (Lanes.ps1)
  Private/Diagnostics        health, logs, diagnostics export
  Recipes/                   scripts executed ON the servers: Vault, WindowsComponent (PVWA, CPM, PSM),
                             LinuxComponent (PSMP), Html5Gateway, Pta, ActiveDirectory
  Controllers/               Invoke-PASRunController.ps1, entry script of the detached controller process
  Data/LogSources.json       the product logs Get-PASRunLog may read
  Desktop/                   the window (WPF); calls only the public commands in Backend/Backend.Contract.ps1
Tools/Build-CommandPages.py  renders site-src/commands/*.md (except index.md) from the comment-based help
```

Names: a **run** is one installation (one controller process, one run id). A **component** is one item of the plan
(vault, dr, pvwa01, ...). A **target** is one engine workflow on one server; a component is usually one target,
the Vault with DR is four (`primary`, `dr`, `primary_final`, `dr_final`). Integrations and domain steps are
targets of their own (`join-<server>`, `register-<gateway>`, `trust-<pta>`, `policy-*`). A **step** is one entry
of a workflow. An **attempt** is one execution of a step on the server.

## What happens when you run `Install-PASLab`

1. **Configuration.** A configuration hashtable, from a file or `New-PASLabConfiguration`. The single-component
   commands (`Install-PASVault`, `Install-PASPVWA`, ...) build the same shape. No password is in it.
2. **Validation.** `Test-PASConfiguration` checks structure, topology rules and media. `-WhatIf`/`-PlanOnly` stop here.
3. **Plan.** `Get-PASDeploymentPlan` orders the components (AD, Vault, DR, PVWA, CPM, PSM, PSMP, HTML5GW, PTA)
   and computes `ConfigDigest` and `MediaDigest` (SHA-256 of each installer).
4. **Credentials.** After you confirm, missing accounts and passwords are asked for (`Resolve-PASInstallCredential`).
5. **Detached run controller.** `Start-PASDeployment` writes the run folder, hands the credentials to a new
   `powershell.exe` through a DPAPI envelope file, and returns the run id. The child runs
   `Controllers/Invoke-PASRunController.ps1`, deletes the envelope after reading it, and takes the run lock.
6. **Lanes or sequence.** `execution.mode = Parallel` (the default of new configurations) runs the servers side
   by side (`Invoke-PASRunLanes`, below). `Sequential`, or no key, runs the forest, the joins, the Vault
   sequence, then every component in plan order, then gateway registration and PTA trust.
7. **Per-target workflow.** For each component the controller writes its workflow and inventory, then calls
   `Invoke-PASWorkflow` (the engine). The engine takes the target lock on the server and walks the steps.
8. **Step attempt.** A detached step is staged on the server as an attempt folder and started as a **scheduled
   task** (Windows) or a **systemd unit** (Linux). The controller only observes it. If the controller dies, the
   attempt continues and is found again by its id.
9. **Verify.** Every step has a separate, read-only verify script. Success of the installer process alone is
   never accepted.
10. **Journal.** Before dispatch and after every outcome the engine writes the step state to `state.json` and an
    event to `events.jsonl`. `Get-PASRun` and the window only read these files.
11. **Domain GPOs** (a new forest only) run last, and only when everything before succeeded.

## Files a run leaves behind

**Controller**, `%LOCALAPPDATA%\PASeasyInstall\Runs\<run id>\` (or `$env:PAS_EASY_DATA_ROOT`):

| File | Content |
|---|---|
| `run.json` | status, controller PID and start time, current component (several in a parallel run), message |
| `config.json`, `plan.json` | what the run installs; frozen at start |
| `events.jsonl` | events of the run controller |
| `controller.lock` | the run lock (empty file, held open by the controller) |
| `credentials-<guid>.json` | DPAPI envelope; exists only until the controller has read it |
| `Payloads\<target>\` | frozen recipe copies, `Workflows\<target>.psd1`, `inventory.psd1` |
| `Payloads\VaultFrozen\` | frozen copy of `Recipes/Vault` for the whole run, with `freeze.json` (SHA-256 of every file) |
| `vault-inventory.psd1`, `join-<server>-inventory.psd1`, `trust-<pta>-inventory.psd1`, ... | inventories of the Vault sequence, domain joins and integrations |
| `<target>\state.json`, `<target>\events.jsonl` | journal and events of one engine target |
| `milestones\<name>.json` | published by Vault steps that another target waits for (`primary-keys`, `primary-ready`, `test-safe-created`) |
| `pvwa-trust-<pvwa>.cer` | PVWA certificate captured for pinning (Lab) |

Beside `Runs\`: `MediaCache\` (installers extracted from bundles) and `ssh\<environment>\` (controller SSH key).

**Windows target**, stage root `C:\ProgramData\PASeasyInstall` (components) or `C:\ProgramData\PAExec` (Vault):
`locks\<server id>\owner.txt` (target lock), `attempts\<attempt id>\` with `task.ps1`, `host.ps1`, `runner.ps1`,
`ownership.ps1`, `contract.txt`, optional `recovery.ps1`, `status.json`, `principal.json`, `stdout.log`;
scheduled task `\PAExec\PAExec-<attempt id>`; `media\<component>\installer.zip`; `components\<component>\`
(on the first PVWA server also `pta-trust-<pta name>.json`, the record of the PTA trust).

**Linux target**: `/opt/paeasyinstall/attempts/<attempt id>/` with `task.sh`, `runner.sh`, `unit.service`,
`contract.txt`, `status.json`, `stdout.log.tail`, `stderr.log.tail`; step inputs in
`/run/paeasyinstall/attempts/<attempt id>/inputs.json` (memory only); systemd unit `paeasy-<attempt id>.service`;
target lock `~/.paeasyinstall/locks/<server id>/owner`; `/opt/paeasyinstall/media/<component>/installer.zip`.

## The three locks (`Private/Engine/Locks.ps1`)

1. **Run lock**: `controller.lock`, an exclusive file handle of the controller process. It ends with the process.
2. **Target lock**: a folder on the server that names the run id. Released when the target succeeds. It is
   **kept when a run fails or is stopped**, so no other run touches a half-installed server; the same run takes it
   again on resume. Only `Stop-PASRun -ReleaseLocksAfterReset -CredentialMap` removes it, and only where the
   owner file names that run.
3. **Vault lock**: a named mutex on the controller (`Global\PASeasyInstall-Vault-<address>`). One authenticated
   Vault session at a time on this machine. Always released in `finally`, never kept after a failure, leaves no
   files. Default wait 180 s; a lane waits up to 4 h (its turn in the registration queue); `Test-PASHealth` 60 s.

A parallel run adds only what lives inside its controller process: the signals below and one short-lived mutex
of the run (`prepare-<run id>`, the same mutex helper) while lanes prepare shared files (SSH known-hosts, PVWA
certificate bundle). Nothing else coordinates runs.

## Servers at the same time (`Private/Run/Lanes.ps1`)

- **Lane**: the work of one server, in plan order. Each lane is a runspace of the controller process with its
  own copy of the module, so remoting sessions are not shared. The Primary Vault is one lane, its DR Vault
  another (`Invoke-PASVaultSequence -Part Primary | PrimaryTest | DR`: the Vault lane installs the Primary under
  the Vault lock, sets `Vault`, then creates the test safe; the DR workflow waits for the milestones
  `primary-keys`, `primary-ready` and `test-safe-created` by itself). The new forest is one lane. A component
  on the Vault server or the domain controller runs after that lane's own work. Components on the same server
  stay one after the other. One more lane, `integrations`, runs gateway registration and PTA trust.
- **Signals** (`ManualResetEvent`s, set once): `Domain` (forest installed), `Vault` (Primary installed,
  hardened and verified), `Cert:<pvwa>` (its step `certificate`), `PvwaRegistered` (the first PVWA finished
  `register`), `Registered:<id>` (a PVWA, CPM, PSM or PSMP finished `register`; PSM: its last pass, `register-pass3`), `Done:<id>` (every component,
  installed and verified), `Fail:<signal>` for every need, and `Cancel` (the lanes are taken down). A signal
  nothing in the run will produce (no forest, no Vault, no PVWA) is set from the start.
- **Gates** (`Get-PASLaneComponentGate`): `StartAfter` (before the component starts) and `VaultAfter` (before
  each step with `RequiresVaultSession`):
    - a component with `options.pvwaTrustFrom` (CPM, PSM, gateway, PTA on another server) starts after `Cert`
      of every PVWA;
    - every Vault step waits for `Vault`;
    - the first PVWA: nothing more. Other PVWAs: `PvwaRegistered`;
    - CPM: `PvwaRegistered` and `Registered` of every PVWA;
    - PSM, PSMP, others: `PvwaRegistered` and `Registered` of every CPM;
    - PTA: `Done` of every PVWA (its configuration names PVWA and signs in through it), `Registered` of every
      CPM, PSM and PSMP. PTA registers last: its vendor configuration holds the Vault for about three minutes,
      PSM still hardens after its registration, and gateway registration waits for PSM.

  Then the step takes the Vault lock, so the registrations run one at a time: the first PVWA, the other PVWAs,
  every CPM, then PSM/PSMP in arrival order, PTA last.
- **Plan check** (`Assert-PASLaneSignalPlan`), before anything is contacted: every awaited signal has exactly
  one producing lane; no component waits for one produced later in its own lane; the component graph is acyclic
  (checked per component, not per lane, so two PVWAs with CPMs are fine).
- **Stage order** (`Get-PASComponentStageNames` in `Private/Config/Planning.ps1`): PVWA `Certificate` first,
  then Extract, Prerequisites, Install, ConfigureTLS, Harden, Register, Verify. PSMP hardens before Register.
  CPM and PSM register before their hardening: CPM's hardening starts services that need the registration; for
  PSM the vendor's stage script reported the registration on a hardened server as failed. PTA: Extract,
  Prerequisites, Install, Register, Verify. The reasons are written next to the stage lists.
- **Integrations** (`Get-PASParallelFinalizationJobs`, `Invoke-PASParallelFinalizations`), one at a time in the
  `integrations` lane, each as soon as its needs are set: `GatewayRegistration` after `Done` of every PVWA,
  PSM, HTML5GW and PTA; `PtaTrust` after `Done` of every PVWA and PTA. Both also wait for everything else on the
  first PVWA server, because both change that server. A failed need skips only that integration
  (`IntegrationBlocked`). Gateway registration signs in to the Vault and takes its turn there like a lane. The
  wait limit (4 h) counts from the last progress.
- **A lane fails** (`Set-PASLaneFailed`): what the lane still owed will never come. `Registered:<id>` is only an
  order, so it is set and who waited for its turn goes on. Every other signal is a need: its `Fail:` handle is
  set and who waits for it gives up (`PASLaneStopped`, nothing dispatched). All other lanes work to the end, then
  the run ends Failed with the step that failed first, the other failed lanes and those not installed because
  of it. The domain GPOs are not applied after a failure.
- **Resume** leaves alone every lane whose targets this run already finished (`Test-PASLaneFinished`: every
  journal of the lane says Succeeded) and every integration it already finished (`Test-PASIntegrationFinished`).
  Their servers are not contacted again and what they owe the others is set from their journals (event
  `LanesSkipped`). The other lanes start again: their finished steps are only revalidated, read-only. So a retry
  of one failed step touches only that server and what waited for it.

## Resume, retry, stop

- **Resume** (`Resume-PASRun`): allowed for Failed, Unknown, Interrupted, LaunchFailed, Blocked. The controller
  refuses if `ConfigDigest` or `MediaDigest` changed. Module files may change (there is no source digest).
  The engine pins a digest of workflow + scripts + inventory per target: PVWA, CPM, PSM, PSMP, HTML5GW, PTA, AD
  and the integrations run from the frozen copies in `Payloads\<target>\`, the Vault targets from
  `Payloads\VaultFrozen\` (checked against its `freeze.json`). An update of the module does not change a started run.
  Succeeded steps are only revalidated (read-only). A step that was dispatched is reconciled by its attempt id,
  never started twice.
- **Retry**: a Failed or Unknown step is not repeated on resume. `-RetryStep <step>` or `<component>:<step>`
  names it; a name that matches no Failed/Unknown step is an error. When the action was acknowledged and only
  its verifier is unresolved (staging cut off), the retry repeats the verification only, and only when the old
  verifier is shown not to be running. `-RetryFailedPreflight` repeats a failed read-only Linux preflight.
- **Status**: `PAExecLocked:` in the error means Blocked, `PAExecUnknown:`/`Unknown:` means Unknown, else Failed.
  A run whose controller process is gone is reported as Interrupted (PID and start time must both match).
- **Stop** (`Stop-PASRun` → `Stop-PASDeployment`): refuses a live controller without `-Force`; with it, stops only
  the process that is provably this run's controller (PID and start time). Marks the run Abandoned and keeps the
  target locks, also with `-Force`: detached attempts may outlive the controller. `-ReleaseLocksAfterReset`
  (requires `-CredentialMap`) is for servers the operator reset or rebuilt: it signs in (re-authorising the
  controller key on a Linux server with the password), releases each lock whose owner is this run and leaves
  locks of other runs alone. Abandoned runs cannot be resumed. Nothing is uninstalled.

## Adding a component recipe

1. Put the on-server scripts in a folder under `Recipes/` (a task script with stages and a read-only verify
   script; follow `WindowsComponent/Task.ps1` + `Verify.ps1`, `LinuxComponent/Task.sh` + `Verify.sh`, or `Pta`).
2. Add the type and its stage names to `Get-PASComponentStageNames` and, if needed, to `New-PASComponentWorkflow`
   and `New-PASRuntimeInventory` (`Private/Config/Planning.ps1`). `Get-PASStageCatalog` follows automatically.
3. Add validation rules to `Test-PASConfiguration`, the run order to `Get-PASDeploymentPlan`, the media pattern
   to `Private/Media`, required credentials to `Get-PASInstallRequirement`, and its gate to
   `Get-PASLaneComponentGate` (what it waits for, which signals it publishes).
4. A public `Install-PAS<Type>.ps1` is optional (HTML5GW and PTA have none; they come through
   `New-PASLabConfiguration -Instances`). If you add one, keep it thin (build the configuration, call
   `Invoke-PASComponentInstall`), add it to `FunctionsToExport`, and regenerate the command pages. Add tests
   (`StageCatalog.Tests.ps1` picks the type up from its list; `Lanes.Tests.ps1` for the gate).

## A lab with a domain

Order of a run: forest (`ad`), one join workflow per server (`join-<server>`: DNS, join, restart, local
administrator for the PSM install account, verify), Vault, components, then the GPO phase
(`Private/Config/DomainPolicy.ps1`, recipe `Recipes/ActiveDirectory/Gpo-Task.ps1`): `policy-prepare-<server>` adds
the firewall rule for the management port, `policy-domain` uploads the vendor GPO backups to the domain controller,
imports and links them and moves the servers into `OU=<role>,OU=CyberArk`, `policy-<server>` refreshes the policy
and checks that the GPO is applied and the management rule is still in force. The vendor GPOs ignore local
firewall exceptions that name only a port; the rule therefore names the program (System) too. Vault servers
are never joined.

## HTML5 Gateway

Component type `HTML5GW`, recipe `Recipes/Html5Gateway` (`Task.sh`, `Verify.sh`: unpack, container engine,
`html5_console.sh install -l` and `run`, health page). `Invoke-PASGatewayRegistration` runs
`Register-Gateway.ps1` on the first PVWA server (target `register-<gateway id>`,
`Private/Config/GatewayRegistration.ps1`): PACLI retrieves `PVConfiguration.xml` from the Vault, the script adds
`PSMGatewayServers/PSMGatewayServer` and a `PSMGateway` reference to every PSM server, stores the file, reads it
back and restarts the PVWA application pool. PACLI runs from `C:\PASeasyInstallGateway`, a folder closed to
everybody but SYSTEM and the administrators (the PACLI helper refuses `C:\ProgramData`).

## PTA

Component type `PTA`, recipe `Recipes/Pta`. `Task.sh` stages: Extract, Prerequisites (sshpass, unzip, tar; the
CyberArk signing key, which the composer takes out of the PSMP package), Install (`pta_installer.sh`), then a
restart step of the engine, Register (hosts entries, the PVWA certificate into PTA's Java trust stores, SELinux
permissive for the vendor's `ptaAutomaticConfiguration.py`, ports in firewalld, restart of `appmgr`). The root
password of the server reaches the Register step as the run secret `PTARoot-<id>`, which `Invoke-PASRunLanes`
(or `Initialize-PASComponentRun`) takes from the server's account.

PTA registers in the Vault under its own host name, the name in its self-signed certificate, not the name of
the configuration. PVWA calls `https://<that name>/api/...` (System Health, PTA details). So
`Invoke-PASPtaTrust` runs `Trust-Pta.ps1` on the first PVWA server (target `trust-<pta id>`,
`Private/Config/PtaTrust.ps1`, Lab profile only): the certificate PTA presents goes into
`Cert:\LocalMachine\Root` (trusted on first use, logged as a deviation with subject and thumbprint), and every
DNS name of the certificate (CN and SAN; the configured name only when it names none) gets a hosts entry when it
does not resolve to the PTA address. `Trust-Verify.ps1` checks the trusted root and makes a real HTTPS request
to PTA under each of those names; a missing hosts entry fails there. When PVWA's
`ComponentsMonitoringDetails/PTA` call fails although PTA is counted in the Vault, `Test-PASHealth` reports
"PTA is registered in the Vault (x of y connected), but PVWA cannot reach it ...".

## Known debt

- What was tested and what is not proven is in [VALIDATION.md](VALIDATION.md). Only the Lab profile was
  qualified (15.0 and 15.2); the Secure profile is a legacy surface and was never run end to end, yet it is
  still the default of `-SecurityProfile`.
- The PSM service restart after the last reboot (`Start-PASeasyPsmStoppedService`) was tried on a server but
  never triggered inside a complete run: in the later runs the PSM service stayed up by itself.
- A retried CPM registration uses the vendor's upgrade mode when the credential file of an earlier attempt names
  the CPM user (`Get-PASeasyCpmRegistrationMode` in `Recipes/WindowsComponent/Vendor.ps1`). A state that mode
  cannot repair is reported instead.
- Transient vendor failures need an operator `-RetryStep`, by design. One exception: when the only error of the
  vendor's PSM hardening is that the Server service (LanmanServer) did not restart within its 30 seconds, the
  hardening is run again by itself, up to three times, 30 seconds apart (`Invoke-PASPsmVendorStage` in
  `Recipes/WindowsComponent/Psm.ps1`).
- Anti-tamper ACL code (owner/ACL checks of staging folders) is duplicated in about 8 places; not consolidated.
- Install paths are hard-coded (`C:\` drive, `C:\ProgramData\...`, `/opt/paeasyinstall`).
- On-disk and remote names still say `PAExec` / `paeasyinstall` (stage root, task path, lock folders, endpoint name).
- Error-prefix strings `PAExecUnknown:` / `PAExecLocked:` / `PASLaneStopped:` are used for control flow instead
  of typed errors.
- A few code comments still name the internal commands (`Start-/Resume-/Stop-PASDeployment`).
- Much of `Private/` is dense one-line code from 1.0; only new code follows "one statement per line".
