# PSM

Installs the Privileged Session Manager on a Windows Server 2022 and registers it with the Vault. The server can
stay in its workgroup or be member of the lab domain.

```powershell
Install-PASPSM -ComputerName 192.0.2.31 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArk -SecurityProfile Lab -Wait
```

In a lab configuration: `@{ Type = 'PSM'; Name = 'PSM01'; Address = '192.0.2.31' }`.

## What it needs

- The PSM package (`Privileged Session Manager-Rls-...zip`, or the big ZIP).
- The password of the Vault user Administrator, to register.
- A PVWA that is registered with the Vault: PSM writes into the PVWA configuration. In a lab that is taken care
  of by the order of the registrations.

## Steps

PSM is installed with the vendor's own stage script (`Execute-Stage.ps1`):

| Step | What it does |
|---|---|
| `management`, `media-upload` | As for [PVWA](pvwa.md) |
| `pvwa-trust-certificate` | Lab: copies the public certificate of PVWA to the server, verified by its SHA-256 |
| `preflight`, `extract` | As for PVWA |
| `prerequisites` | The vendor's prerequisites stage: Remote Desktop Session Host and others |
| `install` | The vendor's installation stage |
| `register` | The vendor's registration stage. Waits for the Vault, the first PVWA and every CPM |
| `harden` | The vendor's hardening stage. On a server that is member of a domain, its out-of-domain part is left out |
| `postinstall` | The vendor's post-installation stage; then the RDP listener is set to TLS |
| `verify` | The PSM service runs and the users `PSMConnect` and `PSMAdminConnect` exist |

**Restarts.** The vendor stages ask for restarts. After each stage the server is restarted when the stage asked
for it, and the same stage is run again (up to three passes, steps `<stage>-pass2` and `<stage>-pass3`) until it
reports that no restart is needed. In the window the restart
and the continuation count as part of the step. No autologon password is stored for these restarts.

After the last stage the PSM service is started if it stopped: after a restart it ends itself when it cannot
reach the Vault at once.

**Trust to PVWA.** The vendor's registration calls the PVWA API (`ApiKeyManager`) and needs trusted
communication to the PVWA server. In a lab the PVWA certificate is self-signed, so the installer copies the
public certificate from the PVWA server and adds it to the trusted roots of the PSM server before PSM registers.
PSM calls PVWA under the computer name PVWA registered in the Vault; with the Lab profile the PSM server gets a
hosts entry for every PVWA name it cannot resolve.

**Why PSM registers before its hardening.** CyberArk documents the order post-installation, hardening,
registration. In the test lab (15.2) the registration on a PSM server that was hardened already did all its
work (PSM was connected to the Vault afterwards), and the vendor's stage script still reported the step as
failed, with an empty error. The installer never turns a vendor failure into a success, so PSM registers before
its hardening, which has passed in every run. PVWA and PSM for SSH register after their hardening.

## In a domain

On a server that was joined to the lab domain, PSM is installed with the domain account of the lab, which the
join makes a local administrator. PSM itself is registered with its local users `PSMConnect` and
`PSMAdminConnect`, as in a workgroup; domain users for PSM are not set up.

## Good to know

- PSM limits who may create files in the root of the Windows Temp folder, to protect a backup the vendor script
  keeps there. The plan lists this as a note.
- **Session recordings:** the Vault creates the safe `PSMRecordings` at the first recorded session. Only members
  of the Vault group **Auditors** see it: look at recordings as the built-in user `Auditor`, or add your user to
  Auditors.
- Options for `Install-PASPSM -Options`: `installDirectory`, `vaultPort`.
