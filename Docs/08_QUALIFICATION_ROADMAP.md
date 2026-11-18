> **Design notes.** This is internal design documentation, kept for contributors; parts of it describe plans
> and history rather than the current release. For user documentation see
> <https://bigbatmanorg.github.io/PASeasyInstall/>. PASeasyInstall is intended for building CyberArk PAM
> **labs**; production use is at your own risk. Not affiliated with or endorsed by CyberArk.

# 08 — Implementation Plan, Priorities and Release Gates

## Execution approach

One product repository. The original imported code is inspected and copied as **internal source** where useful. Remove its standalone module entry points and unused generic adapters. Source changes in PASeasyInstall no longer require synchronizing another repository. No separate engineering framework, no speculative compatibility layer.

## Phases and exit criteria

| Phase | Deliverable | Required passing gate |
|---|---|---|
| **0. Behavioral baseline** | Catalogue original Vault/DR steps, artifacts, execution semantics, licenses, faults | Automated baseline tests and reproducing original 22-step/49-step plans; documented source equivalence before refactor |
| **1. One module and core runtime** | Single PSD1/PSM1, typed config, local file state, one-step sequencer, Windows detached attempts, environment/Vault gate | No imports/dependencies on old standalone engine; synthetic crash tests at all attempt boundaries; CLI-only module import; no secret persistence |
| **2. Requalify Vault + DR** | `Vault Standalone`, `PrimaryWithDR`, media management, hardening verification, secure/lab behavior | Clean-snapshot Windows Server 2022 v15.0.0.76 primary and primary+DR pass; no double dispatch; test-Safe replication where selected; reboot/hardening tests |
| **3. CLI and NativeHTMLKit GUI** | Public commands, Gallery-quality manifest, wizard/progress/monitoring UI | Plan parity CLI/UI; GUI close/reopen; native mouse/keyboard/accessibility/1024×768/scaling tests; UI-free import and deploy |
| **4. AD** | Create forest, use existing forest, eligible member joins, optional lab identities | Fresh DC install/reboot/verify, AD-only operation, failed promotion recovery, join test; Vault remains workgroup |
| **5. Windows PAM components** | PVWA, CPM, PSM recipes with registration and functional checks | Each individual component on clean VM, on existing Vault, during recovery; no overlapping Vault sessions; PSM no leftover plaintext autologon |
| **6. Linux PAM components** | Durable Linux job runner, PSMP, PTA | RHEL-target supported-version checks, SSH/reboot/recovery, vendor registration, operational gateway/PTA tests, SELinux check and restoration |
| **7. Full-lab integration** | Complete selected topology, component health dashboard, export/report | Whole deployment with one click, no manual script intervention, full independent checks; interruption injected at key phases; compact co-location tested only if enabled |
| **8. Release** | Signed/versioned Gallery module, docs/examples, reproducible evidence | `Test-ModuleManifest`, ScriptAnalyzer, Pester, clean-machine `Install-Module`, NativeHTMLKit optional install, Windows PS5.1 qualification and release notes |

**Do not skip Phase 2** because the old lab was qualified: incorporated/refactored execution code must be rerun in the real lab. A passing unit test suite does not establish vendor installer correctness.

## Test layers

1. **Static/unit:** PS5.1 AST parsing, manifest/export list, strict config schema, topology compatibility, plan canonicalization, media hashing, zip traversal, state writes, secret filtering, lock ownership.
2. **Adapter simulation:** Fake Windows/SSH target processes, remote attempt folder/status, boot IDs, runner interruption, lost WinRM, dropped stdout, corrupt state, tampered hashes.
3. **VM integration:** Real Windows Server 2022/target Linux machine, WinRM/SSH, Task Scheduler/systemd, force-terminate controller, process and target reboot; confirm no duplicate vendor command.
4. **Vendor installation:** Actual licensed CyberArk v15 media for each component; verify configuration and health with independent methods, no transitive reliance on install log success strings.
5. **Native GUI:** Real desktop acceptance on Windows PS5.1 and qualified NativeHTMLKit packages, plus headless SDK tests where available.
6. **Security:** benign synthetic passwords seeded into test environment; exhaustive local/remote reports and command-line traces scanned; TLS override matrix; policy and dangerous-file-write review.
7. **Release:** clean install from built module; no clone/source tree, no Ansible/PSSteps/Python required, GUI optional.

