# The desktop

`Start-PASeasyInstall` (module **PASeasyInstall.UI**) opens one window. It builds a lab in four steps and then
shows the installation while it runs. The window only calls the [commands](../commands/index.md) of the
PASeasyInstall module, so everything it does can also be done from PowerShell.

!!! warning "New in 2.0, not yet used against real servers"
    The window was rewritten for 2.0. It was tested with the simulated installation (`-Backend Mock`), not yet with
    a real one. The commands it calls were lab-tested.

## Start page

Two buttons, **Start a new lab** and **Open a saved lab file**, and the list of installations started from this
computer. **Open** on an installation shows its page: progress while it runs, what to do when it stopped.

## Step 1: Media { #media }

Choose the folder with the CyberArk installer media: the one big ZIP or the separate ZIPs, your `license.xml` and
the recovery public key. **Look for installers** lists what was found. Nothing is unpacked or changed.

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

One line per server: its computer name and its address. Then the **lab password**: one password that must already
be the password of `Administrator` on the Windows servers and of `root` on the Linux server, and that becomes the
password of the new Vault users. With PSMP in the lab you also accept the CyberArk license agreement of its
installer here.

**Check the servers** signs in to every server and checks the operating system, free disk space and pending
restarts. It changes nothing and is optional.

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
- **Activity log** shows the events of the run, newest first.

The window keeps no password after an installation has started, so it asks for the lab password again when you
continue an installation or check the lab.

## Advanced options { #advanced }

The switch in the top bar shows what most labs never need:

- other account names and the address of this computer as the Vault sees it;
- a separate password for every server account and Vault user;
- up to four instances of a component (two were tested);
- every single result of the server check;
- the same installation as PowerShell commands, **Save the lab file**, and **Stop the installation**.

## Simulation

`Start-PASeasyInstall -Backend Mock` runs the same window against a simulated installation that contacts no server.
A lab whose name contains `fail` stops with an error, so you can try the retry buttons.
