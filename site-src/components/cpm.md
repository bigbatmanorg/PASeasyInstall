# CPM

Installs the Central Policy Manager, which changes and verifies passwords, on a Windows Server 2022 and
registers it with the Vault. CPM can share the PVWA server or have a server of its own.

```powershell
Install-PASCPM -ComputerName 192.0.2.22 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArk -SecurityProfile Lab -Wait
```

In a lab configuration: `@{ Type = 'CPM'; Name = 'CPM01'; Address = '192.0.2.21' }`. An instance with the
address of the PVWA instance shares its server. In the window: *Install CPM on the PVWA server* on the Lab step.

## What it needs

- The CPM package (`Central Policy Manager-Rls-...zip`, or the big ZIP).
- The password of the Vault user Administrator, to register.
- **To trust PVWA.** The CPM registration looks at the HTTPS certificate of every PVWA that is registered in the
  Vault. With the Lab profile the installer copies the public certificate of the lab PVWA and CPM trusts exactly
  that certificate (shown as the lab shortcut `CPM.AllowPinnedLeafTrust`). With `Install-PASCPM` alone, pass it
  with `-PvwaCertificateFile`.

## Steps

| Step | What it does |
|---|---|
| `management`, `media-upload` | As for [PVWA](pvwa.md) |
| `pvwa-trust-certificate` | Lab: copies the public certificate of PVWA to the server, verified by its SHA-256 |
| `preflight`, `extract` | As for PVWA |
| `prerequisites` | The vendor's prerequisites script |
| `install` | The vendor's installation; creates the services *CyberArk Password Manager* and *CyberArk Central Policy Manager Scanner* |
| `configuretls` | Trusts the PVWA certificate (Lab), or requires a trusted chain (Secure) |
| `register` | Registers the CPM user with the Vault. Waits for the Vault and for every PVWA to be registered |
| `harden` | The vendor's CPM hardening; the services then run under a local user |
| `verify` | Both services run |

CPM registers **before** its hardening. Its hardening starts the CPM services under a local user, and the
scanner service of a CPM that is not registered does not start. (PVWA, PSM and PSM for SSH register after their
hardening.)

## On its own server

A CPM on its own server starts shortly after the run starts, as soon as PVWA has created its certificate, and
is installed while PVWA is installed. On the PVWA server it is installed after PVWA has finished.

## Retrying a registration

If a CPM registration stopped after it had created the CPM user in the Vault, `Resume-PASRun -RetryStep
<cpm id>:register` registers again with the existing user. One case cannot be repaired: when the first attempt
was cut within about two seconds after it created the CPM safes. The step then fails and says so; that CPM has
to be installed again on a clean server after its Vault user and safes were deleted.

## Limits

- The Vault license decides how many CPMs can register. The 15.2 evaluation license used in the tests allows two.
- Options for `Install-PASCPM -Options`: `installDirectory`, `cpmUser`, `vaultPort`, `registrationMode`,
  `hardeningScript`.
