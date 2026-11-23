# PASeasyInstall — lab stability refactor, 2026-11-23

**Support boundary: disposable lab deployments ONLY.** A production-supported deployment, production qualification program, or Secure/production profile is not planned. The built-in `Secure` CLI configuration is a legacy surface and is not a release goal. The existing module and journals are retained; no new framework, server, or external database has been added.

> **Qualification status:** This is a source-level stabilization candidate, **not a verified release**. In the preparation environment, Windows PowerShell 5.1, Pester, the WPF runtime, and CyberArk/Proxmox guests were not available. Shell syntax/static checks and packaging checks are not substitutes for a real lab deployment. The local agent must perform the gates in `LabValidation/`.

## Verified cause and mitigation

| Incident/risk | Implemented change | Safety boundary / remaining qualification |
|---|---|---|
| PSMP action succeeded but its verifier was interrupted | Independent durable verifier retry can create a new verifier attempt **only** when explicitly marked safe or a Linux read-only verifier, *and* the original worker has an identifiable PID/boot record and confirmed inactivity. Original action attempt ID is preserved; attempt lineage is recorded. | An unclaimed staging callback remains Unknown; no blind retries. Requires real WinRM/SSH interruptions during qualification. |
| Slow/unrelated component holds up gateway/PTA | Scheduler starts `GatewayRegistration` and `PtaTrust` in their own parallel runspace as soon as each required `Done:<id>` signal is released. One blocked/failed integration does not prevent the other from running. | PVWA-side integrations are serialized inside the one finalizer lane; GPO integration remains ordered at the end. Assert actual event times in S02/S03. |
| Silent missing signal or wait forever | Strict signal lookup, producer validation and cross-lane cycle check happen before remote dispatch. Signal waits have cancellation plus bounded timeout; errors carry named prerequisites. | Timeout defaults to four hours for slow labs; the agent should collect the outstanding signal and progress evidence. |
| `Stop-PASRun -Force` can allow overlapping detached work | Force stops only the owning controller and retains remote target locks. Explicit release requires `-ReleaseLocksAfterReset` and `-CredentialMap`, only after reverting/rebuilding affected test VMs. | A remote worker can survive controller termination; never infer worker exit from controller exit. |
| Old successful journal causes a lane to be skipped entirely on resume | Parallel execution no longer trusts a lane-level “Succeeded” shortcut; it dispatches the existing engine workflow so successful steps are reverified and dependencies are republished only on verified success. | A successful probe must be read-only and reflect relevant readiness; final acceptance checks remain distinct. |
| Vault workflow modified between runs | Vault recipe tree, workflows and static helper sources are copied to a run-owned payload, with a SHA256 manifest checked on every resume. | Source package update does not rewrite in-flight Vault scripts. Tampering yields a hard stop rather than switching code silently. |
| PSMP “preflight” installed OS packages | Added explicit detached `prepare-tools` stage between read-only preflight and extraction; `unzip` installation and needrestart guard happen in this named mutating step and `Verify.sh` checks readiness read-only. Public stage catalog reflects it. | Existing in-flight PSMP workflows use their frozen original steps; changing the generated workflow is for *new* deployments. OS and package manager behavior require Ubuntu/Rocky qualification. |
| DR wait appears frozen for up to 15 minutes | `Wait-Replication.ps1` writes bounded phase + elapsed/max seconds to protected detached attempt sideband; controller emits throttled `DetachedProgress` events. | Progress is *advisory*. A real PADR log and test-Safe receipt remain authoritative for success. |
| UI needs too many presets | The new-install UI shows only media → Primary or Primary+DR and component counters → servers → install. Existing Vault/domain advanced controls remain optional; old preset helpers remain internally only for compatibility with historical fixtures. | Verify in real WPF, minimum window size and remote desktop; no generated screenshot is proof of a live run. |

## Scheduler / safety invariants

1. **One mutating action ID; zero unproved replays.** A verifier is an independently journaled attempt. Verifier-only recovery never reruns Vault installer, MSI, hardening or registration.
2. **Dependency satisfaction is evidence, not a timer.** A step signals `Done` only after its verification has actually passed; no generic sleeps substituted for readiness checks.
3. **Never release locks solely because the controller exited.** A detached scheduled task or systemd service may still run. Restore disposable VMs before any abandoned-run lock cleanup.
4. **Selective concurrency.** Operations on independent servers can overlap; components on one host are serial. Vault-authenticated operations remain guarded by the existing Vault/account lock; integration mutations on the first PVWA are serialized.
5. **Partial results are explicit.** A failed optional component is not falsely reported as installed, even if unrelated lanes succeed. DR terminal status is independent of the Primary and components.
6. **No secret exposure.** Journals should use redacted information and only safe enum/elapsed telemetry from replication; licensed installer media and secrets are never packaged.

## Recommended test order

Use `LabValidation/scenarios.json` and `LabValidation/AGENT-PROMPT.md`. S01 validates the normal desktop flow. S06 exposes the high-risk PSMP verification bug. S02 validates DR timing, S05 multi-instance readiness/serialization, S04 domain joins/GPO, S07 partial failure, S08 safe cancellation, S03 dependent Linux integrations if vendor packages available. Every test begins with a clean clone/snapshot or a provably clean lab baseline. Scenarios have strict evidence requirements, and a blocked prerequisite is reported as BLOCKED rather than secretly skipped.

## Qualification steps for the local Windows agent

Run from a clean PowerShell 5.1 session on the controller **with the supplied source module**, not the Gallery release:

```powershell
$repo = 'C:\Lab\PASeasyInstall-stabilized'  # adjust to actual extracted path
$env:PSModulePath = "$repo;$env:PSModulePath"
Import-Module "$repo\PASeasyInstall\PASeasyInstall.psd1" -Force -ErrorAction Stop
Get-Module PASeasyInstall | Select-Object Name, Version, Path
Get-PASStageCatalog -Component PSMP | Format-Table Order,Stage
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
Invoke-Pester -Path "$repo\Tests" -Output Detailed -CI
```

Some suites require specific OS, permissions or connectivity; document precisely any exclusions. Also run the project's own `Tools/Invoke-CITests.ps1` entry point according to its parameters. Verify real media discovery, window interaction, all steps, and VM recovery through the eight lab scenarios. For each defect, preserve evidence, patch with focused regression, and retest against clean snapshots.

## Source compatibility notes

- Public `Start-PASDeployment`, `Resume-PASRun`, `Stop-PASRun`, `Get-PASStageCatalog`, CLI workflow semantics, and engine journaling are retained. An additional `Stop-PASRun -ReleaseLocksAfterReset` parameter makes an unsafe cleanup operation explicit.
- Existing incomplete runs should be exported before upgrade. Current frozen scripts are used for newly created run payloads. Do not force-resume a pre-refactor run without checking its `state.json`, recipe digests and detached attempt status.
- Legacy `Get-PASUIPresets`/`Set-PASUIPreset` remain private implementation helpers so existing Pester fixtures still work, but no preset buttons or workflow chooser appear in the new-install page.

## Not implemented / no false assurance

No Proxmox controller, licensed CyberArk media, live host installation, Windows GUI session, vendor DR replication, fault injection, or WPF/Pester suite was executed during preparation. Real pass/fail results must come from the local agent and the provided templates. There is no production-hardening roadmap; only a reliable, repeatable **lab installer** is in scope.
