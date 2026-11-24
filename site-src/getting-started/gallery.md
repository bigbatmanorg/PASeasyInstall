# PowerShell Gallery

PASeasyInstall is published as **one module**. It holds the commands (`Install-PASLab`, `Get-PASRun`, ...) and
the window (`Start-PASeasyInstall`). It needs no other module.

```powershell
Install-Module PASeasyInstall -Scope CurrentUser
Start-PASeasyInstall
```

Use `-Scope AllUsers` from an elevated prompt to install it for everybody on the controller.

`Start-PASeasyInstall` opens the window in its own process and returns at once, so the prompt stays usable.
Closing the prompt does not close the window.

## A fresh Windows Server

A new Windows Server may need TLS 1.2 and the NuGet provider before its first `Install-Module`:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted   # optional: no "untrusted repository" question
Install-Module PASeasyInstall -Scope CurrentUser
```

## Look around

```powershell
Get-Command -Module PASeasyInstall          # the 26 commands
Get-Help Install-PASLab -Full               # every command has help with examples
Get-Help about_PASeasyInstall               # an overview
```

## Update and remove

```powershell
Update-Module PASeasyInstall
Uninstall-Module PASeasyInstall
```

Your installations keep their journals in `%LOCALAPPDATA%\PASeasyInstall`; an update does not touch them.
Finish or give up a run that stopped **before** you update: a run is never continued with changed scripts
(see [Runs and resume](../concepts/durable-runs.md)).

Next: [Your first lab](first-lab.md).
