# PASeasyInstall — meaningful lab release qualification

**Scope: disposable lab installations only.** There is no production deployment plan or production-support gate.

This suite is an **execution specification for an autonomous local agent** with access to the user's Proxmox lab. This ZIP does **not** contain Proxmox credentials, VM template IDs, CyberArk media, licenses, or any evidence that tests have already passed. `scenarios.json` is the authoritative machine-readable scenario inventory. Run the scenario only when the required CyberArk media and OS templates exist; report BLOCKED otherwise, not PASS.

The eight scenarios are deliberately different:

| Scenario | What it proves | Distinct risks covered |
|---|---|---|
| S01 | WPF happy path, Primary + PVWA/CPM/PSM | Real UI, normal registration/hardening |
| S02 | Primary+DR, parallel servers | DR test Safe readiness, no global barrier, progress |
| S03 | PSMP, HTML5 Gateway, PTA | Linux preparation, distinct integration dependencies |
| S04 | New Active Directory domain | Join/reboot/GPO/cert trust ordering |
| S05 | Two PVWAs and CPMs | Multi-instance signals and Vault serialization |
| S06 | Crash during verification | Evidence-backed verifier-only recovery, no action replay |
| S07 | PTA failure while other lanes succeed | Failure isolation and resume |
| S08 | Force-stop during detached work | No premature lock release and safe clean rebuild |

**Execution priority:** S01 and S06 first, then S02, S05, S04, S07, S08; S03 when all required packages and resource sizes are available. Reuse isolated test templates, *not* test mutations, via snapshots/clones; do not accumulate one cluster's worth of eight topologies simultaneously. Skip or reduce impossible configurations explicitly and record why. If an early scenario finds a P0 defect, fix/retest that scenario before spending time on further large deployments.

## Gate criteria

- Every selected deployment reaches terminal states for **all** required steps, finalization tasks and acceptance checks. `Succeeded` on a component is not enough when an integration or DR final test is still Running.
- The dependency timeline must reflect the real prerequisites. Unrelated components are never held behind DR or another unrelated lane.
- Credentials and vendor installation material are never placed in source control or diagnostic archives. Sanitize all logs and screenshots before exporting.
- After interrupted remote work, the exact action/worker/verifier attempt identities are reconciled before any retry. *Unknown is a legitimate safe outcome* when quiescence cannot be proven.
- The released source tree must also pass all Pester and on-target contract tests on the Windows controller; UI Automation or a real desktop smoke cannot be replaced by Linux syntax checks.
- A bug requires a reproducible fix with a new regression test and a rerun of its failed scenario. Do not weaken a verifier, skip a dependency, or turn a failure into success to make tests green.

Use [AGENT-PROMPT.md](AGENT-PROMPT.md) as the autonomous operator prompt. Record the results under a date-stamped directory *outside the source repository*, and report scenario IDs using the format in `REPORT-TEMPLATE.md`.
