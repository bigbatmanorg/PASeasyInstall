# Lab validation

What was tested on real servers, newest first. Every run started from clean operating systems (Proxmox
snapshots), with CyberArk PAM Self-Hosted media supplied locally; no CyberArk file is part of this repository.
The run journals, lab check results and screenshots are kept by the owner outside the repository.

## 2.0.12, 2026-11-24: the owner's MyPAM lab, with and without a new AD forest

Controller LABDEPLOY01, PAM 15.2, servers rolled back to `clean_os_ready` before each run. The lab file is the
configuration of the owner's run 9da236dc, saved with `Export-PASLabConfiguration` and installed with
`Install-PASLab -Wait` from a task in the logged-on Administrator's session.

| Run | Lab | Result |
| --- | --- | --- |
| 49accdf2 | Vault, DR Vault, PVWA, CPM, PSM, PSMP, HTML5 Gateway, PTA | Succeeded in 19 min, no warning |
| 0102db17 | the same + new forest `pam.lab` on LABDC01 (PVWA, CPM, PSM joined, hardening GPOs) | Succeeded in 24 min, `Test-PASHealth` Healthy |

- PSM hardening passed at the first attempt both times (LanmanServer restarted within a second), so the new
  automatic repeat after a LanmanServer timeout was not exercised in the lab; unit tests cover its condition,
  checked against the vendor log of the failed owner run.
- Not covered by a lab run: retry of one failed step (skip of finished lanes), and the window's plan queue and
  collapsed shortcuts list (unit tests only; no window walk).
- A run started from a task with a stored-password (batch) logon lost its controller twice within two minutes;
  started in the interactive session it ran to the end. The window always starts it there.

## 2.0.11, 2026-11-24: full lab through the window, PTA connected

| Item | Value |
|---|---|
| Lab | 9 servers: controller (Windows Server 2022), Vault, DR Vault, PVWA, PSM, CPM on its own server (all Windows Server 2022), PSM for SSH and HTML5 Gateway (Ubuntu 24.04, own servers), PTA (Rocky Linux 9.9, 8 GB) |
| Media | PAM Self-Hosted 15.2 bundle (Vault 15.2.5, PVWA 15.2.3, CPM/PSM 15.2.4, PSMP 15.2.1, PTA 15.2.2), HTML5 Gateway 15.0 added as a second media folder (the gateway ZIP inside the 15.2 bundle was damaged) |
| How | The window, walked by its `-SelfTest` mode with the Live backend, as a separate local user on the controller: media, lab (Primary + DR, one of each component, CPM and gateway on own servers), servers, server check, install, lab check. The names typed in the window (`pta01`, ...) differ from the real host names (`labpta01`, ...) as in the owner's run |
| Unit tests | 706 passed, 0 failed (Windows PowerShell 5.1, Pester 5.9); `Check-Source` passes |

**The problem (owner's run with 2.0.10, 21 minutes):** every component was installed and verified, but the lab
check said *No PTA is registered in the Vault*. The Vault counted PTA (0 of 1 connected). PVWA asks PTA for its
status under the host name PTA registered in the Vault (`https://labpta01/api/getauthtoken`), and PVWA could not
resolve that name: the PTA trust step had written a hosts entry only for the name typed in the window (`pta01`).
PVWA answered the lab check's PTA request with HTTP 503, and the lab check reported that as "not registered".
Adding the hosts entry by hand on PVWA made PTA *connected* at once, which confirmed the cause.

The same run showed PTA registering before PSM: PTA's vendor configuration holds the Vault for about three
minutes while PSM waited, and the gateway registration waits for PSM.

| Run | Code | Result | Time | Notes |
|---|---|---|---|---|
| Owner's run (8ff16e08…) | 2.0.10 | Lab check: *No PTA is registered in the Vault* | 21 min | Registration order PVWA, CPM, PSMP, **PTA (3 min), PSM** |
| Run 1 (a0aaa6d9…) | PTA trust by certificate name, PTA after PSM/PSMP | **Healthy**, PTAAppUser 15.2.2 connected; walk 0 failures | 21 min | PTA took the Vault between PSM's first and second registration pass: PSM's two 12-second passes waited 3 minutes |
| Run 2 (0af8f7e7…) | + PSM announces its registration after the last pass | Stopped *Unknown* at PSM `install-pass2` | – | The step had succeeded on the server (`status.json` Succeeded at 13:26:51.69); the controller read the old status, then saw no process and called it interrupted. A race in the status probe, older than this release. PTA correctly went on without PSM. |
| Run 3 (253ee51e…) | + status read again before *Interrupted* (Windows and Linux) | **Healthy**, all 5 component users connected, PTA 1 of 1; walk 0 failures | **19 min** | Order PVWA, CPM, PSM (3 passes), PSMP, PTA; PTA trust 12 s with its HTTPS check by name |

Each defect has a regression test: PTA's gate and PSM's signal against the generated workflow
(`Tests/StageCatalog.Tests.ps1`, `Tests/Lanes.Tests.ps1`), the status race (`Tests/DetachedStatusRace.Tests.ps1`,
fails without the fix), and the window's Stop button (`Tests/UIDesktop.Tests.ps1`: it called `Stop-PASRun`
without `-Force`, which refuses a running installation; found while the documentation was rewritten).

