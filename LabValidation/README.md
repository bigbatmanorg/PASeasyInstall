# Lab release qualification

**Scope: disposable lab installations only.** These files describe how a release is checked on real servers
before it is published. They contain no credentials, VM identifiers, CyberArk media or test results; what was
actually tested is recorded in [Docs/VALIDATION.md](../Docs/VALIDATION.md).

| File | What it is |
|---|---|
| `scenarios.json` | The eight lab scenarios (topology, faults to inject, acceptance criteria, records to keep). The authoritative list. |
| `REPORT-TEMPLATE.md` | The form of a qualification report: one line per scenario with PASS / FAIL / BLOCKED / NOT_RUN and its evidence. |
| `assess_run.py` | Reads an exported run folder (`run.json`, `config.json`, journals) and prints a sanitized summary: target ids, status values and event counts, never messages, addresses or secrets. It does not decide PASS. |
| `test_assess_run.py` | Unit tests of the assessor: `python3 -m unittest test_assess_run` in this folder. |

```bash
python3 LabValidation/assess_run.py <exported run folder> --output <file outside the repository>
```

## The scenarios

| Scenario | What it proves | Risks covered |
|---|---|---|
| S01 | Window happy path, Primary + PVWA/CPM/PSM | Real UI, normal registration and hardening |
| S02 | Primary + DR, servers in parallel | DR test Safe, no global barrier, progress |
| S03 | PSM for SSH, HTML5 Gateway, PTA | Linux preparation, integration dependencies |
| S04 | New Active Directory domain | Join, restart, GPO and certificate trust order |
| S05 | Two PVWAs and two CPMs | Multi-instance signals, one Vault session at a time |
| S06 | Interruption during verification | Verification-only recovery, no action repeated |
| S07 | PTA failure while other lanes succeed | Failure isolation and resume |
| S08 | Forced stop during detached work | Locks kept, clean rebuild after a reset |

Run S01 and S06 first, then S02, S05, S04, S07, S08; S03 when the PTA and gateway media and an 8 GB RHEL-family
server are available. Start every scenario from clean snapshots and record a scenario as BLOCKED, not PASS,
when its media or servers are missing.

## Gate criteria

- Every step, integration and acceptance check of a selected scenario reaches a final state. A component that
  is `Succeeded` is not enough while its integration or the DR test is still running.
- The timeline follows the real dependencies: no component waits behind DR or another unrelated lane.
- No credential or CyberArk file is put into source control, diagnostics ZIPs, logs or screenshots.
- After an interruption, the recorded attempt ids are reconciled before anything is repeated. *Unknown* is a
  legitimate, safe result when it cannot be shown that a remote worker has stopped.
- The released source also passes `Tools/Invoke-CITests.ps1` on a Windows controller; the window is checked in
  a real desktop session (`-SelfTest` walk), not only by tests.
- A defect gets a fix with a regression test and a rerun of the scenario that found it. A check is never
  weakened to make a run pass.

Keep the evidence of a qualification (run journals, health results, screenshots) outside the repository and
summarise it in `Docs/VALIDATION.md`.
