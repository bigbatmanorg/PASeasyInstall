# Servers at the same time

The servers of a lab are installed at the same time. Only what really depends on another server waits. This
is `execution.mode = Parallel`, the default of `New-PASLabConfiguration` and of the window.

## Lanes

The controller gives every server a **lane**: the work of that server, in plan order. The lanes run side by
side, each in its own runspace of the one controller process.

- Components on the same server stay one after the other: a server does one thing at a time.
- The Primary Vault is one lane and its DR Vault another: the DR Vault is prepared while the Primary is
  installed. A new domain controller is one lane.
- Gateway registration and PTA trust run in one more lane, the **integration lane**. Each starts as soon as
  the components it needs are installed.
- Most of the time a lane only waits for its server: the long steps run on the server itself.

## Signals

The lanes wait for **signals**: wait handles inside the controller process that are set once and stay set.
They leave no file and end with the process.

| Signal | Set when |
|---|---|
| `Domain` | the new forest is installed (set from the start when the lab creates none) |
| `Vault` | the Primary Vault is installed, hardened and verified (set from the start when the run installs no Vault) |
| `Cert:<pvwa>` | that PVWA has its HTTPS certificate (its first step) |
| `PvwaRegistered` | the first PVWA finished its step `register` |
| `Registered:<id>` | that PVWA, CPM, PSM or PSM for SSH finished its step `register` |
| `Done:<id>` | that component is installed and verified |

Most signals are **needs**: who waits for one is not installed when it never comes. `Registered:<id>` is only
an **order**: when that server fails, those that waited for its turn go on.

## What waits for what

| Who | Waits for | Why |
|---|---|---|
| A server joined to a new domain | `Domain`, before its join | A join needs the DNS of the domain |
| A component on a joined server | the join of its server | The join restarts the server; the PSM install account is a domain account |
| CPM, PSM, HTML5 Gateway and PTA on another server than PVWA | `Cert` of every PVWA, before they start | They copy the PVWA certificate to trust it. PVWA creates it as its first step, so this is a short wait |
| Every step that signs in to the Vault | `Vault` | It signs in to that Vault. Nothing waits for the DR Vault |
| The DR Vault | the milestones of the Primary: its keys, then *primary ready* | It is installed with the same keys and replicates from the Primary |
| Every registration except the first PVWA's | `PvwaRegistered` | The others write into the PVWA configuration the first PVWA creates in the Vault |
| CPM | `Registered` of every PVWA (order) | The CPM registration looks at the certificate of every registered PVWA |
| PSM, PSM for SSH | `Registered` of every CPM (order) | The vendor's order: PVWA, CPM, then the rest |
| PTA's Vault steps | `Done` of every PVWA (need); `Registered` of every CPM, PSM and PSM for SSH (order) | PTA's configuration names the PVWA and signs in through it. PTA registers last: its configuration holds the Vault for about three minutes, while PSM still has its hardening after its registration and the gateway registration waits for PSM |
| Gateway registration | `Done` of every PVWA, PSM, HTML5 Gateway and PTA, and of everything else on the first PVWA server | It changes the PVWA configuration in the Vault and restarts the PVWA application pool on the first PVWA server |
| PTA trust | `Done` of every PVWA and PTA, and of everything else on the first PVWA server | It changes the first PVWA server |
| The hardening GPOs of a new domain | the end of every lane | They close the servers down |

Everything else is free: upload, checks, unpacking, prerequisites, the installation itself, hardening and the
final check of a server need no other server.

Before anything is contacted, the controller checks that every signal a component waits for has a lane that
sets it, and that no component waits for one that comes later on its own server. A configuration that would
wait forever is refused at once.

## One sign-in to the Vault at a time

