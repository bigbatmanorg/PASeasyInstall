# Troubleshooting

Messages that were really seen while building labs, and what to do. Start with what stopped:

=== "In the window"

    The installation page says **The installation stopped.**, names the step and the component, and shows the
    installer's own error text. Correct the cause, then press **Try this step again**, or **Continue without
    repeating it** when the step did finish on the server after all. **Save the logs as a ZIP** keeps the logs. See
    [The installation page](../gui/run.md).

=== "From the prompt"

    ```powershell
    Get-PASRun                                 # all runs, newest first
    Get-PASRun -RunId <id>                     # one run: state, components, latest events
    Get-PASRunEvent -RunId <id> -Failed        # what failed
    Test-PASPreflight -Path .\MyLab.json       # do the servers answer, are they ready?
    ```

After you corrected the cause, continue the same run. A step that failed is not repeated on its own; you name
it:

```powershell
Resume-PASRun -RunId <id>                             # check finished steps, install the rest
Resume-PASRun -RunId <id> -RetryStep cpm01:install    # also run this failed step again
```

Why it works like this: [Runs and resume](../concepts/durable-runs.md).

## Before the installation

### Nothing is recognised on the Media step

The window says **No CyberArk installer was recognised.** The folder holds an unpacked copy, or files whose
names were changed. Add the folder with the ZIP files as downloaded from CyberArk. Files are recognised by
their names.

### A package is marked as damaged

On the Media step a part shows **DAMAGED: not a complete ZIP file**, or **Not used, because damaged**. The
package was cut off while it was downloaded or copied. When another copy is there, the window uses it and says
so. When the damaged one is the only copy, download it again, or add another folder or file that holds a good
copy with **Add**. In the test lab the HTML5 Gateway package inside one 15.2 bundle was damaged; a 15.0 gateway
package added as a second place worked.

### "Several copies of the VC++ runtime were found"

The media you added holds `VC_redist.x86.exe` or `VC_redist.x64.exe` more than once outside the packages. Keep
one copy of each, or add the media folder itself instead of its parent.

### The server check says a server does not answer

The address is wrong, the server is off, or a firewall is in the way. Windows servers must answer on port 5986
(WinRM over HTTPS), Linux servers on port 22. See [Server prerequisites](../servers/prerequisites.md).

### WinRM: "Access is denied" with `Administrator`

When you test WinRM by hand with the user name `Administrator`, the controller tries its own local
`Administrator` first. Write `.\Administrator` or `SERVERNAME\Administrator`. PASeasyInstall does this for you;
keep the plain name in the window and in the configuration.

### "Password sign-in to root@... failed"

