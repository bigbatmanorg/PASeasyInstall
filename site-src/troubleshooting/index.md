# Troubleshooting

Real problems met while building labs, and their fixes. Start with the event log on [step 6](../gui/install.md) or
`Get-PASEnvironmentEvents -RunId <id>`. The failing stage and its message are usually enough.

## WinRM: "Access is denied" with `Administrator`

**Symptom:** testing WinRM by hand with the user name `Administrator` fails from the controller, while the same
password works on the console.

**Cause:** the controller has its own local `Administrator`, and a bare name is matched against the controller first.

**Fix:** use `.\Administrator` (or `SERVERNAME\Administrator`). PASeasyInstall does this automatically for plain
account names. Keep the plain name `Administrator` in the configuration, because the Vault's management endpoint
requires an unqualified local account name.

## "Unreconciled resource 'environment-…'" or "PAExecLocked"

**Cause:** a previous run of the same environment failed, and its claims and locks are kept until it is reconciled.
See [Coordination and locks](../concepts/coordination.md).

**Fix:** resume that run. If it provably dispatched nothing (for example it failed during validation), remove only
that run's claim files from `C:\ProgramData\PASeasyInstall-Coordination` and, on Linux targets, the lock folder
`~/.paeasyinstall/locks/<host>` whose `owner` file contains that run ID.

## "Vault media VCx86: Missing"

**Cause:** the media folder doesn't contain the VC++ x86 redistributable, or the folder points one level too deep
(for example `…\CorePAS` inside an extracted bundle).

**Fix:** put `VC_redist.x86.exe` and `VC_redist.x64.exe` next to the installers, and add the top-level media folder.

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

## PSMP preflight: "unzip required"

**Cause:** Ubuntu cloud images don't ship `unzip`.

**Fix:** `apt-get install -y unzip` on the PSMP server, then resume the run with `-RetryFailedPreflight`.

## PSMP install: "Options.acceptEula=true required"

**Cause:** the CyberArk EULA for PSMP was not accepted.

**Fix:** tick the license checkbox on [step 2](../gui/what-to-install.md), or use `-AcceptEula` with
`New-PASDeploymentConfiguration`. Resume reuses the frozen configuration, so start a new run.

## A component shows "not logged on" in the health check

The server is stopped, cannot reach the Vault on port 1858, or the Vault restarted underneath it. Check the
component's service, then the network. For PVWA, see the maintenance-mode entry above.

## The controller closed or rebooted during an installation

Nothing to do in a hurry. The stage keeps running on the target. Reopen the desktop or check
`Get-PASEnvironmentSnapshot`, and resume the run if it stopped. The finished and running attempts are reconciled and
never repeated.

## Getting help

Export the run with [`Export-PASRunData`](../commands/export-rundata.md) and attach it to an issue on
[GitHub](https://github.com/bigbatmanorg/PASeasyInstall/issues). It contains no passwords.