## Mandatory destructive/interruption matrix

| Scenario | Success criterion |
|---|---|
| Kill controller before/after staging, before/after dispatch, while running, after result, during verify | One remote attempt; state reconciliation correct; never blind reexecution |
| Kill GUI, reopen, recover controller reference | Install continues; precise run status shown |
| WinRM cut during Vault hardening | No uncontrolled retry, observable recovery state |
| Windows Update changes hardening control after vendor script | Verification reports failure/deviation and safe remediation |
| AD promotion reboot before controller returns | Promotion observed; no duplicate `Install-ADDSForest` invocation |
| Linux SSH connection lost during PSMP/PTA install | Existing remote unit reconciled; no duplicate installer |
| Two concurrent Vault auth/registration requests | One authenticated operation at a time within application; other queued or `VAULT_GATE_BUSY` |
| Two deployments referencing same host under different alias | Host identity collision recognized, one prevented |
| Mismatch media hash, plan recipe hash, host fingerprint | Refuse resume until reconciled with explicit approved plan revision/new run |
| Insecure lab override, then final audit | Deviation visible in preview, state and report, never silently passed |
| Missing test target for PSM/PSMP/CPM functional check | Clearly `NotTested`, not `Healthy`/`Operational` |
| UI asks to follow 1 GB rotating log | Bounded bytes/memory, correct rotate handling, no UI freeze |

## Verification artifacts per tested recipe

Store under nonsecret test evidence (not Gallery): test case ID; release/version/OS/build; media hash; configuration/policy hash; target VM identity and snapshot; step attempts IDs; independent logs with redaction; before/after service and network checks; operator security deviations; failure reason; output timestamp. Ensure secrets/key material excluded.

## Definition of Done (each recipe)

- Preflight exact versions and package hash; clean host install; existing-install detection.
- Vendor installation + config + registration; independent service/connectivity check; optional functional check or explicit `NotTested`.
- Secure mode + Lab override coverage relevant to the recipe.
- At least one injected disconnect and resumed attempt; known partial outcome never auto-repeats destructive operation.
- Bounded logs, no secret leakage, correct status and recovery guidance in CLI and GUI.
- Compatibility/support status documented as `Qualified`, `Experimental`, or `NotImplemented` with evidence reference.

## Definition of Done (whole application)

- One Gallery module; no external execution framework.
- CLI-only full selected deployment with no UI dependency.
- GUI full selected deployment with same results and history; close/reopen harmless.
- One-window console presents environment config, installation and operational overview.
- Exactly one controller per environment, host identity collision protection and Vault serialized login gate.
- Recovery handling demonstrated at real known failure points.
- Full-lab configuration with selected Windows/Linux and AD components passes the agreed functional matrix, or explicitly marks missing prerequisites as blockers without false completion.

## Risks to resolve early

1. How to deliver secrets reliably to a separately launched Windows controller **without** insecure command lines, under both interactive and unattended task identities.
2. Vault hardening versus post-hardening remote management without weakening vendor security defaults.
3. Vendor component automation paths compatible with v15 media and license/certificate configuration.
4. Linux durable runner and PTA SELinux-reboot sequence, which differ materially from Windows.
5. GUI library early-version layout/accessibility limitations.

## Starter tickets for a local coding agent

- `A01` Create module source layout and public API skeleton; replace all imports of old execution module.
- `A02` Write tests for step attempt identity and state-schema serialization allowlist.
- `A03` Implement global sequential planner, frozen plan hash, state writer and environment lease.
- `A04` Integrate Windows detached runner/reboot logic with source attribution and crash tests.
- `A05` Implement safe credential handoff for interactive and task identities; prove no secrets in run files.
- `A06` Implement Vault operation gate and contention tests.
- `A07` Migrate and qualify standalone Vault recipe from fresh snapshot.
- `A08` Migrate and qualify primary+DR recipe with protected shared keys and replication test.
- `A09` Implement CLI output, headless resume/monitoring commands and Gallery packaging.
- `A10` Implement NativeHTMLKit GUI using only public PowerShell SDK/UI APIs.
- `A11` Add AD, then PVWA/CPM/PSM, then PSMP/PTA with separate gates per recipe.
- `A12` Run full topology and fault injection, prepare release evidence, version manifest.

No release gate should be checked based on asserted success or mock output in place of a required live test.
