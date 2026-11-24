# PVWA

Installs Password Vault Web Access, the web portal, on a Windows Server 2022 and registers it with the Vault.

```powershell
Install-PASPVWA -ComputerName 192.0.2.21 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArk -SecurityProfile Lab -Wait
```

In a lab configuration: `@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' }`. `Name` is the computer
name of the server; users reach the portal at `https://<name>/PasswordVault`.

## What it needs

- The PVWA package (`Password Vault Web Access-Rls-...zip`, or the big ZIP).
- The password of the Vault user Administrator, to register.
- **An HTTPS certificate.** With the Lab profile a self-signed certificate for the computer name is created on
  the server. With the Secure profile you name a certificate that is already in the machine store of the server
  (`-CertificateThumbprint`).

## Steps

| Step | What it does |
|---|---|
| `management` | Registers a restricted WinRM endpoint for the configured administrator |
| `media-upload` | Copies the PVWA package, verified by its SHA-256 |
| `preflight` | Checks the server and the package |
| `certificate` | Lab: creates the self-signed HTTPS certificate now, long before IIS is installed. A CPM, PSM, HTML5 Gateway or PTA on another server copies the public certificate and starts its own installation at once |
| `extract` | Unpacks the package and finds the vendor scripts |
| `prerequisites` | The vendor's prerequisites script: IIS and the Windows features PVWA needs |
| `install` | The vendor's installation |
| `configuretls` | Binds the certificate to HTTPS on port 443 and requires HTTPS for the application |
| `harden` | The vendor's PVWA hardening |
| `register` | Registers PVWA with the Vault. Waits for the Vault; the first PVWA registers before every other component |
| `verify` | The services and the application run, HTTPS serves the expected certificate |

Registration comes after hardening. CyberArk's documentation allows that order for PVWA, and it means the server
is completely prepared before it needs the Vault.

## After the installation

Sign in at `https://<computer name>/PasswordVault` as `Administrator`.

- The computer with the browser must resolve the PVWA name; a hosts entry is enough. The lab check
  (`Test-PASHealth`, **Check the lab**) needs no such entry.
- With the Lab profile the certificate is self-signed: accept it in the browser or import it.

## Options

`Install-PASPVWA -PvwaUrl`, `-CertificateThumbprint` and `-Options` (`installDirectory`, `applicationDirectory`,
`applicationName` and others; see [`Install-PASPVWA`](../commands/install.md#install-paspvwa)).

## If PVWA says "Vault is currently under maintenance mode"

PVWA started while the Vault was still starting, and kept that state. Recycle the application pool on the PVWA
server:

```powershell
Import-Module WebAdministration; Restart-WebAppPool PasswordVaultWebAccessPool
```

When you start a stopped lab, start the Vault first and PVWA when the Vault is up.
