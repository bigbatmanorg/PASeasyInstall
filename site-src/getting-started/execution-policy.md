# Execution policy

PASeasyInstall is not code-signed. What to do depends on the execution policy of the controller
(`Get-ExecutionPolicy -List` shows it).

| Situation | What to do |
|---|---|
| The default of Windows Server (`RemoteSigned`), module installed with `Install-Module` | Nothing. Files installed from the Gallery carry no "downloaded" mark. |
| Portable ZIP | Unblock the ZIP before you extract it: `Unblock-File .\PASeasyInstall-*-portable.zip`. If it is extracted already: `Get-ChildItem -Path <folder> -Recurse \| Unblock-File`. `Start-PASeasyInstall.cmd` starts PowerShell with `-ExecutionPolicy Bypass` for its own process. |
| `AllSigned` or `Restricted` | Allow unsigned code for this PowerShell window only (below). It changes nothing for the computer and ends with the window. |
| A policy set by Group Policy (`MachinePolicy` or `UserPolicy` in the list) | PowerShell does not let you override it. Ask your administrator for an exception for the controller, or use a controller without that policy. |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Start-PASeasyInstall
```

Or in one line, from any prompt:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command Start-PASeasyInstall
```

## On the servers

Every PowerShell process PASeasyInstall starts, on the controller and on the servers, is started with
`-ExecutionPolicy Bypass`. So an installation also works on a server whose local policy is `AllSigned`. A policy
set by Group Policy on a server still applies.
