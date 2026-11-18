# Get-PASEnvironmentSnapshot / Get-PASEnvironmentEvents

## Get-PASEnvironmentSnapshot

Status of a deployment and its most recent events, read from the controller's journals. This is what the progress view
on [step 6](../gui/install.md) renders.

!!! note "A run snapshot, not a server snapshot"
    "Snapshot" here means a point-in-time view of a deployment run's status. PASeasyInstall does not create or manage
    server or virtual-machine snapshots.

```powershell
Get-PASEnvironmentSnapshot -RunId <id> [-Tail <n>]
```

```powershell
PS> Get-PASEnvironmentSnapshot -RunId 5a56f02b26444683bb4dc1a61ed114a2 | Format-List RunId,Status,Message,LastStep,CompletedEvents,ErrorEvents

RunId           : 5a56f02b26444683bb4dc1a61ed114a2
Status          : Succeeded
Message         : All selected component workflows completed
LastStep        : verify
CompletedEvents : 10
ErrorEvents     : 0
```

`Status` is `Launching`, `Running`, `Succeeded`, `Failed`, `Unknown` or `Interrupted`. Each event has
`TimestampUtc`, `Component`, `Stage`, `Event`, `Level`, `Status` (`Running`, `Complete`, `Failed`,
`Warning` or `Info`) and `Message`.

## Get-PASEnvironmentEvents

The events alone, oldest first.

```powershell
Get-PASEnvironmentEvents -RunId <id> [-Tail <n>]
```

### Real example: a PVWA installation

Every stage is a recorded *attempt* (a scheduled task as SYSTEM on the target, or a direct WinRM call) that is
verified independently before the next stage starts.

