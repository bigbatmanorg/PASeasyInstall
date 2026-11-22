# Installing the servers at the same time (design)

Written on 2026-11-22 after the owner's request. **Nothing of this is built.** It says how a run works today,
what must stay in order, and the smallest change that installs the servers side by side.

## Today

One run is one controller process. It does everything one after the other
(`Invoke-PASRunControllerCore` in `Private/Run/Run.ps1`):

1. new forest, 2. domain joins, 3. Vault (and DR), 4. every other component in plan order,
5. gateway registration, PTA trust, GPOs.

Measured on a Full lab with DR, CyberArk 15.2 (run of 2026-11-21, 41.4 minutes):

| Part | Minutes | Starts after |
|---|---|---|
| Vault + DR | 15.6 | - |
| PVWA | 7.8 | Vault |
| CPM (same server as PVWA) | 3.2 | PVWA |
| PSM | 12.5 | CPM |
| PSMP | 2.3 | PSM |

Most of that time the controller only waits: the long steps run on the server itself (scheduled task or systemd
unit) and the controller asks for their state. The PSM server and the PSMP server are idle for 26 and 39 minutes
before their turn comes.

## What really has to be in order

| Rule | Why |
|---|---|
| One server does one thing at a time | Installers, MSI and restarts of one server cannot overlap. Components on the same server (PVWA + CPM, PSMP + gateway) stay one after the other. |
| New forest before the domain joins | A join needs the domain's DNS. |
| Join of a server before anything is installed on it | The join restarts the server; the PSM install account is a domain account. |
| Vault ready before any registration | Registration signs in to the Vault. "Ready" = the Primary Vault workflow reached the end of `configure-primary` and the Vault answers on 1858. With a DR Vault the registrations wait for the end of the whole Vault sequence, because the sequence restarts the Primary Vault while it sets up replication. |
| One Vault sign-in as Administrator at a time | Several at once lock the Administrator out. This is the queue the owner described. |
| First PVWA registered before any other component registers | PSM, PSMP, the gateway and PTA write into the PVWA configuration that the first PVWA creates in the Vault. CPM is registered after PVWA by the vendor's order. |
| PVWA certificate before the CPM that pins it | The CPM step `pvwa-trust-certificate` copies it. On one server this is already in order. |
| Gateway registration and PTA trust after PVWA is installed | Both change the PVWA server. |
| GPOs last | They turn on the firewall and close the servers down; everything else must be finished. |

Everything else is free: uploading media, checks, unpacking, prerequisites, the installation itself, hardening
and the final verification of a server need no other server. Only the step `register` (and for PTA its
configuration step) needs the Vault.

## Design: one lane per server, one queue for the Vault

**Lanes.** The controller keeps one lane per server. A lane runs the components of its server in plan order,
exactly as today. The lanes run side by side. The Vault lane (Vault, DR) is one lane, unchanged inside.

**Gates.** A lane waits at three points, and says so in its status ("Waiting for the Vault"):

| Gate | Opens when | Who waits |
|---|---|---|
| Domain | forest installed (domain labs only) | every lane with a server that is joined; the Vault lane does not wait |
| Vault ready | Vault sequence finished | every step that opens a Vault session |
| First PVWA | first PVWA finished `register` | `register` of every other component; gateway registration; PTA trust |

**The queue.** It exists already: a step marked `RequiresVaultSession` takes the Vault lock (`Private/Engine/Locks.ps1`,
a named mutex per Vault address), so two registrations never run together, also not from two runs. What changes:
a lane waits for the lock without the 180-second limit of today, and the lanes take it in plan order (PVWA, CPM,
PSM, PSMP), so a run is repeatable.

**Order of a run with a new domain:**

```
forest ─┬─ join PVWA/CPM server ── install PVWA .. ─┐
        └─ join PSM server ─────── install PSM .. ──┤   (each lane on its own)
Vault ── (Primary, DR) ─────────── ready ───────────┤
PSMP server ── install .. ──────────────────────────┤
                                                     ├─ register PVWA → CPM → PSM → PSMP (one at a time)
                                                     ├─ harden, verify (each lane on its own)
                                                     └─ gateway registration, PTA trust, GPOs (in order)
```

**How the lanes run.** Each lane is a PowerShell runspace inside the controller process (one thread per lane).
The credentials stay in the memory of the one process, as today; nothing new is written to disk. Each lane
calls the same `Invoke-PASComponent` as today. The engine below it is not changed: it already keeps one journal
and one lock per server.

## What has to change in the code

1. `Invoke-PASRunControllerCore`: replace the loop over the components by lanes and gates (about the size of
   the loop today plus a small lane runner). A switch `execution.parallel` in the configuration, on by default,
   keeps the old order available while the new one is proven.
2. Things all lanes share today and must not:
   - `$Run.Target` and `currentComponent` in `run.json` become one entry per lane.
   - `Write-PASRunEvent` appends to one file from several threads: write under a lock.
   - `$Run.SshReady` and the frozen-media table: fill them before the lanes start.
   - The media cache (`MediaCache`): unpack every package the run needs before the lanes start, so that two
     lanes never unpack the same file.
3. `Enter-PASVaultLock`: a wait without limit for a lane of the same run, with an event "Waiting for the Vault"
   so the window can show it.
4. Failure: when one lane fails, the others finish the step they are in and stop at their next gate. The run
   ends as Failed with the failed step named, as today. `Resume-PASRun` starts all lanes again; finished steps
   are only checked.
5. Window: the run page already has one line per component. It needs the state "Waiting" and must allow several
   components to be "Running". The total progress is counted over all components, as today.
6. `Get-PASRunLog`, `Wait-PASRun`, `Export-PASDiagnostics`: read `currentComponent`; adjust to several.

Not needed: a job scheduler, a dependency graph in the configuration, or parallel work inside one server.

## What it should save

With the numbers above, and registration being a small part of each component:

| | Today | Side by side (estimate) |
|---|---|---|
| Full lab with DR | 41 min | about 20 to 24 min: the Vault and DR (15.6) set the pace; PSM (12.5) is installed during that time and only registers, hardens and verifies afterwards |
| Lab with a new domain | 36 min | about 20 min |
| Two of each component | 62 min | about 25 min |

These are estimates from one run each. The real numbers come from the first parallel runs.

## Risks

- **Load on the hypervisor.** Five installers at once on one host. The lab host has little spare memory; the
  first runs will show whether steps time out.
- **Bandwidth and disk of the controller.** Several uploads at once. If that is slow, limit uploads to two at a time.
- **PowerShell remoting from several threads.** One controller crashed once in remoting under load (2026-11-22).
  If that shows again, the lanes become child processes instead of threads; the credentials are then handed over
  with DPAPI the way the controller gets them today.
- **Readability of the log.** Events of several servers mix. Every event already names its component.

## How to prove it

1. Unit tests: lane order, the three gates, the registration order, a failing lane stops the others at their gate.
2. Lab, from clean servers, each without a manual step: Full lab with DR; lab with a new domain and GPOs;
   two of each component; a lab with PTA and gateway.
3. One run with a provoked failure in one lane (locked root on the PSMP server), then `Resume-PASRun`.
4. Compare the times with the table above and write them into `STATUS.md`.
