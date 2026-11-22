# The window

```powershell
Start-PASeasyInstall
```

One window builds a lab in four steps and then shows the installation while it runs. It is part of the
PASeasyInstall module and is drawn with WPF, which is part of Windows, so there is nothing else to install. The
window only calls the [commands](../commands/index.md) of the module: everything it does can also be done from
the prompt, and the Review step shows you how.

| Page | What you do there |
|---|---|
| [Start page](#start-page) | Start a new lab, open a saved lab file, open an installation |
| [1. Media](media.md) | Say where your CyberArk download, license and keys lie |
| [2. Lab](lab.md) | Choose what to build |
| [3. Servers](servers.md) | Name the servers, enter accounts and passwords, have them checked |
| [4. Install](review.md) | Read the plan and press Install |
| [The installation page](run.md) | Follow the installation, continue it when it stopped, check the lab |

Nothing is changed on any server before you press **Install the lab** on step 4 and confirm.

## Start page

![The start page before any installation](../assets/window/01-start.png)

- **Start a new lab** begins with step 1.
- **Open a saved lab file** reads a lab file (JSON) saved on the Review step or written by
  `Export-PASLabConfiguration`. Its name, lab choice, addresses and server names are filled in. Media and
  passwords are entered again: a lab file never contains them.
- **Your installations** lists every installation started from this computer, with its state. **Open** shows its
  page: the progress while it runs, what to do when it stopped, the lab check when it finished.

![The start page with one finished installation](../assets/window/02-start-with-installations.png)

The name **PASeasyInstall** in the top bar brings you back to this page from anywhere.

## The Advanced switch

The switch at the top right shows what most labs never need. It appears only on pages where it changes something:

| Page | Advanced adds |
|---|---|
| Lab (Custom) | Up to four instances of a component instead of two |
| Servers | Every single result of the server check, the address of this computer, "who installs", the hardening switch, the PTA time zone |
| Install | The same lab as PowerShell commands, and **Save the lab file** |
| Installation page | The PowerShell commands for this installation, and **Stop the installation** |

## An installation runs on its own

When you press Install, the installation starts in its own process on this computer. You can close the window.
Open it again later and the start page lists the installation.

While the window stays open, it remembers the accounts and passwords you typed for the installation it started.
They are kept in memory only, never in a file. For an installation you open later, the window asks again when it
needs them, for example for **Try this step again** or **Check the lab**:

![The window asks for the Vault Administrator password before the lab check](../assets/window/20-accounts-dialog.png)

## Try it without servers

```powershell
Start-PASeasyInstall -Backend Mock
```

The same window with a simulated installer. It contacts no server and installs nothing, and a badge
**Simulation** in the top bar says so. Two lab names make it misbehave on purpose, so that you can try what
happens:

- a lab name that contains `unreach`: the server check finds a server that does not answer;
- a lab name that contains `fail`: the installation stops with an error.

## What was tested

The window was walked by a script that presses its buttons, with the simulated installer and with real servers:
it installed a lab with a new domain (CyberArk 15.2) on clean servers, checked it and opened the installation
again. It has not been tried by hand on a real desktop for every screen, and the folder and file pickers were
not part of the scripted walks. If something looks wrong, please
[report it](https://github.com/bigbatmanorg/PASeasyInstall/issues).
