# Durable runs and resume

A lab installation takes tens of minutes and includes reboots. PASeasyInstall assumes that the controller can close,
reboot or lose the network at any moment.

## Attempts

Every stage that changes a target is started as an **attempt** with a unique ID: a scheduled task (Windows) or a
systemd unit (Linux) with its own folder on the target. The attempt records its state (`Dispatched`, `Running`,
`Succeeded`, `Failed`) on the target itself. The controller polls it and then **verifies** the result independently.
For example, after the Vault installer it checks the Vault log for the "server is up" record and performs a PACLI
login.

## Journals

The controller writes an append-only event journal per run and per server (`events.jsonl`) and a run status file.
The desktop's progress view, `Get-PASEnvironmentSnapshot` and `Export-PASRunData` all read these journals. They
contain no secrets.

## Resume

When a run stops, its next step is decided by **reconciliation**, not by guessing:

- an attempt that finished is never repeated;
- an attempt that is still running on the target is waited for, even after a controller crash;
- an attempt whose outcome is **uncertain** (for example an installer interrupted by a power loss) stops the run
  and asks for inspection. PASeasyInstall never blindly reruns an installer.

Resume reuses the run's frozen configuration and source digest. If you change the configuration, start a new run.
See [`Resume-PASeasyDeployment`](../commands/resume.md).

## Reboots

Stages that require a reboot (Vault and PVWA hardening, PSM's installation passes, AD promotion) record the boot ID
before and after the reboot. The run continues only after the new boot is confirmed.
