# 02 — Architecture

## Single-module structure

```text
PASeasyInstall/
  PASeasyInstall/
    PASeasyInstall.psd1
    PASeasyInstall.psm1
    Public/                # 10-12 small exported functions
    Private/
      Config.ps1           # Read, normalize, validate, freeze
      Plan.ps1             # Explicit dependency graph, compatibility
      State.ps1            # Atomic snapshots, event journal, run read
      Run.ps1              # Scheduler and controller lifecycle
      RemoteWindows.ps1    # WinRM, Task Scheduler, boot check
      RemoteLinux.ps1      # SSH, Linux job integration, boot check
      Media.ps1            # Licensed package discovery, hashes, staging
      Secrets.ps1          # Ephemeral credential material, cleanup
      Gates.ps1            # Environment, host and Vault operation leases
      Verify.ps1           # Independent checks and evidence
      Diagnostics.ps1      # Services, bounded logs, health
    Recipes/
      Vault/               # Static recipe registration; ordinary .ps1 files
      DRVault/
      PVWA/
      CPM/
      PSM/
      PSMP/
      PTA/
      AD/
    UI/                    # Optional UI, never dot-sourced by CLI import
      Start.ps1
      Wizard.ps1
      Progress.ps1
      Overview.ps1
      theme.css
    Data/
      log-paths.json
      compatibility.json
  Tests/
  Examples/
  Docs/
```

All files belong to one `PASeasyInstall` module. No nested PSSteps `.psm1`; no copying a separate repo at build/deploy time. Original provenance/license text accompanies adapted code as required.

## Runtime

```text
User  ─── PowerShell CLI ─┐
                         ├─> Public PASeasyInstall commands
User ─── NativeHTMLKit UI ┘          │
                                     ├─ Config + Plan (read-only until approved)
                                     ├─ Deploy controller process (one per env)
                                     │    ├─ private step engine + state writer
                                     │    ├─ remote Windows/SSH adapters
                                     │    ├─ credential handoff
                                     │    └─ Vault session gate
                                     └─ Verify / Diagnostics

Controller stores JSON run state -> GUI/CLI read snapshots and logs.
Remote staged attempts survive WinRM/SSH disconnection.
```

### Processes

- **UI process:** no vendor install runs inside a NativeHTMLKit event callback. Background UI tasks read JSON snapshots or bounded diagnostic results; UI can close freely.
- **Controller process:** owns the run, writes its state and executes one mutating step at a time. Launch and crash behavior must be qualified independent of GUI lifecycle. For interactive runs use a detached same-identity child process rather than a UI-child job; for unattended runs support a pre-provisioned Scheduled Task identity with a tested secret provider. Do not claim logoff resilience until that mode is tested.
- **Target attempt:** short remote calls may use PowerShell/SSH; long installs, hardening and reboot-sensitive operations execute via persistent Windows Scheduled Tasks or Linux systemd-managed attempts. The remote task records its attempt ID and result. Only the controller decides advancement.

## Execution model

**Initial release uses a single global queue, not per-host workers or a parallel scheduler.** Planner performs topological sort on an explicit set of nodes. At each iteration, the controller chooses one ready node, probes current state, runs/reconciles, independently verifies, commits evidence, then proceeds. This makes cross-component Vault session conflicts and co-located-host operations easier to reason about.

Nodes still carry `HostId` and `ResourceKeys` so later limited cross-host parallelism can be implemented without changing recipe contracts. Do not implement that parallelism until there is measurable need and failure-injection coverage.

## Two data models only

1. **Desired deployment** (operator editable, JSON): topology/hosts, component instances/variants, AD, media roots, security policies, secret references.
2. **Frozen run plan** (engine generated, immutable): resolved host identities, component versions, hashes, explicit dependencies, node IDs, script fingerprints, security deviations, supported/unsupported markers. Hash it and make run resumption validate its identity.

Run state + events are execution *records*, not another domain model. No inventory `.psd1` intermediate or duplicate source-of-truth profile files are necessary.

## Static recipe contract

A recipe is code with three required responsibilities and optional stages:

- `Get-RecipePlan($context)`: returns a list of typed **plan nodes** and compatibility metadata; no changes to targets.
- `Test-RecipeState($node,$context)`: read-only, returns `Satisfied | Unsatisfied | Unknown` and structured evidence.
- `Invoke-RecipeNode($node,$context)`: executes only this node; remote long-running work goes through common launcher.
- `Resolve-RecipeAttempt($node,$attempt,$context)`: reconcile an interrupted attempt without automatically repeating irreversible work.
- `Test-RecipeHealth($instance,$context)`: independent verification for installed/configured/operational state.

These names are internal contract concepts, not exported commands. Prefer simple private functions and static tables mapping `Type/Variant` to function names. Do not build dynamic module discovery or an installer DSL.

### Node schema

```json
{
  "id": "cpm01.register",
  "componentId": "cpm01",
  "hostId": "pam01",
  "stage": "Register",
  "dependsOn": ["cpm01.install", "vault01.health"],
  "resources": ["host:pam01", "vault-session:main-vault"],
  "operation": "CpmRegister",
  "mode": "DetachedWindows",
  "retryPolicy": "ReconcileOnly",
  "timeoutSeconds": 3600,
  "verificationId": "CpmVaultRegistration"
}
```

**No plaintext secrets or arbitrary scriptbody** in a plan. Operations resolve to local, reviewed implementation functions and explicitly declared inputs. Node, recipe and media hashes are frozen to detect drift. A run pins the installed module version and compatible recipe implementation; an upgrade/uninstall cannot silently replace active-run behavior. Resume under a different module version needs proven compatibility or the preserved version.

## Host-level prerequisite aggregation

Before nodes are generated, collect shared host prerequisites (IIS/.NET/reboots/firewall/certificates/RDS/domain join). Deduplicate them. Co-located components cannot each independently reset the same IIS settings, account policy or hardening configuration. If their requirements conflict, reject the combination or label as unqualified lab experiment; never resolve it silently.

## Module and runtime support

- Windows PowerShell 5.1 for the qualified Windows controller. `pwsh` 7 on Windows may be supported after execution, DPAPI, remoting and GUI gates pass.
- Windows remoting uses native WSMan; Linux targets use SSH for shell/install commands from PowerShell and systemd for durable job state, when available.
- Linux targets need not have PowerShell installed: "pure PowerShell" applies to the controller/application; vendor shell scripts on Linux are permitted execution payloads.
- NativeHTMLKit SDK/UI modules load **inside UI entry point only**; check pinned tested versions. Early UI releases require native-input tests and scoped CSS workarounds where necessary.

## Scope guardrails

No background server, no fleet database, no plugin provider system, no reusable generic PowerShell automation product, no hidden ability to execute arbitrary user-supplied scripts. Controlled recipes with clear source and tests are simpler and safer.
