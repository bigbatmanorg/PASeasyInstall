# Run commands

An installation is a **run**. It executes in its own process on the controller and has a run id of 32
characters. These commands list, follow, continue and give up runs. They read the files of the run; only
`Resume-PASRun` and `Stop-PASRun -CredentialMap` contact servers.

See also [Runs and resume](../concepts/durable-runs.md) and [Locks](../concepts/coordination.md).

The text of every command below is its own help (`Get-Help <command> -Full`).

| Command | What it does |
|---|---|
| [`Get-PASRun`](#get-pasrun) | Lists the installation runs of this controller, or shows one run with its components and events. |
| [`Get-PASRunEvent`](#get-pasrunevent) | Returns the progress events of a run, oldest first. |
| [`Wait-PASRun`](#wait-pasrun) | Follows a run until it ends: prints its progress events as they arrive and returns the final run. |
| [`Resume-PASRun`](#resume-pasrun) | Continues a run that stopped: finished components are checked again, the remaining ones are installed. |
| [`Stop-PASRun`](#stop-pasrun) | Abandons a run, retaining target locks unless the lab machines were reset. |

## Get-PASRun

Lists the installation runs of this controller, or shows one run with its components and events.

Without -RunId: one line per run, newest first, with RunId, Name (the environment), Status, StartedUtc, FinishedUtc and Message.

With -RunId: the run in detail, with RunId, Name, Status, CurrentComponent, Message, LastStep, StartedUtc, FinishedUtc, CompletedEvents, ErrorEvents, Components (Id, Type, Status, Message), Events (the last -Tail events, see Get-PASRunEvent), OperationallyVerified and RunDirectory (the folder that holds the run's files).

Status of a run: Launching or Running while the controller works; Succeeded; or stopped as Failed, Unknown (an outcome on a server could not be determined), Blocked, Interrupted (the controller process ended), LaunchFailed or Abandoned (see Stop-PASRun). A stopped run is continued with Resume-PASRun. Succeeded means every installer step finished and was verified; Test-PASHealth checks that the lab works end to end.

Reads local files only. No server is contacted.

| Parameter | Meaning |
|---|---|
| `-RunId` | Run id (32 hexadecimal characters), as returned by the Install-* commands. |
| `-Tail` | With -RunId: how many of the latest events to include (1 to 1000). Default 150. |
| `-Last` | Without -RunId: only the newest &lt;n&gt; runs. |

```powershell
Get-PASRun | Format-Table RunId, Name, Status, StartedUtc
```

Lists all runs.

```powershell
Get-PASRun -RunId 688d8e04f1874d41a75cda4441c00553 | Format-List Status, CurrentComponent, LastStep, Message
```

```powershell
(Get-PASRun -Last 1 | Get-PASRun).Components | Format-Table Id, Type, Status, Message
```

Shows the components of the newest run.

## Get-PASRunEvent

Returns the progress events of a run, oldest first.

Each event has TimestampUtc, RunId, Component (the component id of the configuration), Stage (the step), Event (its type, e.g. TaskStarted, TaskCompleted), Level (Information, Warning or Error), Status (Running, Complete, Failed, Warning or Info), Source (Controller or Engine), Message and Sequence.

The events of the controller and of every component are merged. Reads local files only.

| Parameter | Meaning |
|---|---|
| `-RunId` | Run id (32 hexadecimal characters). |
| `-Tail` | How many of the latest events to read (1 to 1000). Default 150. |
| `-Failed` | Only the events whose Status is Failed. |

```powershell
Get-PASRunEvent -RunId 688d8e04f1874d41a75cda4441c00553 -Tail 50 | Format-Table TimestampUtc, Component, Stage, Status, Message
```

```powershell
Get-PASRun -Last 1 | Get-PASRunEvent -Tail 1000 -Failed | Format-List Component, Stage, Message
```

Shows what failed in the newest run.

## Wait-PASRun

Follows a run until it ends: prints its progress events as they arrive and returns the final run.

Every new event is written to the console as one line: local time, component, step, status, message. When the run reaches a final status the same object Get-PASRun -RunId returns is returned. Final statuses: Succeeded, Failed, LaunchFailed, Unknown, Interrupted, Blocked, Abandoned.

Waiting does not influence the run. You can stop waiting with Ctrl+C at any time: the installation continues in its own process, and Wait-PASRun can be started again later. When started again it first prints the latest (up to 1000) events of the run.

| Parameter | Meaning |
|---|---|
| `-RunId` | Run id (32 hexadecimal characters). |
| `-PollSeconds` | Seconds between two looks at the run (1 to 600). Default 15. |
| `-Quiet` | Prints nothing; only waits and returns the final run. |

```powershell
Wait-PASRun -RunId 688d8e04f1874d41a75cda4441c00553
```

```powershell
$run = Install-PASLab -Path .\MyLab.json | Wait-PASRun -Quiet
if ($run.Status -ne 'Succeeded') { $run.Components | Where-Object Status -ne 'Succeeded' }
```

Waits silently and shows the components that did not succeed.

## Resume-PASRun

Continues a run that stopped: finished components are checked again, the remaining ones are installed.

Works on a run whose status is Failed, Unknown, Interrupted, LaunchFailed or Blocked. The run keeps its own copy of the configuration and its plan; they are used again unchanged, and so must the installer media be.

What happens on resume:

- steps that finished are verified again, not repeated;
- a step that was still running on a server is picked up where it is, never started a second time;
- a step that ended Failed or Unknown is NOT repeated on its own. Look at the server and at Get-PASRunEvent -Failed, correct the cause, then name the step with -RetryStep.

The command checks the run and asks for confirmation. Only then it asks for the server accounts and passwords of the run's configuration that -CredentialMap, -SecretMap or -LabPassword do not supply (passwords are never stored, so they are needed again). With -WhatIf nothing is asked.

| Parameter | Meaning |
|---|---|
| `-RunId` | Run id (32 hexadecimal characters). |
| `-RetryStep` | Steps to execute again, as '&lt;step&gt;' or '&lt;component&gt;:&lt;step&gt;', e.g. 'install' or 'cpm01:register'. Only steps that ended Failed or Unknown are accepted. Get-PASStageCatalog lists the step names. |
| `-RetryFailedPreflight` | Runs a failed read-only preflight of a Linux server again, for example after you installed a missing package there. |
| `-CredentialMap` | Server accounts: @{ &lt;server id&gt; = PSCredential }. Missing ones are asked for. |
| `-SecretMap` | Passwords as SecureString: @{ VaultAdmin = ...; VaultMaster = ...; DRPassword = ...; ADSafeMode = ...; DomainJoinPassword = ... }. Missing ones are asked for. |
| `-LabPassword` | One password for every server and every secret that is not supplied otherwise. Only for a run with the Lab security profile. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PollSeconds` | With -Wait: seconds between two progress checks. Default 15. |

```powershell
Resume-PASRun -RunId 688d8e04f1874d41a75cda4441c00553 -Wait
```

Asks for the accounts and passwords again, continues the run and shows the progress.

```powershell
Resume-PASRun -RunId $id -RetryStep 'pvwa01:install' -LabPassword $lab
```

Continues a lab run and executes the failed install step of pvwa01 again.

```powershell
Get-PASRun -Last 1 | Resume-PASRun -RetryFailedPreflight -Wait
```

## Stop-PASRun

Abandons a run, retaining target locks unless the lab machines were reset.

A run that stopped (Failed, Unknown, Blocked, Interrupted, LaunchFailed) keeps a lock folder on every server it did not finish, so that no other run touches a half-installed server. Stop-PASRun marks the run abandoned, but keeps the locks by default. A detached remote worker can outlive its controller. Restore or rebuild affected VMs before explicitly releasing the locks.

- A run that is still running is refused, unless you add -Force: then the controller process of this run is stopped first.
- The run is marked Abandoned. An abandoned run cannot be resumed.
- Pass -ReleaseLocksAfterReset AND -CredentialMap only after restoring/rebuilding the affected lab VMs. Locks still held by another run are never released. Without both parameters the locks remain.

No installed software is changed or removed: a server may be left with a partial installation.

Returns RunId, Status, PreviousStatus, ControllerStopped and Locks (Target, Computer, LockFolder, Released, Message).

| Parameter | Meaning |
|---|---|
| `-RunId` | Run id (32 hexadecimal characters). |
| `-CredentialMap` | Server accounts for explicit -ReleaseLocksAfterReset cleanup: @{ &lt;server id&gt; = PSCredential }. |
| `-Force` | Stops the controller only; detached workers may continue and target locks stay. |
| `-ReleaseLocksAfterReset` | Explicitly release locks after all affected lab targets have been reset/rebuilt. Not safe otherwise. |

```powershell
Stop-PASRun -RunId 83cf015f78bd4743a54e6d0a9d0dd301 -CredentialMap @{ vault01 = (Get-Credential Administrator) }
```

Gives up a failed run but leaves the remote target locks in place.

```powershell
Get-PASRun | Where-Object Status -eq 'Running' | Stop-PASRun -Force
```

Stops every running installation after asking for confirmation, and lists the lock folders.
