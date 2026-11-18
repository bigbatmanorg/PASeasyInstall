# Start-PASeasyInstall

Opens the [desktop](../gui/index.md).

```powershell
Start-PASeasyInstall [-Config <path>] [-Advanced] [-Backend Orchestrator|Mock] [-Theme v2|v1]
```

| Parameter | Description |
|---|---|
| `-Backend` | `Orchestrator` (default) drives the real installer. `Mock` simulates plans and installations and never contacts a server. |
| `-Theme` | `v2` (default, dark and compact) or `v1` (light). |
| `-Advanced` | Shows advanced options. |
| `-Config` | A project file. <!-- TODO(parent): reopening a saved project in the desktop is not wired yet; document once it is. --> |

The desktop runs in its own process. Closing it never stops an installation that is already running.

From the portable folder, use `Start-PASeasyInstall.cmd` (double-click) or `.\Start-PASeasyInstall.ps1`.
