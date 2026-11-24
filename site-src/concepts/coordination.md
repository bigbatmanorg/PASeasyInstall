# Locks

Three locks keep installations out of each other's way.

| Lock | Where | Prevents | Released |
|---|---|---|---|
| **Run lock** | `controller.lock` in the run folder on the controller, held open by the controller process of the run | Two processes working on the same run | When the process ends, always |
| **Target lock** | A folder on each server that names the run id | Two runs changing the same server | When that server's work finishes successfully. After a failure or a stop it stays; see below |
| **Vault lock** | A named mutex on the controller, one per Vault address | Two sign-ins to the Vault at the same time | After every step that signs in, also when it fails |

A run that installs the servers at the same time adds nothing that outlives it: its lanes wait for each other
through signals inside the one controller process ([Servers at the same time](parallel.md#signals)), and use one
short-lived mutex of the run while they prepare shared files (the SSH known-hosts file, the PVWA certificates).

A new run for a lab name is refused only while another run of that name has a live controller. Runs that
stopped do not block a new run. What protects a half-installed server is its target lock.

## The target lock stays after a failure

On purpose. A run that failed left a server in a state only that run knows about. The same run takes the lock
again when you resume it. Another run that reaches the server stops as **Blocked**:

```text
PAExecLocked: server 192.0.2.22 ('cpm01') is locked by run <run id>. Either resume that run
(Resume-PASRun -RunId <run id>), or abandon it (Stop-PASRun -RunId <run id>) and, once the server is
restored, release its locks (Stop-PASRun -RunId <run id> -ReleaseLocksAfterReset -CredentialMap <accounts>),
or, if that run no longer exists on this controller, delete the lock folder <folder> on 192.0.2.22.
```

On a Linux server that the other run already hardened, the sign-in with the password may fail before the lock
can be read. The run then says which unfinished run of this controller holds the server:
`PAExecLocked: server ... is still locked by run <run id> of this controller ...`.

## Stop-PASRun keeps the locks

```powershell
Stop-PASRun -RunId <run id>
```

marks the run **Abandoned** and lists the lock folders it leaves. It contacts no server, and it keeps every
target lock. An abandoned run cannot be continued. No installed software is changed or removed.

`Stop-PASRun` refuses a run that is still working. With `-Force` it first ends the controller process of that
run, and only a process whose id and start time match the run. The steps that were already started on the
servers (scheduled tasks, systemd units) do not depend on the controller and may go on. That is why the locks
stay with `-Force` too.

## Releasing a target lock

- **Continue the run that holds it:** `Resume-PASRun -RunId <run id>`.
- **After you reset or rebuilt the servers of that run** (for example from a clean snapshot):

    ```powershell
    Stop-PASRun -RunId <run id> -ReleaseLocksAfterReset -CredentialMap $creds
    ```

    It signs in to each server the run locked and removes the lock folder only when it names this run. A lock
    of another run is left alone and named in the result. On a Linux server it authorises the controller key
    again with the password from `-CredentialMap`, because a reset server no longer knows that key.
    `-ReleaseLocksAfterReset` without `-CredentialMap` is refused. Use it only after the reset: the
    command cannot prove that nothing is still running on a server.

- **The run no longer exists on this controller:** make sure nothing of it still runs on the server (or reset
  the server), then delete the lock folder by hand. On Windows it is `locks\<server>` under
  `C:\ProgramData\PASeasyInstall` (components) or `C:\ProgramData\PAExec` (Vault); on Linux
  `~/.paeasyinstall/locks/<server>`.

A server reset to a snapshot from before the installation has no lock any more.

## The Vault lock

Every step that signs in to the Vault (a registration, a check with PACLI, gateway registration, the lab check)
takes the Vault lock first and gives it back when its session is closed, also after a failure. It is a named
mutex of the controller computer (`Global\PASeasyInstall-Vault-<address>`) and leaves no file.

- Inside one run, the servers wait for their turn for up to four hours; that is the queue of the
  registrations ([order](parallel.md#one-sign-in-to-the-vault-at-a-time)).
- Between two runs on the same controller, a step waits three minutes and then fails with
  `Vault <address> is in use by another PASeasyInstall controller on this machine`. Wait until the other run is
  past that step, then resume.
- `Test-PASHealth` waits up to 60 seconds for it.
