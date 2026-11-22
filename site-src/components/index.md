# Components

Every component is installed by a **recipe**: a list of steps in a fixed order. Each step runs on the server as
a recorded attempt and is verified by a separate check before the next one starts. The product work is done by
the vendor's own installers, registration tools and hardening scripts.

| Component | Type name | Server | State |
|---|---|---|---|
| [Vault](vault.md) | `Vault` | Windows Server 2022, not in a domain | Tested with 15.0 and 15.2 |
| [DR Vault](dr.md) | `DRVault` | Windows Server 2022, not in a domain | Tested with 15.0 and 15.2 |
| [PVWA](pvwa.md) | `PVWA` | Windows Server 2022 | Tested with 15.0 and 15.2 |
| [CPM](cpm.md) | `CPM` | Windows Server 2022 | Tested with 15.0 and 15.2 |
| [PSM](psm.md) | `PSM` | Windows Server 2022 | Tested with 15.0 and 15.2 |
| [PSM for SSH](psmp.md) | `PSMP` | Ubuntu 22.04/24.04, RHEL/Rocky 8/9 | Tested on Ubuntu 24.04 (15.0, 15.2) and once on Rocky 9.9 (15.2) |
| [HTML5 Gateway](html5gw.md) | `HTML5GW` | Linux with Docker or Podman | Experimental |
| [PTA](pta.md) | `PTA` | RHEL/Rocky 8/9 with 8 GB | Experimental |
| [Active Directory](ad.md) | `AD` | Windows Server 2022 | New forest tested; joining a foreign domain not |

The type name is what you write in `New-PASLabConfiguration -Instances @(@{ Type = '...' })` and what
`Get-PASStageCatalog -Component` takes.

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
| PSM | post-installation, hardening, **registration**, final check |
| PSM for SSH | hardening, **registration**, final check |

CPM is the exception: its hardening starts the CPM services under a local user, and they only start once CPM is
registered.

The registrations themselves run one at a time, in the vendor's order: every PVWA, then every CPM, then the
others. See [Servers at the same time](../concepts/parallel.md).

## More than one, and together

- Up to four instances of PVWA, CPM, PSM, PSM for SSH, HTML5 Gateway and PTA are accepted. Two of each were
  tested (not yet at the same time). The Vault license decides how many can register.
- Components can share a server: instances with the same address are installed on one server, one after the
  other. PVWA with CPM, and PSM for SSH with the HTML5 Gateway, were tested.
- One Vault per lab, and at most one DR Vault, which must be installed together with the Vault.
