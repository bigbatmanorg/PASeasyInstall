# The desktop

`Start-PASeasyInstall` opens one window. It is part of the PASeasyInstall module and is drawn with WPF, which is
part of Windows, so nothing else has to be installed. It builds a lab in four steps and then
shows the installation while it runs. The window only calls the [commands](../commands/index.md) of the
PASeasyInstall module, so everything it does can also be done from PowerShell.

!!! note "New in 2.0"
    The window was rewritten for 2.0. On 2026-11-21 it installed a Full lab (CyberArk 15.2) on real servers, was
    stopped by an error on purpose, continued with *Try again*, and ran the lab check. That run was driven by a
    script that calls the same functions as the buttons, so mouse and keyboard use is tested less than the logic.

The window is small on purpose (800 x 560, usable down to 480 x 340) and uses one dim colour scheme, so it can sit
beside other windows or in a remote desktop session while an installation runs.

## Start page

Two buttons, **Start a new lab** and **Open a saved lab file**, and the list of installations started from this
computer. **Open** on an installation shows its page: progress while it runs, what to do when it stopped.

## Step 1: Media { #media }

Choose the folder with the CyberArk installer media: the one big ZIP or the separate ZIPs, your `license.xml` and
the recovery public key. Type the folder, **Browse** to it, or drop the folder or the files on the window.
**Look for installers** lists what was found. Nothing is changed in that folder.

The VC++ runtimes the Vault needs are taken from the CPM, PVWA or PSM package of the lab. Only a Vault on its own
needs `VC_redist.x86.exe` and `VC_redist.x64.exe` in the folder.

## Step 2: Lab { #lab }

Pick a ready-made lab:

| Lab | What it installs | Servers |
|---|---|---|
| Starter | Vault, PVWA, CPM | 2 |
| Standard | Starter plus PSM | 3 |
| Full | Standard plus a DR Vault and PSMP | 5 |
| Custom | You choose: a new Vault, a Vault with DR or a Vault you already have, and how many of each component | |

In **Custom**, *Install CPM on the PVWA server* saves one server. Give the lab a name; installations are listed
under it.

## Step 3: Servers { #servers }

A plain form. One line per server: its computer name, its address, and the account to sign in with (a local
administrator on Windows, `root` on Linux) with its password. Below it, the Vault passwords: for a new Vault the
passwords to set for the Vault users Administrator and Master (and the DR user, with a DR Vault); for a Vault you
already have, the password of its Administrator. With PSMP in the lab you also accept the CyberArk license agreement
of its installer here.

**Next** checks the servers before anything else happens:

1. within a few seconds, whether every server answers at its address at all;
2. then, in the background, whether the account can sign in to each server and whether the server is ready
   (operating system, free disk space, pending restarts).

A server that does not answer or an account that does not work is named with the reason, and the window stays on
this step. Only when every server passed, the review step is shown. The check changes nothing on the servers.

## Step 4: Review and install { #install }

The plan in installation order, with the installer file used for each part and a rough duration. Problems are
listed in plain words and block the **Install the lab** button until they are solved. *Lab shortcuts in use* lists
what the Lab profile relaxes.

## The installation page { #run }

One line per component with a progress bar and the step that is running. The installation runs in its own process:
you can close the window and open it again later.

- **Stopped with an error:** the page shows the step and the installer's own error text. Correct the cause on the
  server, then **Try this step again**, or **Continue without repeating it**. **Save the logs as a ZIP** collects
  the diagnostics.
- **Finished:** **Check the lab** asks the Vault whether every component is connected.
- **Activity log** shows the events of the run, newest first: time, component, step and message. A coloured bar
  marks finished, started, warning and failed lines. Folded, it shows the newest event.

While the window stays open it remembers the accounts of the installation it started (protected in memory, never
in a file), so *Try again* and *Check the lab* need nothing more. For an installation opened later from the list
it asks for the accounts again.

## Advanced options { #advanced }

The switch in the top bar shows what most labs never need:

- the address of this computer as the Vault sees it;
- up to four instances of a component (two were tested);
- every single result of the server check;
- the same installation as PowerShell commands, **Save the lab file**, and **Stop the installation**.

## Simulation

`Start-PASeasyInstall -Backend Mock` runs the same window against a simulated installation that contacts no server.
A lab whose name contains `fail` stops with an error, so you can try the retry buttons.
