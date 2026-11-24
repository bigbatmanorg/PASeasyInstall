# Step 1: Media

*Where is the installer media?* Say where your CyberArk download, your license file and your keys lie.

![The Media step before anything is added](../assets/window/03-media-empty.png)

## Add folders and files

In the card **Add a folder or a file**:

- type or paste a path into **Path of a folder or a file** and press **Add**, or
- press **Choose a folder...** or **Choose files...** and pick them. Several files can be picked at once.

You do not have to sort anything, and nothing has to be in one folder or one ZIP. Add every place where a part
lies, one after the other, for example:

- the folder with the download from CyberArk (the one big ZIP, or the separate ZIPs);
- the folder with `license.xml`;
- the folder with your operator keys (`recpub.key`).

After every **Add** the window looks through all places again. That takes a few seconds; the window says
*Looking for installers* meanwhile and stays usable. A folder is searched four levels deep. ZIP files are looked
into. Nothing is unpacked, moved or changed.

There is no drag and drop: media is added by path. A path that is typed but not added yet is added when you
press Next.

## Where the window looks

The card **Where the window looks** lists every place you added, with what was found in it (*Found here: ...*
or *Nothing recognised here*). **Remove** takes a place out again. A path that does not exist is marked in red,
so that you can remove it and add the right one.

![The places that were added, each with what was found there](../assets/window/04-media-sources.png)

## What was found

The card **What was found** has one line per part: *found* or *not found*, what it is with its version and file
name, and where it was found (the place you added, and the ZIP it lies inside).

![The table of what was found, with the place of every part](../assets/window/05-media-found.png)

The window looks for:

| Part | File |
|---|---|
| Vault server, PACLI, key generator, Disaster Recovery | from the big ZIP, or `Server-Rls-...zip`, `PACLI-Rls-...zip`, `Disaster Recovery-Rls-...zip` and `Vault Ansible Role-Rls-...zip` |
| PVWA, CPM, PSM | `Password Vault Web Access-Rls-...zip`, `Central Policy Manager-Rls-...zip`, `Privileged Session Manager-Rls-...zip` |
| PSMP | `PrivilegedSessionManagerSSHProxy-<distribution>-Intel64-Rls-...zip` |
| HTML5 Gateway, PTA | `HTML5 Gateway-Rls-...zip`, `PTA-Installer-Rls-...zip` |
| Vault license | `license.xml` |
| Recovery public key | `recpub.key`, from your operator keys |
| Visual C++ runtimes for the Vault | `VC_redist.x64.exe`, `VC_redist.x86.exe`; also taken from the PVWA, CPM or PSM package |

When several versions of a part are found, the highest version is used, but a package that is not a complete
ZIP file (cut off or damaged) is not used when another copy is there. Its line then says *Not used, because
damaged*; when it is the only copy it says *DAMAGED* and you should download it again. The window has no other
way to pick a file; see also [HTML5 Gateway: media](../components/html5gw.md#media).

## What is still missing

Below the table a box says whether the lab chosen on the next step has everything: *Everything the chosen lab
needs was found*, or *Not found yet for the lab that is chosen:* with the parts that are missing. Add the
folder or file that holds them, or leave those parts out of the lab on the next step.

**Next: choose the lab** goes on as soon as at least one CyberArk installer was recognised. The Lab step then
does not let you go on with a component that has no installer. **Back** brings you here again.

If nothing is recognised (*No CyberArk installer was recognised*), the usual cause is an unpacked copy: add the
folder with the ZIP files as downloaded from CyberArk.

## From the prompt

```powershell
Get-PASMediaInventory -Path D:\CyberArk, D:\Licenses | Format-Table Component, Version, Name, Container
$media = Get-PASMediaInventory -Path D:\CyberArk, D:\Licenses | Get-PASMediaSelection
```

See [Media commands](../commands/media.md).

Next: [Step 2: Lab](lab.md).
