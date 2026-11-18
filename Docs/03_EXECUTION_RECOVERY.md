> **Design notes.** This is internal design documentation, kept for contributors; parts of it describe plans
> and history rather than the current release. For user documentation see
> <https://bigbatmanorg.github.io/PASeasyInstall/>. PASeasyInstall is intended for building CyberArk PAM
> **labs**; production use is at your own risk. Not affiliated with or endorsed by CyberArk.

# 03 — Reliable Execution, State, Recovery and Locking

## Non-negotiable contract

An execution acknowledgement is **not** proof that installation succeeded. A process exit code of zero must be followed by independent postcondition checks. A lost connection must never be treated as evidence that the remote process stopped. Exact-once execution cannot be guaranteed in every crash window; the design guarantees **no blind repeated irreversible action** and records uncertain outcomes until reconciled.

Windows independent verifiers can explicitly use `VerifyMode='Detached'`. Each has
its own journaled attempt and typed Check result; authenticated checks additionally
require `VerifyRequiresVaultSession=$true` and acknowledged session closure. An
outstanding generation resumes under the same ID. Result consumption is committed
with its parent checkpoint; later completed-step revalidation creates a fresh check.
An acknowledged action is never replayed because only its check failed. Explicit
Retry cannot bypass an unconsumed check. Both check paths honor the declared timeout.
Authenticated steps cannot use skipping direct probes. Borrowed VaultSequence leases
remain owned by the parent; child completion never deletes the parent's claim.
Mechanism tests and synthetic killed-controller evidence are in
[durable-check qualification](Verification/durable-check-20261117/README.md).
Real PACLI recipe integration/authenticated recovery remains required.

## One global sequencer

At most one state-changing step executes per environment in the initial release. Read-only remote checks are allowed when they cannot disturb ongoing operations. If a check authenticates to Vault it must acquire the Vault session gate, even when initiated through the GUI. Every worker must act on a frozen plan and be prevented from creating a second run controller for the same environment.

## Step state machine

```text
Pending
   │
   ▼
Inspecting ──[current state satisfies postcondition]──> Satisfied
   │
   ├──[cannot inspect]──────────────────────────────────> Unknown
   ▼
Ready ──> AttemptRecorded ──> Dispatched ──> Running
                              │                │
                              └── timeout/lost connection ──> Unknown
                                               │
                                               ▼
                                           Verifying
                                               │
                         ┌─────────────────────┴─────────────────────┐
                         ▼                                           ▼
                      Succeeded                                    Failed

Unknown/Failed -> Reconcile (inspect remote attempt + target) ->
    Succeeded | SafeToReexecute | NeedsIntervention | StillRunning
```

`Satisfied` means verified before execution; `Succeeded` means verified after execution. `Failed` is a known terminal error; it may have left partial changes. `Unknown` means outcome cannot be proved. `NeedsIntervention` blocks the dependent part of the run. `NotTested` applies to optional functional checks, not executable step state.

## Attempt protocol

1. Generate immutable `AttemptId` (GUID) and record it **durably before any remote dispatch**.
2. Stage an allowlisted script/payload, canonical arguments, nonsecret hashes, expected machine/host identity and short-lived secret references under a restrictive remote directory.
3. Record remote staged metadata before launch. Verify staged hash and ownership.
4. Launch a persistent remote attempt. The remote runner atomically writes `Started`, periodic heartbeat if meaningful, `Ended` and `ExitCode`/bounded outputs. An attempt cannot be recreated with the same identity and a different payload.
5. Controller queries attempt state; on success it runs a separate read-only verifier; on failure it reports the vendor result and the concrete recovery recommendation.
6. On controller crash/reboot, inspect the target for the **same attempt ID**. If Running, reattach; if exited, verify; if absent, determine whether staging/launch could have occurred. `Unknown` stays blocked if there is no proof it never executed.
7. Clean up only once the attempt has been reconciled; retain bounded diagnostic evidence and references.

### Windows strategy

