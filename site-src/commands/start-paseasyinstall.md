# Start-PASeasyInstall

Opens [the window](../gui/index.md).

The text of every command below is its own help (`Get-Help <command> -Full`).

| Command | What it does |
|---|---|
| [`Start-PASeasyInstall`](#start-paseasyinstall) | Opens the PASeasyInstall desktop: a window that builds a CyberArk PAM lab in four steps. |

## Start-PASeasyInstall

Opens the PASeasyInstall desktop: a window that builds a CyberArk PAM lab in four steps.

The steps are: media folder, the lab to build, servers and password, review and install. A start page lists the installations of this computer; each has a page with live progress, retry and a lab check. Nothing is sent to any server before you press Install on the last step. "Advanced" shows the settings most labs never need.

The window only calls the other commands of this module (New-PASLabConfiguration, Test-PASLabConfiguration, Get-PASLabPlan, Install-PASLab, Get-PASRun, ...), so everything it does can also be done from the prompt.

The window is drawn with WPF, which is part of Windows: nothing else has to be installed.

The window opens in its own process and the command returns at once: the prompt stays usable, and closing the prompt does not close the window. When the window cannot start, the command says why.

Needs Windows PowerShell 5.1. PASeasyInstall builds labs. Production use is at your own risk.

From the portable folder use `Start-PASeasyInstall.cmd`; from a source checkout `.\Start-PASeasyInstall.ps1`. Both take the same two parameters.

| Parameter | Meaning |
|---|---|
| `-Config` | Optional lab file (JSON, saved from the window or by Export-PASLabConfiguration). Its name, Vault option, addresses and component servers are filled in; media and passwords are entered again. |
| `-Backend` | Live (default) runs real installations. Mock simulates the installation and never contacts a server, which is useful for demos and training. |

```powershell
Start-PASeasyInstall
```

```powershell
Start-PASeasyInstall -Config .\PASeasyInstall-Lab01.json
```

```powershell
Start-PASeasyInstall -Backend Mock
```