Several sign-ins as the Vault Administrator at once can lock that user out. So every step that signs in to the
Vault takes the **Vault lock** first and gives it back when its session is closed
([Locks](coordination.md#the-vault-lock)). The registrations therefore run strictly one at a time:

1. the first PVWA;
2. the other PVWAs;
3. every CPM;
4. PSM and PSM for SSH, in the order in which they become ready;
5. PTA, last.

Gateway registration also signs in, and takes its turn in the same queue. A component that is ready and waits
shows *Waiting for its turn at the Vault* in the window.

## Registration comes late

To keep the waiting short, a component does everything that needs no Vault first, where the product allows it
also its hardening, and registers at the end. The steps of each type, in order, are listed by
[`Get-PASStageCatalog`](../commands/configuration.md#get-passtagecatalog).

| Component | Order after the installation |
|---|---|
| PVWA | certificate (first step), HTTPS, hardening, registration |
| PSM for SSH | hardening, registration |
| CPM | registration, hardening |
| PSM | registration, hardening, post-installation |
| PTA | registration (it has no separate hardening step) |

CyberArk's documentation allows hardening before registration for PVWA. CPM registers first because its
hardening starts services that need the registration. PSM registers first because the vendor's stage script
reported the registration on a hardened PSM server as failed in the test lab (see [PSM](../components/psm.md)).

## The DR Vault and the replication test

The DR Vault uploads its media, installs its prerequisites and unpacks while the Primary Vault is installed.
It installs its server when the Primary has created the keys, and sets up replication when the Primary is
ready. The other servers register with the Primary meanwhile.

The installation proves that replication works with a small test safe. The Primary creates it as soon as it is
ready (one short sign-in, in the queue like every other); with that the Primary Vault is finished. The DR Vault
is finished when that safe has arrived there.

The Primary is ready as soon as its services run after the restart that follows hardening. Two of them are
"delayed start" services that Windows would start two minutes later; the installation starts them itself.

## When a server fails

A server that fails stops **only what depends on it**. Every other server is installed to the end.

| Fails | Not installed because of it | Goes on |
|---|---|---|
| The Primary Vault | Every step that signs in to it, and the DR Vault | What needs no Vault is still done on each server, then it stops |
| The first PVWA | CPM, PSM, PSM for SSH, PTA, gateway registration and PTA trust | The Vault and the DR Vault |
| Another PVWA | PTA, gateway registration and PTA trust (they need every PVWA finished); when it fails before its certificate, also what trusts the PVWA certificate | CPM, PSM, PSM for SSH (their order only) |
| CPM, PSM for SSH, the DR Vault | Nothing | Everything else |
| PSM | Gateway registration | Everything else, PTA included |
| The HTML5 Gateway | Gateway registration | Everything else |
| PTA | PTA trust and gateway registration | Everything else |
| A new domain controller | The servers that join the domain | Servers that are not joined |

- A server that is not installed for this reason says so on its line: *Not continued: a server it depends on
  failed*. Nothing was started for the step it waited for.
- After a failure the hardening GPOs of a new domain are not applied.
- The run ends as Failed and names the step that failed first, the other servers that failed and those that
  were not installed because of it.

Nothing is undone. Correct the cause and continue with [`Resume-PASRun`](../commands/runs.md#resume-pasrun) or
the buttons of the window. Every lane starts again: on every server the steps that finished are checked again,
read-only (the window shows *Checking what is already installed*); nothing is installed twice. Then the rest is
installed. A step whose result is uncertain is only repeated when you ask for it by name (*Try this step
again*, `-RetryStep`). See [Runs and resume](durable-runs.md).

A server can be tried again when the run has ended, that is when every other server is finished or has stopped.

## What it saves

Measured in the test lab with CyberArk 15.2, from clean servers, with release 2.0.5:

| Lab | One after the other | At the same time |
|---|---|---|
| Vault, DR Vault, PVWA and CPM on one server, PSM, PSM for SSH | 41 minutes | 23 minutes |
| New domain, Vault, PVWA and CPM on one server, PSM, PSM for SSH | 36 minutes | 20 minutes |

The registration order changed since then. The labs run for the current release are in
[Docs/VALIDATION.md](https://github.com/bigbatmanorg/PASeasyInstall/blob/main/Docs/VALIDATION.md).

## The old order

```powershell
New-PASLabConfiguration ... -ExecutionMode Sequential
```

installs one component after the other: the forest, the joins, the Vault and DR Vault, then PVWA, CPM, PSM,
PSM for SSH, HTML5 Gateway and PTA, then gateway registration, PTA trust and the GPOs. A configuration file
without `execution.mode` is installed one after the other too.

## Limits

- Tested with CyberArk 15.0 and 15.2. Two PVWAs and two CPMs in one lab were installed at the same time;
  three or four of a kind were not.
- A lab with a DR Vault and a new domain together was not installed at the same time yet.
- Five installers at once worked on a small lab host. Whether steps time out on a slower host is not known.
- Once, a step on a Linux server stopped with "SSH observation timed out" while five servers were being
  installed; see [Troubleshooting](../troubleshooting/index.md#ssh-observation-timed-out).