- Fast read-only probes: native `Invoke-Command`/CIM/WinRM with explicit timeouts.
- Long installs/hardening: Windows Scheduled Task with a unique name, defined run identity, exit-status sidecar, redirected bounded logs and protected staging folder. Keep task creation and execution idempotent against AttemptId; startup of an already existing attempt never restarts it.
- Reboots: record pre-reboot boot identity, request once, observe loss/return of transport, confirm boot identity changed, then verify intended role/service state; don't keep issuing reboot commands on timeout.
- Vault hardening may disable ordinary WinRM. The recipe must explicitly provide a qualified management/recovery channel (restricted lab exception or documented out-of-band action). Do not silently keep vendor-unapproved remote management exceptions.
- Properly terminate controller-local subprocesses on controller exit, but **do not kill remote detached vendor installers** when the GUI/controller dies. The existing repo's Windows Job Object regression is a concrete test case.

### Linux strategy

- SSH transport from PowerShell (explicit host-key policy, no implicit `StrictHostKeyChecking=no`).
- Short operations may use direct SSH; long installation uses `systemd-run`/persistent unit and files under a restricted attempt directory when OS and privileges support it. No `nohup &` without durable status.
- If systemd unavailable, either use an explicitly qualified alternative or declare the target unsupported for remote durable installation.
- Store stdout/stderr separately, cap retrieval, verify PID/unit and boot identity on recovery, and avoid full OS upgrades as an unrequested prerequisite.

## State store

