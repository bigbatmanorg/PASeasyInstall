# PASeasyInstall — Lab release qualification report

**Source ZIP / SHA256:**
**Source revision and modified diff:**
**Controller OS / PowerShell / Pester:**
**Proxmox version / allowed nodes, VMIDs, template+snapshot IDs:**
**Media version(s) and package digest metadata (no licensed media files):**
**Test window (UTC):**

| Scenario | Result (PASS/FAIL/BLOCKED/NOT_RUN) | Duration | Run ID | Crucial evidence | Defect ID |
|---|---|---|---|---|---|
| S01 | | | | | |
| S02 | | | | | |
| S03 | | | | | |
| S04 | | | | | |
| S05 | | | | | |
| S06 | | | | | |
| S07 | | | | | |
| S08 | | | | | |

## Core safety assertions

- No duplicate mutating action after interruption: **evidence:**
- No lock released for a possibly active detached worker: **evidence:**
- Dependencies validated before dispatch, no cyclic or missing signals: **evidence:**
- Independent integration executed when ready (without DR/global barrier): **evidence:**
- DR final test Safe, not merely a service up: **evidence:**
- Successful steps independently revalidated on resume: **evidence:**
- Credential/media/log redaction checked: **evidence:**
- Source-imported module and Pester pass count, no accidental older Gallery version: **evidence:**

## Defects and root-cause analysis

Record each defect with: first observed UTC, scenario, failed attempt ID, target and stage, actual vs expected, primary cause, evidence filename/path, code change, regression command, clean-snapshot rerun result.

## Explicit non-evidence / unqualified tests

Note any not-yet-proven browser session flow, PTA audit ingestion, vendor media variations, Windows environment variants, or unknown recovery states. Do not market them as completed.

## Release decision

Lab build candidate **PASS / FAIL / INCOMPLETE** with objective reasons. No production-supported deployment scope.
