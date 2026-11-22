# Vault

Installs a **new Primary Vault** on a dedicated Windows Server 2022 that is not member of a domain.

```powershell
Install-PASVault -ComputerName 192.0.2.11 -MediaPath D:\CyberArk -SecurityProfile Lab -Wait
```

In a lab configuration: `-VaultMode Primary -PrimaryAddress 192.0.2.11`. In the window: every ready-made lab,
or *New Vault* in Custom.

## What it needs

- The Vault server and PACLI packages and `Vault Ansible Role-Rls-...zip` (all three are in the big ZIP),
  `license.xml` and `recpub.key`.
- The Visual C++ runtimes. They are taken from the PVWA, CPM or PSM package; only a Vault on its own needs
  `VC_redist.x64.exe` and `VC_redist.x86.exe` as files.
- Two passwords to set: for the Vault users **Administrator** and **Master**. Printable ASCII without double
  quotes.
- The address of the controller as the Vault server sees it (`-ControllerAddress`). The firewall of the hardened
  Vault is opened for this address only.

## Steps

| Step | What it does |
|---|---|
| `preflight` | Checks the server: identity, address, operating system, no Vault installed yet |
| `management-endpoint` | Registers a restricted WinRM endpoint that only the configured administrator may use |
| `prepare-paths` | Protected work folders, and a rule that limits WinRM to the controller address |
| `upload-...` | Copies the Vault server, PACLI, the key generator, the license, the recovery public key and the runtimes; each file is verified by its SHA-256 on the server |
| `prerequisites` | Visual C++ runtimes and a .NET check |
| `extract` | Unpacks the Vault server and PACLI |
| `keygen` | Generates the Vault keys (their content is never logged) |
| `install-server` | Runs the Vault installer silently |
| `configure-primary` | Starts the Vault services, checks that the server is up and that a sign-in with PACLI works |
| `harden-primary` | Runs the vendor's Vault hardening |
| `hardening-reboot` | Restarts the server |
| `hardening-services` | Disables the Windows update services again if Windows switched them back on during the restart, then verifies the hardening |
| `verify-primary` | After the restart: the server is up, the Vault services run, a sign-in with PACLI works |

The other servers of a lab are installed while this runs. Their registrations start when `verify-primary` has
finished (with a DR Vault: when the [DR Vault](dr.md) is replicating).

## After the installation

The hardened Vault server serves the Vault port 1858. Management connections are accepted only from the
controller:

- **WinRM** over HTTPS through a restricted endpoint (`PAExec.Management`), for the administrator account you
  entered. A normal remote PowerShell session to the hardened Vault is refused.
- **Remote desktop** only with the Lab profile (`Vault.AllowRDP`), and only from the controller.

To look at a Vault log from the controller:

```powershell
Get-PASRunLog -Path .\MyLab.json -Component vault -LogName italog -Credential (Get-Credential Administrator) -Tail 100
```

## Without hardening

With `-SkipHardening` (window: *Apply the vendor hardening* off) the steps `harden-primary` and
`hardening-services` do nothing; the restart still happens. The Vault is installed and works, but the server
keeps its Windows settings. For tests only.

## Limits

- Vault clusters and distributed Vaults are not supported.
- A Vault server must never be joined to a domain; PASeasyInstall refuses that.