Per-run root under a protected data directory (default `%LOCALAPPDATA%\PASeasyInstall\` for interactive controller; explicit configured root for unattended identity):

```text
Environments/<environment-id>/environment.json
Runs/<run-id>/config.snapshot.json    # no plaintext secrets
Runs/<run-id>/plan.json               # frozen plan + hashes
Runs/<run-id>/state.json              # authoritative atomic snapshot
Runs/<run-id>/events.jsonl            # append-only bounded structured diagnostics
Runs/<run-id>/evidence.json           # nonsecret explicit evidence objects
Runs/<run-id>/logs/                  # redacted controller logs, manifest
Secrets/                             # outside export bundles, owner ACL
```

The controller is the **single writer** to each run's state. State writes use temp-file-on-same-volume, flush, atomic replace/rename, monotonic sequence and schema version. UI and CLI only read immutable snapshots. A torn last JSONL line is ignored. Remote attempt state is external evidence consulted during reconciliation, not a second host-side scheduler.

Pin a module version and execution-script digest for the duration of the run. Installing/upgrading a different Gallery release does not mutate a running plan; if its original execution code is unavailable on resume, report `PLAN_DRIFT` and require a controlled migration rather than loading a different implementation silently.

State serializes **allowlisted** values only (status, attempt ID, timestamps, hashes, codes, sanitized messages, recognized evidence fields). Never persist arbitrary script `Data` or full remote-return objects. Vendor logs are kept separately and treated as sensitive/untrusted content, with export policy.

## Immutable plan and changes after failure

- A run freezes canonical config, source/recipe versions and media SHA-256.
- Resume with the same plan skips or revalidates completed nodes; no silent rescheduling from an edited JSON config.
- If DNS, network, service or credentials change externally, **reprobe using the frozen plan**. Fresh secrets can be injected without modifying frozen nonsecret config.
- A changed target IP, component version, media hash, server placement or hardening policy requires **Plan Revision**: create a new versioned run plan, explicitly record differences, revalidate affected nodes and maintain linkage to original attempts. For first release, limit revision to a small set of documented safe fields; unsafe mutations require a new deployment and, where appropriate, a clean snapshot.

## Locks and Vault sessions

**One environment gate:** one mutating deployment controller per environment, enforced by both OS exclusive lock and persistent ownership metadata. On crash, the OS lock may disappear but unresolved remote attempts remain in `state.json`; reacquisition must reconcile before scheduling any next step.

**Host gate:** useful against two environments sharing a physical target. Identity includes inventory host ID, canonical DNS/IP and a verified remote fingerprint where available; reject ambiguous duplicate aliasing. Single global sequencer already prevents two steps in one run from colliding on a shared host.

**Vault session gate:** one authenticated operation at a time per Vault environment in the initial release, even across different Vault accounts. Covers complete login / register / verify / logout scope for PACLI, vendor registration tools and REST. GUI health probes must request the gate or return a cached/stale reading when unavailable. A remote registration action that may still be active keeps the gate unresolved until reconciled; no arbitrary TTL-based release.

Use deterministic lock ordering (environment > host > Vault gate); never start long-running callbacks with a lock not declared in the plan. The gate protects application-owned identities only; external users can still invalidate a session. Show this limitation in diagnostics.

## Failure matrix (mandatory acceptance)

| Fault | Expected behavior |
|---|---|
| GUI closed | Controller and detached target task continue; GUI reopening reattaches |
| Terminal/SSH disconnect | Remote detached task continues; CLI reconnects to run state |
| Controller killed before remote launch | State/attempt reconciled; launch only if proven not started |
| Controller killed after launch | Original attempt discovered, not duplicated |
| WinRM blocked by hardening | Qualified recovery pathway; no repeated hardening blind |
| Remote reboot while waiting | Observe new boot ID; recheck desired state |
| 2nd CLI/GUI requests Vault login | Queues/refuses until active Vault operation exits |
| Controller and target unreachable | Mark `Unknown`; do not declare failure/success, do not retry |
| Power outage during state write | Atomic snapshot remains readable; remote attempts reconciled |
| Script changed after run creation | Resume refuses changed execution payload |
| Invalid/expired credential | Safe `Blocked`; fresh secret supplied on resume, no edit to frozen plan |
| Vendor returned 0 but service broken | Step verification fails; no false success |
| Windows Update reverses hardening control | Explicit security verification failure; do not autorerun hardening |
| Operator changes target/media mid-run | Plan-drift error; revised plan or new run required |

## Cancellation policy

No arbitrary kill-install button. Provide `PauseAfterStep` (stop scheduling next step) and `RequestStop` (same semantics; active noninterruptible attempt completes or becomes observable). Emergency termination has an explicit warning and produces `Unknown` where necessary. `Resume` never means `restart all steps`.

## Controller-wide coordination initialization

Run `Initialize-PASeasyController` once in an elevated Windows PowerShell5.1 session.
An elevated first deployment can initialize automatically. Ordinary CLI/GUI operators
then share the protected `%ProgramData%\PASeasyInstall-Coordination` boundary,
regardless of their `DataRoot`. This is one Windows controller's cross-process
coordination, not a distributed lease between independent controller computers.
All deployments for an environment must use the same controller.

Each canonical resolved Vault/host IP has a machine-wide named mutex and a persistent
creator-owned claim. Different DNS aliases resolving to one address cannot bypass
host co-location/dedicated-role policy. A killed controller releases the kernel mutex
but retains its claim: a different run cannot start uncertain work. Resume the same
run and same state root to reconcile its immutable remote attempts. Only successful
completion removes claims automatically. Failed/unknown claims remain deliberately
blocked for target reconciliation; never delete them simply to rerun an installer.
Cross-user positive qualification remains pending; cross-process/differentDataRoot/
killed-controller claims are covered by Windows runtime tests.

Windows detached inputs now travel in a SecureString over PSRP, then become target
LocalMachine DPAPI ciphertext `inputs.dpapi`, bound to the attempt ID as entropy.
There is no plaintext controller JSON staging file for these inputs. The runner
requires encrypted input, decrypts in memory, deletes it before task execution,
and removes it again in cleanup. SYSTEM/domain-task identities still depend on
restricted staging ACLs: machine DPAPI is not an authorization boundary against
local administrators. Linux attempts retain their separately documented restricted
transient native input lifecycle. Live SYSTEM proof for this new format is pending.

Vault RDP allowance now defaults false. Only the scoped Lab override `Vault.AllowRDP`
enables it and appears as a configuration security deviation. The controller-scoped
management endpoint remains necessary for verified resume/reboot operations.