```text
Time (UTC)   Stage          Event             Message
----------   -----          -----             -------
17:06:16                    RunStarted        Workflow PVWA pvwa started on WinRM/WindowsPowerShell (PowerShell 5.1.20348.5773)
17:06:18                    TargetLocked      remote target lease acquired
17:06:18     management     TaskStarted       Script/Detached attempt 6a43a58ef9c24978b03cef4b0fc940f3
17:06:20     management     DetachedLaunched  scheduled task PAExec-6a43a58ef9c24978b03cef4b0fc940f3 launched as SYSTEM
17:06:33     management     DetachedStatus    remote attempt 6a43a58ef9c24978b03cef4b0fc940f3 is Succeeded
17:06:34     management     TaskVerified      Endpoint=PASeasyInstall.Management; ManagementSID=S-1-5-21-…-500; ExactSIDOnlyACL=True :: Man...
17:06:34     management     TaskCompleted     Succeeded: Restricted management endpoint PASeasyInstall.Management verified for S-1-5-21-…-5...
17:06:34     media-upload   TaskStarted       Transfer/Direct attempt 056b28eaf3434be0a1f7de407ec29626
17:06:34     media-upload   TransferStarted   uploading 314.5 MiB
17:07:37     media-upload   TransferVerified  SHA-256 3BD434154A6B17D45397790727B43BA2E288AEEF41D52C3D7BDC392ED5E7D860 verified on target a...
17:07:37     media-upload   TaskCompleted     Succeeded
17:07:37     preflight      TaskStarted       Script/Direct attempt c27c4cdc75c7432e90ff23f52efe5777
17:07:38     preflight      TaskVerified      Staged installer media exists :: PVWA Preflight check passed
17:07:38     preflight      TaskCompleted     Succeeded: PVWA host preflight successful
17:07:38     extract        TaskStarted       Script/Detached attempt 83744218dcc246a094412ae2466da2f9
17:07:39     extract        DetachedLaunched  scheduled task PAExec-83744218dcc246a094412ae2466da2f9 launched as SYSTEM
17:07:50     extract        DetachedStatus    remote attempt 83744218dcc246a094412ae2466da2f9 is Succeeded
17:07:50     extract        TaskVerified       :: PVWA Extract check passed
17:07:50     extract        TaskCompleted     Succeeded: Media extracted and scripts located
17:07:50     prerequisites  TaskStarted       Script/Detached attempt 0e115b0ed7c54b97b3f0195d15822bdd
17:07:51     prerequisites  DetachedLaunched  scheduled task PAExec-0e115b0ed7c54b97b3f0195d15822bdd launched as SYSTEM
17:08:02     prerequisites  DetachedStatus    remote attempt 0e115b0ed7c54b97b3f0195d15822bdd is Running
17:12:48     prerequisites  DetachedStatus    remote attempt 0e115b0ed7c54b97b3f0195d15822bdd is Succeeded
17:12:48     prerequisites  TaskVerified      VC x86 v14.32.31332.00; VC x64 v14.32.31332.00; All 29 required Windows features installed ::...
17:12:48     prerequisites  TaskCompleted     Succeeded: PVWA prerequisites completed
17:12:49     install        TaskStarted       Script/Detached attempt a6b691319d944a6faba957d1bdff89f5
17:12:49     install        DetachedLaunched  scheduled task PAExec-a6b691319d944a6faba957d1bdff89f5 launched as SYSTEM
17:13:00     install        DetachedStatus    remote attempt a6b691319d944a6faba957d1bdff89f5 is Running
17:13:20     install        DetachedStatus    remote attempt a6b691319d944a6faba957d1bdff89f5 is Succeeded
17:13:21     install        TaskVerified      CyberArk Scheduled Tasks=Stopped :: PVWA Install check passed
17:13:21     install        TaskCompleted     Succeeded: PVWA installed; discovered 1 services
17:13:21     configuretls   TaskStarted       Script/Detached attempt fb92e68687774858ad827c98e39d76a1
17:13:22     configuretls   DetachedLaunched  scheduled task PAExec-fb92e68687774858ad827c98e39d76a1 launched as SYSTEM
17:13:32     configuretls   DetachedStatus    remote attempt fb92e68687774858ad827c98e39d76a1 is Succeeded
17:13:33     configuretls   TaskVerified      System.Collections.Hashtable
17:13:33     configuretls   TaskCompleted     Succeeded: SECURITY DEVIATION: explicit Lab PVWA self-signed certificate bound and trusted on...
17:13:33     register       VaultOperationAdmitted Exclusive authenticated operation admitted; independent OS installation holds no Vault sessio...
17:13:33     register       TaskStarted       Script/Detached attempt 38781da63bfa4daba4ff88b3ad7b5e35
17:13:34     register       DetachedLaunched  scheduled task PAExec-38781da63bfa4daba4ff88b3ad7b5e35 launched as SYSTEM
17:13:44     register       DetachedStatus    remote attempt 38781da63bfa4daba4ff88b3ad7b5e35 is Running
17:14:04     register       DetachedStatus    remote attempt 38781da63bfa4daba4ff88b3ad7b5e35 is Succeeded
17:14:05     register       TaskVerified      Vendor stage completed; independent API authentication not yet tested :: PVWA Register check ...
17:14:05     register       TaskCompleted     Succeeded: PVWA registration attempted; verify service and connectivity separately
17:14:06     harden         TaskStarted       Script/Detached attempt 13d29752c7de402b802cec5fee3e1fed
17:14:06     harden         DetachedLaunched  scheduled task PAExec-13d29752c7de402b802cec5fee3e1fed launched as SYSTEM
17:14:17     harden         DetachedStatus    remote attempt 13d29752c7de402b802cec5fee3e1fed is Running
17:16:01     harden         DetachedStatus    remote attempt 13d29752c7de402b802cec5fee3e1fed is Succeeded
17:16:03     harden         TaskVerified      RemoteAccess=Disabled; SCardSvr=Disabled; SCPolicySvc=Disabled; SNMPTRAP=Disabled; sacsvr=Dis...
17:16:03     harden         TaskCompleted     Succeeded: PVWA hardening stage completed
17:16:03     verify         TaskStarted       Verify/Direct attempt 8297dda7efbc4a8bba2c4d85464bce98
17:16:04     verify         TaskVerified      System.Collections.Hashtable; CyberArk Scheduled Tasks=Running :: PVWA Verify check passed
17:16:04     verify         TaskCompleted     Succeeded
17:16:04                    RunCompleted      Workflow finished and verified
```
