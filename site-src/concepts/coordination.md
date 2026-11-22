# Locks

Three locks keep installations out of each other's way.

| Lock | Where | Prevents | Released |
|---|---|---|---|
| **Run lock** | A file in the run folder on the controller, held open by the controller process of the run | Two processes working on the same run | When the process ends, always |
| **Target lock** | A folder on each server that names the run id | Two runs changing the same server | When that server is finished successfully, or by `Stop-PASRun` |
| **Vault lock** | In memory on the controller, one per Vault address | Two sign-ins to the Vault at the same time | After every step, also when it fails |

A run that installs the servers at the same time uses nothing more that outlives it: its lanes wait for each
other inside the one controller process ([Servers at the same time](parallel.md)).

A new run for a lab name is refused only while another run of that name is working. Runs that stopped do not
block a new run on the controller. What protects a half-installed server is its target lock.

## The target lock stays after a failure

On purpose. A run that failed left a server in a state only that run knows about. The same run takes the lock
again when you resume it. Another run that reaches the server stops as **Blocked** with this message:

```text
PAExecLocked: server 192.0.2.22 ('cpm01') is locked by run <run id>. Either resume that run
(Resume-PASRun -RunId <run id>), or release it (Stop-PASRun -RunId <run id>), or, if that run no longer
exists on this controller, delete the lock folder <folder> on 192.0.2.22.
```

## Releasing a target lock

- **Continue the run that holds it:** `Resume-PASRun -RunId <run id>`.
- **Give that run up**, for example because you reset the servers:

    ```powershell
    Stop-PASRun -RunId <run id> -CredentialMap $creds
    ```

    The run is marked Abandoned. With `-CredentialMap` the lock of every unfinished server is removed, if it
    still names this run. Without it no server is contacted, and the lock folders to delete are listed. A server
    that cannot be reached becomes a warning. No installed software is changed or removed.

- **The run no longer exists on this controller:** delete the lock folder the message names. On Windows it is
  `locks\<server>` under `C:\ProgramData\PASeasyInstall` (components) or `C:\ProgramData\PAExec` (Vault); on
  Linux `~/.paeasyinstall/locks/<server>`.

A server you reset to its clean state has no lock any more.

`Stop-PASRun` refuses a run that is still working. With `-Force` it ends the controller process of that run
first, and only the process that is provably this run's controller.

## The Vault lock

Every step that signs in to the Vault (a registration, a check with PACLI, the lab check) takes the Vault lock
first and gives it back when its session is closed, also after a failure. It leaves no file.

- Inside one run, the components wait for their turn without a time limit; that is the queue of the
  registrations.
- Between two runs on the same controller, a step waits three minutes and then fails with
  `Vault <address> is in use by another PASeasyInstall controller on this machine`. Wait until the other run is
  past that step, then resume.
