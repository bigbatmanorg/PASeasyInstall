# 01 — Product Scope and Success Criteria

## Mission

PASeasyInstall is an operator-controlled, local-first, PowerShell-native installer for a complete CyberArk PAM Self-Hosted **lab** and progressively qualified supported deployments. Select components, place them on hosts, create/use AD if desired, supply media and credentials, inspect a plan, install, resume safely, verify, inspect logs and export evidence. One operator, one environment at a time is the default mental model.

## Three primary flows

### A. Fresh environment

Wizard or JSON config → select topology/template → hosts → optional AD → media → security mode → credentials → read-only preflight → frozen plan → explicit approval → deployment controller → phase/step progress → independent verification → report → environment overview.

### B. Add components to an existing environment

Specify an existing Vault and already-installed component instances → verify their identity/health and relevant prerequisites → produce a plan that creates *only* requested new instances → register/integrate using serialized authenticated operations → verify. Do not reuse the 'fresh DR plus primary' recipe to add DR to a running Vault: that is a different qualified lifecycle recipe.

### C. Resume after failure

Open an existing run via GUI/CLI → inspect real on-host state and remote attempt identity → supply fresh secrets if needed → either continue verified pending steps, reconcile known partial state with recipe-specific behavior, or show `NeedsIntervention`. Never blindly launch a second copy of a potentially running vendor installer.

## Components in target full-lab scope

Primary Vault; DR Vault; PVWA; CPM; PSM; Linux PSMP; Linux PTA; optional AD DS forest creation or existing domain integration, eligible Windows domain joins, optional lab OU/accounts. Support any subset whose dependencies can be satisfied by selected or existing components. Registration and functionality must be tested, not installation alone.

## Topology policy

- `Recommended`: qualified dedicated host placement; Vault and DR isolated and not domain joined.
- `CompactLab`: only explicitly tested co-location combinations; per-host prerequisite merging; warn about shared hardening/service interference.
- `CustomLab`: planned deviations available through explicit overrides, but cannot sidestep unknown state, secret protection, leases, or product-internal resource serialization.
- An environment has named host identities and named component instances: multiple instances of a type are representable, even if a recipe variant initially supports one.
- Deployment options for Distributed Vault, cluster, alternative PSM modes, upgrades/repairs are **reserved extension points**, not implemented features or synonyms for existing DR.

## Product boundaries

**Included:** plan, deploy, verified installation, handoff credentials, media staging, rollback guidance (not universal rollback), recovery, network/DNS/OS prerequisites, component-specific basic health, bounded remote log tail, evidence/report, optional lab-only security deviations.

**Excluded:** fleet orchestration, multi-tenancy/roles, central database, web backend, generalized workflow engine, reusable plugin ecosystem, disaster-recovery failover orchestration, PAM policy administration, credential reconciliation management, lifecycle upgrades, self-service production rollback, automated Proxmox VM provisioning (test harness may provision/restore VMs).

## Definition of a successful deployment

Separate the following states:
1. `Installed`: package and expected service/file evidence present.
2. `Configured`: registration, certificate binding, Vault connectivity, domains and policies verified.
3. `Operational`: component-specific functional check passed using a dedicated controlled test resource where feasible.
4. `SecurityVerified`: selected baseline was checked; every skipped/mismatched control is explicitly reported.

`Installed` without `Operational` must never appear as an overall success. Checks requiring unavailable test resources are `NotTested`, not `Passed`. The final run status may be `CompletedWithUnverifiedChecks`, not `Success` unless its configured acceptance policy is met.

## Product quality constraints

- Headless import, plan, deployment, recovery, diagnostics with **no NativeHTMLKit installation**.
- Windows PowerShell 5.1 is the initial qualified controller edition; PowerShell 7 support must be separately validated, not assumed.
- Native UI uses only public NativeHTMLKit PowerShell SDK/UI APIs; no changes to Core required.
- No Python/Ansible runtimes, vendor binaries, licenses or secret material shipped in the Gallery module.
- Every state-changing operation has a bounded timeout, precondition, intent, durable attempt record, outcome reconciliation and independent verification.
- One controlling user/identity; no multi-user scheduling or permission service.

## Acceptance statements

- A complete configured lab can be deployed using only a JSON file and one PowerShell command once all recipes have qualified.
- GUI and CLI generate byte-equivalent canonical plans from identical input (excluding presentation metadata).
- Kill a controller at dispatch, during installation, verification or reboot: resume does not repeat a destructive step unless it is proven safe or explicitly reconciled by a recipe.
- Vault registration operations never overlap **within this application**, including GUI monitoring and a second CLI invocation.
- Every visible health status has a timestamp, source and confidence/verification level.
- Operators can disable supported TLS/hardening choices for disposable labs without disabling journaling, lock enforcement, redaction or safe recovery.
