# Coordination and locks

There are three locks, and only three.

| Lock | Where | Prevents | Released |
|---|---|---|---|
| **Run lock** | `controller.lock` in the run folder on the controller, held open by the run's controller process | Two controller processes working on the same run | When the process ends, always |
| **Target lock** | A folder on each server that names the run id: `locks\<server>` under the toolkit's stage root (Windows) or `~/.paeasyinstall/locks/<server>` (Linux) | Two runs changing the same server | When the workflow on that server **succeeds**, or by `Stop-PASRun` |
| **Vault lock** | A named mutex on the controller, one per Vault address | Two authenticated Vault sessions (registrations, PACLI, health check) at the same time | After every step, also when it fails |

A new run for an environment name is refused only while another run of that name has a **live** controller process.
Failed, Unknown, Interrupted, Blocked and Abandoned runs do not block a new run on the controller. What protects a
half-installed server is its target lock.

## The target lock stays after a failure

This is on purpose. A run that failed has left a server in a state only that run knows about. The same run takes the
lock again when you resume it. A different run that reaches the server stops with status **Blocked** and this message:

```text
PAExecLocked: server 10.10.0.22 ('pas-cpm') is locked by run <run id>. Either resume that run
(Resume-PASRun -RunId <run id>), or release it (Stop-PASRun -RunId <run id>), or, if that run no longer
exists on this controller, delete the lock folder <folder> on 10.10.0.22.
```

## How to release a target lock

- **Resume the owning run** if you want to finish it: `Resume-PASRun -RunId <run id>`.
- **Give the run up** if you will not finish it (for example you rebuilt the servers):

    ```powershell
    Stop-PASRun -RunId <run id> -CredentialMap $creds
    ```

    The run is marked **Abandoned**. With `-CredentialMap` the lock of every unfinished server is removed, if it
    still names this run. Without it nothing is contacted and the lock folders to delete are listed. A server that
    cannot be reached becomes a warning. No installed software is changed or removed.

- **The run no longer exists on this controller:** delete the lock folder named in the message on that server.

`Stop-PASRun` refuses a run whose controller is still working. `-Force` stops that controller process first, and only
the process that is provably this run's controller.

## The Vault lock leaves nothing behind

The Vault lock is a mutex in memory. It is always released, also after a failure, and it leaves no files. If another
installation on the same controller holds it for more than three minutes, the waiting step fails with
`Vault <address> is in use by another PASeasyInstall controller on this machine`. Wait until the other run has
finished, then resume.
