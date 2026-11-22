# Start-PASeasyInstall

Opens the [desktop](../gui/index.md). The command is part of the PASeasyInstall module. The window is drawn with WPF,
which is part of Windows, so nothing else has to be installed:

```powershell
Install-Module PASeasyInstall -Scope CurrentUser
Start-PASeasyInstall [-Config <path>] [-Backend Live|Mock]
```

| Parameter | Description |
|---|---|
| `-Config` | A project file (JSON) written by the desktop or by `Export-PASLabConfiguration`. Its name, Vault option, addresses and component servers are filled in. Media and passwords are entered again; they are never in a project file. |
| `-Backend` | `Live` (default) runs real installations. `Mock` simulates the installation and never contacts a server. |

The desktop only calls the [commands](index.md) of the PASeasyInstall module, so everything it does can also be done
from the prompt. An installation runs in its own process: closing the window never stops it.

From the portable folder, use `Start-PASeasyInstall.cmd` (double-click). From a source checkout, use
`.\Start-PASeasyInstall.ps1`.
