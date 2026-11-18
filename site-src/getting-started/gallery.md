# PowerShell Gallery

```powershell
Install-Module PASeasyInstall -Scope CurrentUser
Start-PASeasyInstall
```

`Install-Module` also installs **NativeHTMLKit.UI**, the desktop runtime, as a dependency.

## A fresh Windows Server

A new Windows Server may need the NuGet provider and TLS 1.2 before its first `Install-Module`:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted   # optional: skip the "untrusted repository" prompt
Install-Module PASeasyInstall -Scope CurrentUser
```

Use `-Scope AllUsers` from an elevated prompt to install it for everyone on the controller.

## Update and remove

```powershell
Update-Module PASeasyInstall
Uninstall-Module PASeasyInstall
```

## Commands

After installation, every command in the [command reference](../commands/index.md) is available. Use
`Get-Command -Module PASeasyInstall` to list them and `Get-Help <command> -Full` for details.
