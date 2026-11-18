# Execution policy

PASeasyInstall is not Authenticode-signed. How to run it under each PowerShell execution policy:

| Situation | What to do |
|---|---|
| Default Windows Server policy (`RemoteSigned`), installed with `Install-Module` | Nothing. Files installed from the Gallery carry no internet zone mark. |
| Portable ZIP | Unblock the ZIP before extracting: `Unblock-File .\PASeasyInstall-*-portable.zip`, or, after extracting, `Get-ChildItem -Path <folder> -Recurse \| Unblock-File`. `Start-PASeasyInstall.cmd` starts PowerShell with `-ExecutionPolicy Bypass` for its own process. |
| `AllSigned` or `Restricted` policy | Allow unsigned code for this PowerShell window only. This changes nothing machine-wide and ends when the window closes. |
| Policy enforced by Group Policy (`Get-ExecutionPolicy -List` shows `MachinePolicy` or `UserPolicy`) | PowerShell does not let the commands below override it. Ask your administrator for an exception for the controller, or use a controller without that policy. |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Start-PASeasyInstall
```

Or in one line:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command Start-PASeasyInstall
```

The background processes PASeasyInstall starts on the controller, and the scripts it runs on the target servers,
always start with an explicit `-ExecutionPolicy Bypass`. So they also work on hosts whose local policy is `AllSigned`.
A policy enforced by Group Policy on a target still applies.
