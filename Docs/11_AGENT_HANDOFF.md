# 11 — Local Coding Agent Handoff (Phase 0–2)

This is an optional starter brief for the **first implementation pass**. It is not an instruction to claim the full CyberArk product complete without running vendor qualification.

## Goal

Refactor `PASeasyInstall` into a **single self-contained PowerShell module** using the accompanying architecture pack. Remove all runtime/build dependencies on a standalone PSSteps engine and on UI4ME. Adapt only the useful old execution code directly into PASeasyInstall's private implementation. Support a CLI with a frozen JSON plan and reliable Windows detached execution, while keeping the proven Vault/DR semantics. NativeHTMLKit UI is optional and can follow after the headless phase passes.

## Read first

`README.md`, `02_ARCHITECTURE.md`, `03_EXECUTION_RECOVERY.md`, `05_CONFIG_CLI.md`, `06_SECURITY.md`, `08_QUALIFICATION_ROADMAP.md`, and `09_SOURCE_REVIEW.md` from this design pack. Read the current PASeasyInstall source and tests yourself. Treat the old source as evidence, not an immutable architecture. Do not copy vendor installer binaries or key material into the repo.

## Implementation pass 1

1. Build a manifest-backed single-module layout; expose a small set of public commands. The module must import with NativeHTMLKit/PSSteps/Ansible/Python absent.
2. Write characterization tests against old Vault/DR step semantics, attempt recovery, log redaction and media handling before rewriting those areas.
3. Convert imported engine helpers into module-private code, remove unused generic features, preserve the original MIT notices where required.
4. Implement configuration parsing, typed validation, deterministic plan generation, frozen versioned plan hashes and a single global mutating step queue.
5. Implement protected atomic run state, structured events and allowlisted evidence output; never persist arbitrary remote result data.
6. Integrate Windows Task Scheduler detached execution and reboot/management recovery, with attempt ID stored **before** remote dispatch.
7. Implement one environment controller lease, physical-host collision check and one Vault-authentication gate respected by all application-authenticated operations.
8. Implement CLI start/status/resume and read-only independent postcondition checks for Vault/DR; UI can initially be a later milestone.
9. Prove fault recovery with synthetic targets, then requalify standalone Vault and primary+DR on **fresh VM snapshots** with actual licensed media; collect evidence, do not silently rerun hardening/installers.

## Agent behavior

- Work autonomously, but do not invent qualification evidence, lower security checks silently or replace unknown outcomes with success.
- Prioritize correctness and simple code. Do not build a plugin framework, extra backend, database, generic DAG system or a second PowerShell module.
- Keep commits small, with tests proving each behavioral change and a documented rollback path.
- Use the lab VM infrastructure only after explicitly verifying target names, IDs and snapshot labels. Never restore a VM by guessed identity.
- When blocked on credentials/media or insufficient local access, implement/test what is possible and report exactly which live gates remain unqualified.
- Finish with a concise statement of implemented behavior, tests run, failing cases, security deviations and next actions. `No live qualification` must never be phrased as `completed`.

## Phase-2 completion checklist

- [ ] Clean Windows controller imports PASeasyInstall CLI without UI packages.
- [ ] No separate execution-engine module import/runtime copy/source-sync step remains.
- [ ] Standalone Vault `Primary` and coupled primary+DR plans are deterministically reproduced or intentionally updated with matching test evidence.
- [ ] Crash/WinRM loss/target reboot failure-injection tests guarantee no duplicate irreversible attempt.
- [ ] Vault gate contention, host aliases, plan drift and secret leakage tests pass.
- [ ] Fresh, live Vault and Vault+DR qualification re-run is documented with actual target versions and independent verification.
- [ ] Any remaining GUI and additional-component work is clearly marked as not yet implemented.

## Follow-on passes

After Phase 2: NativeHTMLKit GUI and Gallery packaging; AD; PVWA/CPM/PSM; PSMP/PTA; combined full-lab regression. Apply the per-recipe acceptance gates from `08_QUALIFICATION_ROADMAP.md`. Only then consider limited host parallelism.
