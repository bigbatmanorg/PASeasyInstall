# Durable runs and resume

A lab installation takes tens of minutes and includes reboots. PASeasyInstall assumes that the controller can close,
reboot or lose the network at any moment.

## Runs

An installation is a **run**. `Install-PASVault`, `Install-PASLab` and the other install commands start a detached
controller process and return a 32-character run id. The run keeps going when you close the console or the desktop.
Its files are in `%LOCALAPPDATA%\PASeasyInstall\Runs\<run id>`: `run.json` (status), `config.json` and `plan.json`
(what it installs), `events.jsonl` (progress) and one folder per server with its journal.

## Attempts

Every step that changes a target is started as an **attempt** with a unique ID: a scheduled task (Windows) or a
systemd unit (Linux) with its own folder on the target. The attempt records its state (`Dispatched`, `Running`,
`Succeeded`, `Failed`) on the target itself. The controller polls it and then **verifies** the result with a separate
check. For example, after the Vault installer it checks the Vault log for the "server is up" record and performs a
PACLI login.

## Journals

The controller writes an event journal per run and per server (`events.jsonl`) and a journal of step states
(`state.json`). `Get-PASRun`, `Get-PASRunEvent`, the desktop's progress view and `Export-PASDiagnostics` all read
these files. They contain no secrets.

## Run status

| Status | Meaning |
|---|---|
| Launching, Running | The controller process is working |
| Succeeded | Every step finished and was verified |
| Failed | A step failed. Nothing was repeated |
| Unknown | The outcome of a step on a server could not be determined |
| Blocked | A server is locked by another run ([locks](coordination.md)) |
| Interrupted | The controller process ended without recording an outcome |
| LaunchFailed | The controller process never started, or stopped before any server was contacted |
| Abandoned | Given up with `Stop-PASRun`. Cannot be resumed |

## Resume

```powershell
Resume-PASRun -RunId <run id>
```

Resume works for Failed, Unknown, Blocked, Interrupted and LaunchFailed runs. It uses the configuration and plan the
run saved at start. What happens next is decided by **reconciliation**, not by guessing:

- a component that finished is only checked again, read-only;
- an attempt that is still running on the target is waited for, even after a controller crash;
- an attempt that was dispatched is found again by its ID. It is never started a second time;
- a step that ended **Failed** or **Unknown** is **not** repeated on its own.

## Repeating a failed step: -RetryStep

Look at the server and at the failed event first (`Get-PASRunEvent -RunId <run id> -Failed`). Correct the cause. Then
name the step:

```powershell
Resume-PASRun -RunId <run id> -RetryStep install            # the step 'install', wherever it failed
Resume-PASRun -RunId <run id> -RetryStep cpm01:install      # only for the component cpm01
```

Only steps whose journal says Failed or Unknown are accepted. A name that matches no such step is an error, so
nothing is ever repeated by accident. `Get-PASStageCatalog` lists the step names of a component type.
`-RetryFailedPreflight` repeats a failed read-only Linux preflight, for example after you installed a missing package.

## What may change between start and resume

- **The configuration and the installer media may not change.** Resume compares the configuration digest and the
  SHA-256 of every installer with the saved plan and refuses a difference. Start a new run instead.
- **The module may change.** There is no source digest any more: updating PASeasyInstall does not invalidate a run.
  Each server's workflow and scripts are still pinned per run, so a step is never continued with different code.

## Reboots

Steps that require a reboot (Vault and PVWA hardening, PSM's installation passes, AD promotion) record the boot ID
before and after the reboot. The run continues only after the new boot is confirmed.
