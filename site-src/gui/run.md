# The installation page

Every installation has a page. It opens when you press Install, and again when you **Open** an installation on
the start page. The installation itself runs in its own process: close the window whenever you like.

![An installation that is running](../assets/window/15-run-installing.png)

## What you see

- **The headline:** the name of the lab, its state, how many steps are done and how long it has been running.
- **One line per component:** its server, a progress bar, the step it is on, and steps done of steps in all.
  The number of steps of a component is fixed from the start.
- **Several components work at once.** A server does everything that needs no other server straight away.
- **Waiting for its turn at the Vault:** the component is ready to register. It waits until the Vault is
  installed, and then for the other components, because only one may sign in to the Vault at a time.
- **Waiting for PVWA:** a component that has to trust the PVWA certificate (CPM, the gateway or PTA on another
  server) starts when PVWA has created it, shortly after the start.
- **Waiting:** the component has not started yet. On a server with two components the second one waits for the
  first.
- **Activity log:** every event of the installation, the newest first: time, component, step and message. The
  coloured bar marks lines that started, finished, warn or failed.

PSM restarts its server several times, and a server that joins a domain restarts once. That is expected.

## When it stopped { #stopped }

![An installation that stopped with an error](../assets/window/17-run-failed.png)

The red box names the step and shows the installer's own error text. A server that fails stops only what
depends on it: every other server is installed to the end, and a server that could not go on says *Not
continued: a server it depends on failed* (see [Servers at the same time](../concepts/parallel.md#when-a-server-fails)).
Nothing is undone.

The buttons appear when the run has ended: the other servers finish first, and the line of the failed server
says so meanwhile. **Try this step again** and **Continue** leave every server that is installed and verified
as it is. Only the server that stopped is started again: its finished steps are looked at once (*Checking what
is already installed*), then the failed step runs.

An HTML5 Gateway is installed early, because it needs no Vault. Its line says *Installed. It is entered into
PVWA when PVWA and PSM are finished*: that entry is the last thing the installation does.

Look at the server and correct the cause. Then:

| Button | What it does |
|---|---|
| **Try this step again** | Runs the failed step again, then continues the installation. Use it when you corrected the cause. |
| **Continue without repeating it** | Continues the installation without running the failed step again. Finished steps are only checked. Use it when the step did finish on the server after all. |
| **Save the logs as a ZIP** | Writes the journals of the installation into a ZIP without passwords, for a bug report. |

A failed step is never repeated on its own. That is on purpose: an installer whose outcome is not known must
not simply run twice.

If the window was closed in between, it asks for the accounts and passwords again before it continues.

## When it finished

![A finished installation](../assets/window/18-run-finished.png)

**Check the lab** signs in to the Vault through PVWA and lists the components the Vault sees as connected, with
their versions. It changes nothing.

![The lab check: every component is connected](../assets/window/19-lab-check.png)

*Healthy* means every component of the lab is connected to the Vault. If one is missing, see
[Troubleshooting](../troubleshooting/index.md#a-component-is-not-connected-in-the-lab-check).

Then open the web portal at `https://<computer name of the PVWA server>/PasswordVault` and sign in as
`Administrator` with the Vault Administrator password. In a lab the certificate is self-signed, and the computer
with the browser must resolve the PVWA name (a hosts entry is enough).

## Advanced: PowerShell commands and Stop

With **Advanced** on, a card above the activity log shows the commands for this installation, with its run id
filled in: look at it, list what failed, continue it, stop it, save the logs.

![The PowerShell commands of an installation, above the activity log](../assets/window/16-run-advanced.png)

**Stop the installation** ends the installation on this computer. A step that is running on a server at that
moment is not interrupted, but nothing new is started, and the servers keep what was installed until then. A
stopped installation cannot be continued; see [`Stop-PASRun`](../commands/runs.md#stop-pasrun).

The commands are explained in [Run commands](../commands/runs.md).
