# DR Vault

Installs a **standby DR Vault together with a new Primary Vault** and verifies that replication works. Adding a
DR Vault to a Vault that exists already is not supported.

```powershell
Install-PASVault -ComputerName 192.0.2.11 -DRComputerName 192.0.2.12 -MediaPath D:\CyberArk -SecurityProfile Lab -Wait
```

In a lab configuration: `-VaultMode PrimaryDR -PrimaryAddress ... -DRAddress ...`. In the window: **New Vault with
DR** on the Lab step.

## What it needs

- Everything the [Vault](vault.md) needs, plus the Disaster Recovery package (it is in the big ZIP).
- A second Windows Server 2022 that is not member of a domain. The administrator account must have the same
  name as on the Primary Vault server; the password may differ.
- One more password to set: for the Vault user the DR Vault replicates with.

## Steps

The DR Vault is a lane of its own and is installed at the same time as the Primary Vault. It uploads its
media, installs its prerequisites and unpacks while the Primary is installed, installs its Vault server when
the Primary has created the keys, and sets up replication when the Primary is ready. At the end the Primary
creates a small test safe and the DR Vault confirms that it arrived.

| Step | What it does |
|---|---|
| `preflight` to `extract` | As for the Vault, with the Disaster Recovery package instead of PACLI |
| `await-primary-keys`, `relay-shared-keys` | Waits for the keys of the Primary Vault and copies them to the DR server (their content is never logged) |
| `install-dr-server` | Installs the Vault server on the DR server |
| `prepare-standby` | Stops the Vault service of the DR server; its database keeps running |
| `await-primary-ready` | Waits until the Primary Vault is installed and verified |
| `install-padr` | Installs the Disaster Recovery service, pointing at the Primary Vault |
| `configure-padr` | Sets manual failover and starts replication |
| `first-replication` | Waits until a replication cycle was observed |
| `harden-dr`, `hardening-reboot`, `hardening-services` | The vendor's hardening and a restart, as for the Vault |
| `replication-after-hardening` | Replication is observed again after hardening |
| `test-safe-replication` | Confirms that the test safe created on the Primary Vault reached the DR Vault |

**Failover is manual.** The DR Vault never makes itself the Primary.

## While it is installed

The other servers of the lab are installed at the same time and register with the Primary Vault as soon as it
is installed, hardened and checked. Nothing waits for the DR Vault. The DR Vault itself waits only for the keys
of the Primary and then for the Primary being ready.

## Keep the DR Vault running

With a DR Vault, the Vault changes the passwords of the components only after the DR Vault has replicated them.
While the DR Vault is stopped, the component logs show `CASTM057E Password has not yet been replicated to DR
site(s)`. Start the DR Vault and it catches up within one replication cycle.

To include the replication in the lab check from the prompt (the window's **Check the lab**
does it too, with the account of the DR server):

```powershell
Test-PASHealth -Path .\MyLab.json -VaultCredential $vault -DRCredential (Get-Credential Administrator)
```
