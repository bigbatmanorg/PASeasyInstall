# Which servers a lab needs

## The ready-made labs

| Lab | Servers |
|---|---|
| **Starter** | Vault · PVWA with CPM |
| **Standard** | Vault · PVWA with CPM · PSM |
| **Full** | Vault · DR Vault · PVWA with CPM · PSM · PSM for SSH |

Add one server when CPM gets a server of its own, one for a new domain controller, one Linux server for PTA, and
one Linux server for an HTML5 Gateway when the lab has no PSM for SSH server it can share.

## Sizes that worked

| Server | CPUs | Memory | Disk | Notes |
|---|---|---|---|---|
| Controller | 2 | 8 GB | 100 GB | Windows; keeps the installer cache and the journals |
| Vault | 2 | 4 GB | 100 GB | Windows Server 2022, not in a domain |
| DR Vault | 2 | 4 GB | 100 GB | Windows Server 2022, not in a domain |
| PVWA | 2 | 4 GB | 100 GB | 6 GB when CPM shares the server |
| CPM | 2 | 3 to 4 GB | 100 GB | |
| PSM | 2 | 4 GB | 100 GB | |
| PSM for SSH | 2 | 2 to 4 GB | 40 GB | Ubuntu 24.04; 4 GB with the HTML5 Gateway on it |
| PTA | 4 | 8 GB | 80 GB | Rocky Linux 9 |
| Domain controller | 2 | 3 GB | 100 GB | Windows Server 2022 |

These are the sizes of the test lab. They are enough for a lab and below what CyberArk recommends for
production. All servers of a lab are installed at the same time, so the host of your virtual machines needs the
memory for all of them at once.

## Making a lab smaller

- **Put CPM on the PVWA server.** That is the default.
- **Put the HTML5 Gateway on the PSM for SSH server.**
- **Leave out what you do not need.** Only the Vault is required, and with *A Vault I already have* not even
  that.
- **Add later.** Components can be added to a Vault that exists: choose *A Vault I already have* in the Custom
  lab, or use `Install-PASPVWA`, `Install-PASCPM`, `Install-PASPSM`, `Install-PASPSMP`.

## Rules

- Vault and DR Vault servers must not be members of a domain.
- One Vault per lab. A DR Vault only together with a new Vault.
- PTA needs a server of its own. A new domain controller gets nothing else installed.
- Every server needs a unique computer name and a fixed address: the Vault firewall and the components refer to
  addresses.

## When a lab with a DR Vault is stopped and started

Start the Vault first, then the DR Vault, then PVWA and the other components. Keep the DR Vault running while
the components run: with a DR Vault, the Vault changes component passwords only after the DR Vault has
replicated them.