The root password is wrong, or the server does not let root sign in with a password. Correct the password, or
allow it while you install, or authorise the key shown in the message for root yourself. See
[Linux servers](../servers/prerequisites.md#linux-servers).

### "PASeasyInstall signs in to Linux servers as root, but ... is not root"

The account entered for the Linux server is not root. The installation writes system packages and services, so
it runs as root. Enter `root`.

### "Accept the CyberArk license agreement ..."

The lab has a PSM for SSH, an HTML5 Gateway or PTA, and the license agreement of their installers was not
accepted. Tick the box under **Vault** on the Servers step of the window, or pass `-AcceptEula` to
`New-PASLabConfiguration` or `Install-PASPSMP`.

### "The controller could not be started ..." (Windows DPAPI) { #the-controller-could-not-be-started-windows-dpapi }

The installation was started from a remote PowerShell session (`Enter-PSSession`, `Invoke-Command`, SSH). The
installation process gets the accounts protected with Windows DPAPI, which does not work in such sessions.
Start `Start-PASeasyInstall` or the `Install-PAS*` command in a local session on the controller: at the console
or through remote desktop.

### "Environment '...' is being deployed right now by run ..."

Another installation of the same lab name is running on this controller. Wait for it
(`Wait-PASRun -RunId <id>`), or stop it with `Stop-PASRun -RunId <id> -Force`.

## During the installation

### "PAExecLocked: server ... is locked by run ..." (the run is Blocked)

An earlier run worked on this server and did not finish. It left a lock folder there on purpose, so that no
other run touches a half-installed server. Choose one:

- Continue the earlier run: `Resume-PASRun -RunId <that run id>`.
- Give the earlier run up: `Stop-PASRun -RunId <that run id>`. The run is marked Abandoned; its locks stay.
- Reset the servers to their clean snapshot. Then, and only then, release the locks:
  `Stop-PASRun -RunId <that run id> -ReleaseLocksAfterReset -CredentialMap $creds`, and start a new run. A
  worker on a server can outlive its controller, so never release locks of servers you did not reset.

More: [Locks](../concepts/coordination.md).

### "Not continued: a server it depends on failed"

The window shows this for the other servers when one server failed; from the prompt the message is
`PASLaneStopped: ... Nothing was started for this step.` The servers that were waiting for the failed one
gave up, and nothing was started for them. Look for the step that really failed
(`Get-PASRunEvent -RunId <id> -Failed`), correct it, and try that step again: every server continues.

### "SSH observation timed out; target work was not stopped" { #ssh-observation-timed-out }

The controller did not get an answer from a Linux server in time, and the state of the step is Unknown. Seen
once, while five servers were being installed; the cause is not known. Look at the server: if it answers
again, run the step again by name:

```powershell
Resume-PASRun -RunId <id> -RetryStep <component id>:<step>
```

### "Vault ... is in use by another PASeasyInstall controller on this machine"

Another run or a lab check on this controller held the Vault longer than this step waited. Wait until it has
finished, then continue the run.

### "Cannot resume: workflow, scripts or inventory changed since run began"

PASeasyInstall was updated, or its files were changed, after the run started. A server is never continued with
different scripts. Reset that server to its clean state and start a new run.

### "The configuration of this run changed" / "The installer media changed"

A run installs exactly what was planned. Put the original files back, or start a new run.

### Linux: "unzip required and could not be installed"

The server has no `unzip` and its package sources could not be reached to install it. Make them reachable, or
install `unzip` yourself, then:

```powershell
Resume-PASRun -RunId <id> -RetryFailedPreflight
```

### PSM for SSH: "User [PSMPApp_...] already exists in the Vault"

Another PSM for SSH server with the same host name is registered. Give each one a unique host name. If the old
server is gone, remove its users `PSMPApp_<host>`, `PSMPGW_<host>` and `PSMP_ADB_<host>` in PVWA
(Administration, Users), then run the step again.

### The controller was closed or restarted during an installation

Nothing to do in a hurry. The step that was running goes on, on the server. Look at the run
(`Get-PASRun -RunId <id>`, or open it from the start page of the window). If it is Interrupted, continue it.
What ran is found again and not repeated.

## After the installation

### A component is not connected in the lab check { #a-component-is-not-connected-in-the-lab-check }

The server is off, cannot reach the Vault on port 1858, or the Vault was restarted underneath it. Check the
service of the component on its server, then the network. For PVWA and PTA see the next entries.

### "PTA is registered in the Vault, but PVWA cannot reach it ..."

PVWA reaches PTA under the host name PTA registered in the Vault, which is the name in PTA's certificate. The
installation adds a hosts entry for that name on the first PVWA server and checks it with a real HTTPS call.
If you see this message, that name does not lead to PTA from the PVWA server (for example, PTA's address or
host name changed, or another PVWA server is used): add the name to DNS or to the hosts file of the PVWA
server, and make sure PVWA reaches PTA on port 443.

Labs installed with version 2.0.10 or earlier, whose PTA host name differs from the name typed in the window,
show PTA as not connected and the older message "No PTA is registered in the Vault". Add the hosts entry on the
PVWA server by hand, or build the lab again.

### PVWA: "PASWS383E Vault is currently under maintenance mode"

PVWA started while the Vault was still starting, and kept that state. On the PVWA server:

```powershell
Import-Module WebAdministration; Restart-WebAppPool PasswordVaultWebAccessPool
```

Start the Vault first next time, and PVWA when the Vault is up.

### Password changes of components fail with CASTM057E

`CASTM057E Password has not yet been replicated to DR site(s)`: the lab has a DR Vault and it is stopped. Start
it; it catches up within one replication cycle.

### Recordings: "PSMRecordings" not found

The Vault creates that safe at the first recorded session, and only members of the Vault group **Auditors** see
it. Sign in as the built-in user `Auditor`, or add your user to Auditors.

### The browser cannot open the web portal

The computer with the browser must resolve the computer name of the PVWA server; add a line to its hosts file.
In a lab the certificate is self-signed, so the browser warns.

## Getting help

```powershell
Export-PASDiagnostics -RunId <id>
```

writes a ZIP of the run without passwords (in the window: **Save the logs as a ZIP**). Look through it before
you share it: it holds the names and addresses of your servers. Attach it to an issue on
[GitHub](https://github.com/bigbatmanorg/PASeasyInstall/issues).
