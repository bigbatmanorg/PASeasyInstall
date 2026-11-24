# Components

Every component is installed by a **recipe**: a list of steps in a fixed order. Each step runs on the server as
a recorded attempt and is verified by a separate check before the next one starts. The product work is done by
the vendor's own installers, registration tools and hardening scripts.

| Component | Type name | Server | Tested |
|---|---|---|---|
| [Vault](vault.md) | `Vault` | Windows Server 2022, not in a domain | 15.0 and 15.2 |
| [DR Vault](dr.md) | `DRVault` | Windows Server 2022, not in a domain | 15.0 and 15.2 |
| [PVWA](pvwa.md) | `PVWA` | Windows Server 2022 | 15.0 and 15.2 |
| [CPM](cpm.md) | `CPM` | Windows Server 2022 | 15.0 and 15.2 |
| [PSM](psm.md) | `PSM` | Windows Server 2022 | 15.0 and 15.2 |
| [PSM for SSH](psmp.md) | `PSMP` | Ubuntu 22.04/24.04, RHEL/Rocky 8/9 | Ubuntu 24.04 (15.0, 15.2); once on Rocky 9 |
| [HTML5 Gateway](html5gw.md) | `HTML5GW` | Linux with Docker or Podman | Ubuntu 24.04, with a 15.0 gateway package |
| [PTA](pta.md) | `PTA` | RHEL, Rocky or Alma 8.8+/9.3+ with 8 GB | PTA 15.2.2 on Rocky 9.9 |
| [Active Directory](ad.md) | `AD` | Windows Server 2022 | New forest tested; joining a foreign domain not |

Everything was tested with the Lab profile only.

The type names PVWA, CPM, PSM, PSMP, HTML5GW and PTA are what you write in
`New-PASLabConfiguration -Instances @(@{ Type = '...' })`. The Vault and the DR Vault come from `-VaultMode`,
the domain controller from `-DomainMode New`. `Get-PASStageCatalog -Component` takes the same names, with `DR`
for the DR Vault and `DomainJoin` for the join of a server.

## The order of the steps

```powershell
Get-PASStageCatalog -Component PVWA | Format-Table Order, Stage
```

lists the steps of a component in the order they run. The step names are the ones you see in the window, in
`Get-PASRunEvent`, and that `Resume-PASRun -RetryStep` takes.

Every component first does what needs no other server: upload, checks, unpacking, prerequisites, the
installation itself. **Registration with the Vault comes as late as possible**, after hardening where the
product allows it, so that a server only waits for the Vault when it has nothing else left to do:

| Component | After the installation |
|---|---|
| PVWA | HTTPS, hardening, **registration**, final check |
| CPM | trusting the PVWA certificate, **registration**, hardening, final check |
| PSM | **registration**, hardening, post-installation, final check |
| PSM for SSH | hardening, **registration**, final check |
| PTA | restart, **registration** (the vendor's automatic configuration), final check |
| HTML5 Gateway | final check; it is entered into the PVWA configuration at the end of the run |

CPM and PSM are the exceptions. PSM: on a hardened PSM server the vendor's stage script reported the
registration as failed in the test lab, although it had done its work (see [PSM](psm.md)).
CPM: its hardening starts the CPM services under a local user, and they only start once CPM is
registered.

The registrations themselves run one at a time, in the vendor's order: every PVWA, then every CPM, then PSM and
PSM for SSH. PTA registers last, because its configuration holds the Vault for about three minutes. See
[Servers at the same time](../concepts/parallel.md).

## More than one, and together

- Up to four instances of PVWA, CPM, PSM, PSM for SSH and HTML5 Gateway are accepted (the window allows two
  without **Advanced**). Two of each were tested. The Vault license decides how many can register. PTA: one per
  lab; every PTA signs in to the Vault as the same user ([PTA](pta.md)).
- Components can share a server: instances with the same address are installed on one server, one after the
  other. PVWA with CPM, and PSM for SSH with the HTML5 Gateway, were tested. PTA needs a server of its own.
- One Vault per lab, and at most one DR Vault, which must be installed together with the Vault.
