# Troubleshooting

Real problems met while building labs, and their fixes. Start with the event log on [step 6](../gui/install.md) or with
these commands. The failing step and its message are usually enough.

```powershell
Get-PASRun                                # all runs, newest first
Get-PASRun -RunId <id>                    # one run: status, components, latest events
Get-PASRunEvent -RunId <id> -Failed       # what failed
Get-PASRunLog -RunId <id>                 # the controller journal of the run
Test-PASPreflight -Path .\Lab01.json      # are the servers reachable and ready?
```

After you corrected the cause, continue the same run. A step that failed is not repeated on its own; name it:

```powershell
Resume-PASRun -RunId <id>                           # check finished components, install the rest
Resume-PASRun -RunId <id> -RetryStep cpm01:install  # also execute this failed step again
```

More: [Durable runs and resume](../concepts/durable-runs.md).

## WinRM: "Access is denied" with `Administrator`

**Symptom:** testing WinRM by hand with the user name `Administrator` fails from the controller, while the same
password works on the console.

**Cause:** the controller has its own local `Administrator`, and a bare name is matched against the controller first.

**Fix:** use `.\Administrator` (or `SERVERNAME\Administrator`). PASeasyInstall does this automatically for plain
account names. Keep the plain name `Administrator` in the configuration, because the Vault's management endpoint
requires an unqualified local account name.

## "PAExecLocked: server … is locked by run …" (run status Blocked)

**Cause:** an earlier run started on this server and did not finish. It left its **target lock** there on purpose,
so that no other run touches a half-installed server. The message names the run that holds the lock and the lock
folder.

**Fix:** choose one:

- The earlier run can continue: `Resume-PASRun -RunId <that run id>`.
- You will not continue it (for example you reset or rebuilt the servers): give it up and release its locks with
  `Stop-PASRun -RunId <that run id> -CredentialMap $creds`. Without `-CredentialMap` it lists the lock folders
  instead.
- That run no longer exists on this controller: delete the lock folder named in the message on that server
  (Windows: `locks\<server>` under `C:\ProgramData\PASeasyInstall` or `C:\ProgramData\PAExec`; Linux:
  `~/.paeasyinstall/locks/<server>`).

Then resume the blocked run. See [Coordination and locks](../concepts/coordination.md).

!!! note
    The 1.0 message "Unreconciled resource 'environment-…'" no longer exists. A stopped run does not block a new
    run on the controller any more; only the lock on the server does.

## "Vault … is in use by another PASeasyInstall controller on this machine"

**Cause:** another run on this controller holds the Vault lock: it is working with an authenticated Vault session
(a registration, a PACLI step or a health check). The step waited three minutes.

**Fix:** wait until the other run has finished that step, then `Resume-PASRun -RunId <id>`.

## "Vault media VCx86: Missing"

**Cause:** the media folder doesn't contain the VC++ x86 redistributable, or the folder points one level too deep
(for example `…\CorePAS` inside an extracted bundle).

**Fix:** put `VC_redist.x86.exe` and `VC_redist.x64.exe` next to the installers, and add the top-level media folder.

## "Several copies of the VC++ runtime were found"

**Cause:** the media folder you added holds more than one `VC_redist.x86.exe` / `VC_redist.x64.exe` (for example a
copy inside a subfolder). The Vault recipe needs exactly one of each.

**Fix:** keep one copy next to the Vault installers. Separate media folders for different product versions side by
side are fine: add only the folder of the version you install.

## "The controller could not be started … Windows DPAPI"

**Cause:** the deployment was started from a remote PowerShell session (`Enter-PSSession` / `Invoke-Command`). The
background installer receives credentials encrypted with Windows DPAPI, which is not available in such sessions.

**Fix:** start `Start-PASeasyInstall` or the `Install-PAS*` command in a local session on the controller (console or
RDP). A scheduled task that runs as the user with a stored password also works.

## "Environment '…' is being deployed right now by run …"

**Cause:** another run of the same environment has a live controller process on this controller.

**Fix:** wait for it (`Wait-PASRun -RunId <id>`), or stop it with `Stop-PASRun -RunId <id> -Force`. A run whose
controller never started or is no longer running is detected automatically and does not block a new start.

## PVWA: "PASWS383E Vault is currently under maintenance mode"

**Cause:** PVWA started while the Vault was still booting (for example after both were restarted together), and kept
that state.

**Fix:** on the PVWA server, recycle the application pool:

```powershell
Import-Module WebAdministration; Restart-WebAppPool PasswordVaultWebAccessPool
```

Next time, start the Vault first and PVWA once the Vault is up.

## Component password changes fail with CASTM057E

**Message:** `CASTM057E Password has not yet been replicated to DR site(s)`.

**Cause:** with a DR Vault configured, the Vault rotates component passwords only after DR has replicated them, and
the DR Vault is stopped.

**Fix:** start the DR Vault. It catches up within one replication cycle.

## Linux: "signs in to Linux servers as root, but … is not root"

**Cause:** the account entered for the Linux server is not `root`. The installation writes system packages,
services and `/opt/paeasyinstall`, so it runs as root.

**Fix:** use `root`. If the server's image blocks root sign-in, allow it while you install (a root password and
`PermitRootLogin yes` in `/etc/ssh/sshd_config.d/`), or authorise the controller key for root. See
[Prerequisites](../servers/prerequisites.md#psmp-linux).

## PSMP preflight: "unzip required"

**Cause:** the server has no `unzip`, and the preflight could not install it from the OS repositories (it does so
automatically when they are reachable).

**Fix:** make the OS repositories reachable (or `apt-get install -y unzip` on the PSMP server), then resume the run
with `Resume-PASRun -RunId <id> -RetryFailedPreflight`.

## PSMP register: "User [PSMPApp_<host>] already exists in the Vault"

**Cause:** PASeasyInstall lets the vendor setup recreate the credential files of an existing PSMP server's users, so a
rebuilt server re-registers by itself. This message means the setup still refused, for example because another PSMP
server with the same hostname is registered and running.

**Fix:** give each PSMP server a unique hostname. If the old server is gone, remove its `PSMPApp_<host>`,
`PSMPGW_<host>` and `PSMP_ADB_<host>` users in PVWA (**Administration → Users**), then start the deployment again.

## Recordings not visible: "PSMRecordings" not found

**Cause:** the recordings safe is visible only to Vault **Auditors** members, and it exists only after the first
recorded session.

**Fix:** sign in as the built-in `Auditor` user, or add your reviewer to the Auditors group.

## PSMP: "Accept the CyberArk license agreement (EULA) for the PSMP installer"

**Cause:** the CyberArk EULA for PSMP was not accepted.

**Fix:** tick the license checkbox on [step 2](../gui/what-to-install.md), or use `-AcceptEula` with
`New-PASLabConfiguration` or `Install-PASPSMP`. The rule is checked when the configuration is validated, before
anything is installed.

## A component shows "not logged on" in the health check

The server is stopped, cannot reach the Vault on port 1858, or the Vault restarted underneath it. Check the
component's service, then the network. For PVWA, see the maintenance-mode entry above.

## The controller closed or rebooted during an installation

Nothing to do in a hurry. The stage keeps running on the target. Check the run with
`Get-PASRun -RunId <id>`. If its status is Interrupted, resume it with `Resume-PASRun -RunId <id>`. The finished and
running attempts are reconciled and never repeated.

## Getting help

Export the run with [`Export-PASDiagnostics -RunId <id>`](../commands/checks.md#export-pasdiagnostics) and attach it to an issue on
[GitHub](https://github.com/bigbatmanorg/PASeasyInstall/issues). It contains no passwords.
