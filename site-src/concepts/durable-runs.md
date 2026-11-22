# Runs and resume

A lab installation takes tens of minutes and restarts servers. PASeasyInstall assumes that the controller can be
closed, restarted or cut off from the network at any moment.

## A run

An installation is a **run**. `Install-PASLab` and the other install commands start a controller process of
their own and return a run id of 32 characters. The run keeps going when you close the prompt or the window.

Its files are in `%LOCALAPPDATA%\PASeasyInstall\Runs\<run id>` on the controller: the configuration and the plan
it installs, its events, and one folder per server with that server's journal. They contain no password.

## Attempts

Every step that changes a server is started there as an **attempt** with its own id: a scheduled task on Windows,
a systemd unit on Linux, with a folder of its own on the server. The attempt writes its state down on the
server. The controller watches it, and when it has finished, **verifies** the result with a separate, read-only
check. A step counts only when that check passed: an installer that ended without an error is not proof.

Because the attempt lives on the server, it does not need the controller. If the controller disappears, the
step continues, and the run finds it again by its id.

## The state of a run

| State | Meaning |
|---|---|
| Launching, Running | The controller process is working |
| Succeeded | Every step finished and was verified |
| Failed | A step failed. Nothing was repeated |
| Unknown | What happened to a step on a server could not be found out |
| Blocked | A server is locked by another run ([Locks](coordination.md)) |
| Interrupted | The controller process ended without recording an outcome |
| LaunchFailed | The controller process never started, or stopped before any server was contacted |
| Abandoned | Given up with `Stop-PASRun`. Cannot be continued |

Succeeded means the installation steps were verified. Whether the lab works as a whole is what
[`Test-PASHealth`](../commands/checks.md#test-pashealth) and *Check the lab* tell you.

## Resume

```powershell
Resume-PASRun -RunId <run id>
```

Works for a run that is Failed, Unknown, Blocked, Interrupted or LaunchFailed. It uses the configuration and the
plan the run saved when it started, and asks for the accounts and passwords again, because they are never
stored. What happens then is decided by what the journals and the servers say:

- a step that finished is checked again, read-only, and not repeated;
- a step that is still running on a server is waited for, also after the controller crashed;
- a step that was started is found again by its id. It is never started a second time;
- a step that ended **Failed** or **Unknown** is **not** repeated on its own.

In a run that installs the servers at the same time, resume starts every lane again.

## Repeating a failed step

Look at the failed event first, then at the server. Correct the cause. Then name the step:

```powershell
Get-PASRunEvent -RunId <run id> -Failed | Format-List Component, Stage, Message
Resume-PASRun -RunId <run id> -RetryStep cpm01:install     # the step install of the component cpm01
Resume-PASRun -RunId <run id> -RetryStep install           # the step install wherever it failed
```

Only steps whose journal says Failed or Unknown are accepted; any other name is an error, so nothing is repeated
by accident. `Get-PASStageCatalog` lists the step names of a component type. In the window this is the button
**Try this step again**.

`-RetryFailedPreflight` runs a failed read-only check of a Linux server again, for example after you installed a
missing package there.

!!! warning "Why not simply run it again?"
    An installer whose outcome is not known may have changed the server halfway. Running it twice can break what
    the first run did. So the decision to repeat a step is yours, after you looked.

## What may change between start and resume

- **The configuration and the installers may not change.** Resume compares them with what the run saved and
  refuses a difference. Start a new run instead.
- **The scripts of a server may not change either.** Each server's steps and scripts are fixed when the server
  is first worked on. PVWA, CPM, PSM and the Linux components run from copies kept with the run; the Vault steps
  are read from the module, so after an update of PASeasyInstall a run that stopped in the Vault part cannot be
  continued. Reset that server and start a new run.

## Restarts of a server

Steps that restart a server (hardening of the Vault, the stages of PSM, the promotion of a domain controller, a
domain join) write down the boot of the server before and after. The run goes on only when the new boot is
confirmed.

## Giving a run up

```powershell
Stop-PASRun -RunId <run id> -CredentialMap $creds
```

marks the run Abandoned and releases the locks it holds on the servers. No installed software is removed. Use
it when you will not continue the run, typically after you reset the servers. See [Locks](coordination.md).