Not proven by these runs: the Linux side of the status race (same fix, checked with `bash -n` and the jq
expression, not provoked), a lab with two PVWAs and PTA (the PTA trust is made on the first PVWA only).

## 2.0.9 and 2.0.10, 2026-11-23/24


**Date:** 2026-11-23, 18:10–22:50 UTC · **Scope:** disposable CyberArk 15.2 labs only

| Item | Value |
|---|---|
| Source ZIP | `PASeasyInstall-lab-stabilized-2026-11-23.zip`, SHA256 `4d1abb7a543f3d520c255720439a5f664fb4206488a1429c50ddac0c1897aa72` (identical to `PASeasyInstall-lab-stabilized/`) |
| Base | `main` = 2.0.8 (`0ed8afd`). The candidate is 2.0.8 plus the stabilization changes. |
| Branch | `lab/stabilized-candidate` (merged as PR #17): import commit + 8 fix commits |
| Controller | A Windows Server 2022 controller, Windows PowerShell 5.1.20348, Pester 5.9.0. The module was imported from the source tree, never from the Gallery. |
| Proxmox | Proxmox VE 9.2, a three-node cluster; every test server started from a clean snapshot. |
| Media | CyberArk PAM Self-Hosted 15.2 bundle (PVWA 15.2.3, CPM/PSM 15.2.4, PSMP 15.2.1 Ubuntu 24.04, PTA 15.2.2 on Rocky 9) and HTML5 Gateway 15.0 (the 15.2.1 gateway zip in the bundle is damaged) |
| Evidence | Kept by the owner outside the repository: one journal zip per run, lab health check per run, screenshots of the window, fault-injection logs |
| Unit tests | Candidate as delivered: 684 passed, **3 failed**. Final branch: **696 passed, 0 failed**. `Check-Source` passes. |

### Result per scenario (final code)

| Scenario | Result | Run ID | Key evidence |
|---|---|---|---|
| S01 Primary + PVWA/CPM + PSM through the **window, in a real visible desktop** (RDP session) | **PASS** | 67eb953a… | Walk: 0 failures, media scan, counters, no preset tiles, server check, install, lab check (walk log and 65 desktop screenshots kept with the evidence). An earlier headless walk (f65cd6ad) failed: defect D6. |
| S02 Primary + DR, parallel | **PASS** (after D7) | 550f9f28… | The DR Vault started next to the Primary, and PVWA, CPM and PSM continued while DR worked. `DetachedProgress` "DR replication: phase (elapsed / max)". The test Safe was replicated and verified. Health OK. The first run (c190d94d) failed: defect D7. |
| S03 PSMP + HTML5 Gateway + PTA | **PASS** (one operator retry) | 85604a2c… | PTA trust started as soon as PVWA and PTA were Done, without waiting for PSMP or PSM. Gateway registration waited only for its own prerequisites. 5 components logged on. The PSM vendor hardening failed once ("Error restarting LanmanServer: Time out", a vendor/Windows timeout under load). `Resume-PASRun -RetryStep harden` completed it, and PTA trust was revalidated, not redone. |
| S04 New AD forest + joins + GPO | **PASS** | 2fa170eb… | Vault not joined. Joins waited for the forest. GPOs applied at the end, only in `pasval.test`. Health OK after the GPOs. |
| S05 Two PVWAs, two CPMs, PSM | **PASS** (after D8) | 787f3351… | Vault registrations strictly one at a time: PVWA1, PVWA2, CPM2, CPM1, PSM. Both PVWAs and both CPMs logged on. The first run (252bc55e) was refused at once: defect D8. |
| S06 Verifier interruption, exactly-once actions | **PASS** (after D5) | 440d8cd1… (baseline 3f94976d) | **Fault A:** the hardening verifier was killed while running and replaced by a verification-only generation (`VerificationRecovered`). The action ID stayed the same. **Fault C:** SSH was cut while the verifier was being staged: the run ended **Unknown**, and ordinary Resume stayed Unknown without starting another verifier. With D5, `-RetryStep` repeated only the verification. Every attempt folder created after the last action is a verifier, so no hardening or registration ran twice. |
| S07 PTA failure isolation and resume | **PASS** | 7a573438… | With root locked on PTA, only the PTA lane failed, and PTA trust was marked `IntegrationBlocked` at once. Primary, DR (including the test Safe), PVWA, CPM, PSM and PSMP finished, and the run ended Failed. After unlocking root, Resume revalidated the finished steps (`TaskRevalidated`), installed PTA, and ran PTA trust. 5 components healthy. |
| S08 Forced stop and lock safety | **PASS** | a9cda711… / c564015e… / bbfa651b… | `Stop-PASRun -Force` stopped the controller during the PVWA install, marked the run Abandoned and **kept** all 3 locks. A new run was blocked by those locks on both Windows servers. After the VMs were restored, `-ReleaseLocksAfterReset` was run and a clean deployment succeeded. |

A/B check with unchanged 2.0.8 (`main`) on the S01 topology (e93e0778): Succeeded. Its PSM simply won the NLA race (D6).

### Defects found and fixed on the branch (each has a regression test)

| ID | Severity | Where | Problem → fix |
|---|---|---|---|
| D1 | P1 | candidate, Lanes.ps1 | Every component now publishes `Done:<id>`, so a failed CPM reported "what depends on it is not installed". Only signals that something waits for are reported now. |
| D2 | P2 | candidate tests | SelfTest switched Advanced off again; a test helper was not loaded. These were the 3 failing Pester tests. |
| D3 | P0 | candidate, Lanes.ps1 | The new integration lane had no Vault gate, so gateway registration would give up after 180 s while other servers were registering. Its 4-hour limit counted from the start of the run. Both integrations could run on the first PVWA while another component on that server was still installing. Fixed: gate, deadline from the last progress, same-host order, and the gateway waits for PTA. |
| D4 | P1 | candidate, DurableCheck.ps1 / workflows | Linux verifier race at worker exit, which now waits up to 30 s. `prepare-tools` time limit raised to 1800 s. The DR progress reporting was never wired up: the DR waits now run detached. |
| D5 | P0 | candidate + engine | A Linux verifier whose staging was cut off (a network glitch) left the run unrecoverable: Resume refused, and `-RetryStep` refused as well. The operator's `-RetryStep` now repeats only the verification, and only when the old verifier is shown not to be running. |
| D6 | P1 | **also in 2.0.8**, PSM recipe | About a minute after the Remote Desktop Session Host restart, Windows turns NLA back on, after the vendor's DisableNLA step has already checked it. Post-install then fails. Observed in 2 of 4 PSM installs, and the NLA watcher (an NLA watcher log) shows the flip. The recipe now re-applies the vendor prerequisite through the native method, with a read-back. **Proven live 2026-11-24** (run d53ee52b): NLA was forced on at PSM registration; post-install logged the re-apply, verified, and the lab is healthy. The natural flip was seen in 3 of 5 PSM installs. |
| D7 | P0 | **2.0.8 regression** | The DR test Safe is created earlier since 2.0.8, so it was replicated before the final wait started, and the wait never completed. Every Primary+DR lab would fail. The wait now searches the whole PADR log for the run-unique Safe and still requires a fresh cycle after it. |
| D8 | P0 | candidate, Lanes.ps1 | The new plan check rejected any lab with two PVWAs as a "cyclic dependency". Deadlock detection now works per component. |

### Remaining risks / not proven

- **P2:** S08: releasing the PSMP lock after a VM reset uses only the controller key, which the restored VM no longer trusts. Harmless (the reset VM has no lock), but the message is misleading. The blocked PSMP lane failed on password sign-in (the old run had hardened PSMP) before it reached its lock check.
- **P2:** The server check of 3 Windows servers takes 4–7 minutes. The window stays responsive.
- **P2:** Every Linux check now runs as a detached systemd job, so resumes are slower (about 4 s per finished Linux step).
- **Not exercised:** browser PSM/HTML5 session, PTA audit ingestion, other OS/media versions, real AD with an existing domain.
- Transient vendor failures (such as the LanmanServer restart timeout in PSM hardening) still need an operator `-RetryStep`, by design.

### Release decision

**Lab build candidate: PASS**, for the branch `lab/stabilized-candidate` (2.0.8 + candidate + 8 fixes), **not** for the ZIP as delivered. The ZIP as delivered fails S05 (two PVWAs refused) and S02 (DR test Safe; that part is inherited from 2.0.8), and can leave PSMP runs unrecoverable. 2.0.8 itself fails every Primary+DR lab (D7) and intermittently the PSM (D6).

### Addendum 2026-11-24: recovery path (released as 2.0.10)

| Test | Fault | Result | Run ID |
|---|---|---|---|
| F1 first PVWA fails | WinRM stopped on the PVWA during its media upload | **PASS.** PVWA Unknown; CPM and PSM gave up within 1 s; the Vault finished. After WinRM was back, a plain Resume finished the lab: health OK. | 5cfaaf10… |
| F2 Primary Vault fails, Primary + DR | WinRM stopped on the Vault during its upload | **PASS.** The DR Vault gave up at once; PVWA and PSM stopped where they need the Vault; nothing waited. A plain Resume finished everything, including the DR test Safe: health OK. | 7f338d49… |
| L1 forced stop with PSMP | `Stop-PASRun -Force` | **PASS** (after the 2.0.10 fixes). The new run was Blocked with "locked by run …" on all servers, PSMP included. After a VM reset, `-ReleaseLocksAfterReset` reached PSMP with the password, and the run was marked `locksReleased`. | 910d0b06… / 46fc14c1… |

The PSM NLA re-apply (D6) was proven live on 2026-11-24 as well (run d53ee52b). With this, nothing in the installation and recovery path is left unproven.
