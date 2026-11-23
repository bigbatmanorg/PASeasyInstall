# Troubleshooting

Messages that were really seen while building labs, and what to do. Start with what stopped:

=== "In the window"

    The installation page shows the step that stopped and the installer's own error text. See
    [When it stopped](../gui/run.md#stopped).

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
accepted. Tick the box on the Servers step of the window, or pass `-AcceptEula` to `New-PASLabConfiguration` or
`Install-PASPSMP`.

### "Several copies of the VC++ runtime were found"

The media you added holds `VC_redist.x86.exe` or `VC_redist.x64.exe` more than once outside the packages. Keep
one copy of each.

### Nothing is recognised on the Media step

The folder holds an unpacked copy. Add the folder with the ZIP files as downloaded from CyberArk.

### "The controller could not be started ..." (Windows DPAPI) { #the-controller-could-not-be-started-windows-dpapi }

The installation was started from a remote PowerShell session (`Enter-PSSession`, `Invoke-Command`, SSH). The
installation process gets the accounts protected with Windows DPAPI, which does not work in such sessions.
Start `Start-PASeasyInstall` or the `Install-PAS*` command in a local session on the controller: at the console
or through remote desktop.

### "Environment '...' is being deployed right now by run ..."

Another installation of the same lab name is working on this controller. Wait for it
(`Wait-PASRun -RunId <id>`), or stop it with `Stop-PASRun -RunId <id> -Force`.

## During the installation

### "PAExecLocked: server ... is locked by run ..." (the run is Blocked)

An earlier run started on this server and did not finish. It left its lock there on purpose, so that no other
run touches a half-installed server. Choose one:

- Continue the earlier run: `Resume-PASRun -RunId <that run id>`.
- Abandon the run while retaining its locks: `Stop-PASRun -RunId <that run id>`.
- Only **after the affected lab VMs are restored/rebuilt** may you explicitly clean stale locks: `Stop-PASRun -RunId <that run id> -ReleaseLocksAfterReset -CredentialMap $creds`. Never infer remote worker termination from controller termination.
- If you reset the servers to their clean state, the lock is gone with it; start a new run.

Then resume the blocked run. More: [Locks](../concepts/coordination.md).

### "Nothing was started for this step" on other servers

One server failed. The servers that were waiting for their turn at the Vault gave up; nothing was started for
them. That is how a run that installs the servers at the same time stops. Look for the step that really
failed (`Get-PASRunEvent -RunId <id> -Failed`), correct it, and resume: every server continues.

### "SSH observation timed out; target work was not stopped" { #ssh-observation-timed-out }

The controller did not get an answer from a Linux server within two minutes, and the state of the step is
Unknown. Seen once, while five servers were being installed; the cause is not known. Look at the server: if it
answers again, run the step again by name:

```powershell
Resume-PASRun -RunId <id> -RetryStep <component id>:<step>
```

### "Vault ... is in use by another PASeasyInstall controller on this machine"

Another run on this controller was signed in to the Vault for more than three minutes. Wait until it is past
that step, then resume.

### "Cannot resume: workflow, scripts or inventory changed since run began"

PASeasyInstall was updated, or the source was changed, after the run started. A server is never continued with
different scripts. Reset that server to its clean state and start a new run.

### "The configuration of this run changed" / "The installer media changed"

A run installs exactly what was planned. Put the original files back, or start a new run.

### Linux: "unzip required"

The server has no `unzip` and its package sources could not be reached to install it. Make them reachable, or
install `unzip` yourself, then:

```powershell
Resume-PASRun -RunId <id> -RetryFailedPreflight
```

### PSM for SSH: "User [PSMPApp_...] already exists in the Vault"

Another PSM for SSH server with the same host name is registered. Give each one a unique host name. If the old
server is gone, remove its users `PSMPApp_<host>`, `PSMPGW_<host>` and `PSMP_ADB_<host>` in PVWA
(Administration, Users), then run the step again.

### HTML5 Gateway stops at `extract`

The gateway package inside the 15.2 big ZIP is cut short. Use the complete 15.0 package; see
[HTML5 Gateway](../components/html5gw.md#media).

### The controller was closed or restarted during an installation

Nothing to do in a hurry. The step that was running goes on, on the server. Look at the run
(`Get-PASRun -RunId <id>`, or open it in the window). If it is Interrupted, resume it. What ran is found again
and not repeated.

## After the installation

### A component is not connected in the lab check { #a-component-is-not-connected-in-the-lab-check }

The server is off, cannot reach the Vault on port 1858, or the Vault was restarted underneath it. Check the
service of the component on its server, then the network. For PVWA see the next entry.

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
