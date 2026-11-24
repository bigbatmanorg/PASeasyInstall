# Which servers a lab needs

On the Lab step of the window you choose the Vault (**New Vault** or **New Vault with DR**) and set the number
of each component with **-** and **+**. Each choice decides how many lines the Servers step has.

| What you choose | Servers it needs |
|---|---|
| New Vault | 1 Windows server |
| New Vault with DR | 2 Windows servers |
| Each PVWA | 1 Windows server |
| Each CPM | none when **Install CPM on the PVWA server** is ticked (the default), else 1 Windows server |
| Each PSM | 1 Windows server |
| Each PSMP (PSM for SSH) | 1 Linux server |
| Each HTML5 Gateway | none when **Install the HTML5 Gateway on the PSM for SSH server** is ticked (the default) and there is a PSM for SSH to share, else 1 Linux server |
| Each PTA | 1 Linux server of the RHEL family, with 8 GB |
| New domain (Advanced) | 1 more Windows server, the domain controller |

Some examples:

| Lab | Servers |
|---|---|
| Vault, PVWA with CPM | 2 |
| Vault, PVWA with CPM, PSM | 3 |
| Vault, PVWA with CPM, PSM, PSM for SSH with HTML5 Gateway | 4 |
| Vault, DR Vault, PVWA, CPM, PSM, PSM for SSH, HTML5 Gateway, PTA, each on its own server | 8 (the full lab of the tests) |

Without **Advanced** each counter goes up to 2; with it, up to 4. Two of each were tested. The Vault license
decides how many components can register.

## Sizes that worked

| Server | CPUs | Memory | Disk | Notes |
|---|---|---|---|---|
| Controller | 2 | 8 GB | 100 GB | Windows; keeps the installer cache and the journals |
| Vault | 2 | 4 GB | 100 GB | Windows Server 2022, not in a domain |
| DR Vault | 2 | 4 GB | 100 GB | Windows Server 2022, not in a domain |
| PVWA | 2 | 4 GB | 100 GB | 6 GB when CPM shares the server |
| CPM | 2 | 3 to 4 GB | 100 GB | |
| PSM | 2 | 4 GB | 100 GB | |
| PSM for SSH | 2 | 2 to 4 GB | 40 GB | Ubuntu 24.04; 4 GB with the HTML5 Gateway on it. A gateway on a server of its own: size it like this one |
| PTA | 4 | 8 GB | 80 GB | Rocky Linux 9 |
| Domain controller | 2 | 3 GB | 100 GB | Windows Server 2022 |

These are the sizes of the test lab. They are enough for a lab and below what CyberArk recommends for
production. All servers of a lab are installed at the same time, so the host of your virtual machines needs the
memory for all of them at once.

## Making a lab smaller

- **Put CPM on the PVWA server.** That is the default.
- **Put the HTML5 Gateway on the PSM for SSH server.** That is the default when the lab has both.
- **Leave out what you do not need.** Set its counter to 0.
- **Add later.** Components can be added to a Vault that exists: switch on **Advanced**, choose **Use existing
  Vault (advanced)** on the Lab step, and enter the address of that Vault and the current password of its
  Administrator on the Servers step. From the prompt: `New-PASLabConfiguration -VaultMode Existing`, or
  `Install-PASPVWA`, `Install-PASCPM`, `Install-PASPSM`, `Install-PASPSMP`.

## Rules

- Vault and DR Vault servers must not be members of a domain. They are never joined to one.
- One Vault per lab. A DR Vault only together with a new Vault in the same lab.
- PTA needs a server of its own, a PVWA in the lab, and the PSM for SSH package in the media.
- The HTML5 Gateway needs a PVWA and a PSM in the lab, and the PACLI package in the media.
- A new domain controller gets nothing else installed.
- Every server needs a unique computer name and its own fixed address: the Vault firewall and the components
  refer to addresses.

## When a lab with a DR Vault is stopped and started

Start the Vault first, then the DR Vault, then PVWA and the other components. Keep the DR Vault running while
the components run: with a DR Vault, the Vault changes component passwords only after the DR Vault has
replicated them.
