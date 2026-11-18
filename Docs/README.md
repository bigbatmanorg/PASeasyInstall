# PASeasyInstall — Architecture & Development Specification

**Status:** Design baseline for implementation, 16 November 2026. **Not an implemented release.**

## Decision in one page

Build **one PowerShell module named `PASeasyInstall`**. Incorporate and refactor the useful source code from the current Vault/DR installer and its included execution library directly inside the module. It must never import, install, or invoke a standalone PSSteps module at runtime. The only GUI is **NativeHTMLKit PowerShell SDK + NativeHTMLKit.UI**, loaded on demand. CLI installation must work without any GUI components installed.

The product has four inner units: **configuration/planning, recipe catalog, execution/recovery, and verification/diagnostics**. These are normal PowerShell files loaded by one `.psm1`, not separate products or package dependencies. The GUI is another caller of the same public functions.

**Key simplification:** the first qualified release runs **one mutating step at a time**, even when deploying to many hosts. It is an intentional performance tradeoff: dependable recovery, correct Vault-account serialization, and comprehensible behavior are more valuable than early parallelism. Only one active deployment per environment; read-only local/remote monitoring can run separately, but authenticated Vault probes use the same durable gate. Add parallelism only after full-lab qualification and demonstrated need; the plan already records host and resource identities.

**Development strategy:** requalify all workflows from zero. Preserve the 2026-11-14 Vault/DR test evidence as a behavioral reference, not as certification of rewritten code. No broad production-support claims until actual compatibility and hardening tests support them.

## Documents

| File | Purpose |
|---|---|
| `01_PRODUCT_SCOPE.md` | Supported journeys, precise scope and boundaries |
| `02_ARCHITECTURE.md` | One-module architecture, process topology, component recipe contracts |
| `03_EXECUTION_RECOVERY.md` | Step state machine, durable attempts, interrupted execution, locks and persisted state |
| `04_COMPONENT_RECIPES.md` | Vault, DR, PVWA, CPM, PSM, PSMP, PTA, Active Directory design and verification |
| `05_CONFIG_CLI.md` | JSON schema, PowerShell commands, noninteractive operation |
| `06_SECURITY.md` | Credentials, TLS, secure defaults, explicit lab overrides, hardening constraints |
| `07_GUI_MONITORING.md` | NativeHTMLKit wizard, live installation view, post-install diagnostics |
| `08_QUALIFICATION_ROADMAP.md` | Ordered implementation tasks, failure-injection and release gates |
| `09_SOURCE_REVIEW.md` | Findings and exact reference paths in the 11 uploaded archives |
| `10_ARCHITECTURE_DECISIONS.md` | Locked decisions, alternatives rejected and explicit reassessment triggers |
| `schema/deployment.schema.json` | Example v1 deployment configuration contract (design draft) |
| `examples/full-lab.json` | Illustrative, NONEXECUTABLE example; no credentials |
| `examples/vault-only.json` | Illustrative, NONEXECUTABLE example; no credentials |

The Markdown is intentionally implementation-facing: definitions of done, state transitions, command names, errors, and ownership boundaries are included. Examples and schema are proposed contracts, **not functional files until corresponding code is implemented**.

## Phase-0 development kickoff

1. Create `docs/architecture/` in PASeasyInstall and place this pack there. Designate this as the sole architecture authority; archive the old UI4ME-/two-target-only design as historical.
2. Write characterization tests for current Vault/DR behavior and remote attempt recovery. Treat source extraction as migration, not a dependency link.
3. Refactor into one module with tests passing even when the old standalone execution library is completely absent.
4. Implement the global plan and step execution journal; verify CLI-only before writing the GUI.
5. Build the NativeHTMLKit GUI as an optional frontend. Then add/qualify one recipe at a time.

## Release boundary

A component is either `Qualified` for a specific version/OS/topology/security profile, `Experimental` (lab, explicit override), or `NotImplemented`. The UI/CLI must never quietly turn an unqualified combination into a supported one. A plan may describe future variants but must reject execution of those variants.

**Source basis:** User-provided PASeasyInstall, NativeHTMLKit SDK/UI, six vendor Ansible role archives, and the two admin-center references; see `09_SOURCE_REVIEW.md`. External Microsoft/CyberArk links appear there. Source material was inspected; no live VMs or vendor installers were executed as part of writing this specification.
