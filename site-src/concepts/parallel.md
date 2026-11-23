# Servers at the same time

The servers of a lab are installed at the same time. Only what really depends on another server waits.

## Lanes

The controller gives every server a **lane**: the work of that server, in plan order. The lanes run side by
side.

- Components on the same server stay one after the other: a server does one thing at a time.
- The Vault is one lane and its DR Vault another: the DR Vault is prepared while the Primary is installed.
  The new domain controller is one lane.
- Most of the time a lane only waits for the server: the long steps run on the server itself.

## What waits for what

| Who | Waits for | Why |
|---|---|---|
| A server that is joined to a new domain | the new forest | A join needs the DNS of the domain |
| A component on a joined server | the join of its server | The join restarts the server |
| CPM, HTML5 Gateway and PTA on another server than PVWA | the HTTPS certificate of every PVWA | They copy it to trust PVWA. PVWA creates it as its first step, so this is a short wait |
| Every step that signs in to the Vault | the Primary Vault being installed, hardened and checked | It signs in to that Vault. Nothing waits for the DR Vault |
| The DR Vault | the keys of the Primary Vault, then the Primary Vault being ready | It is installed with the same keys and replicates from the Primary |
| Every registration except the first PVWA's | the first PVWA being registered | The others write into the PVWA configuration the first PVWA creates in the Vault |
| CPM | every PVWA being registered | The CPM registration looks at the certificate of every registered PVWA. Only the first PVWA is needed; a second PVWA that fails does not stop CPM |
| PSM, PSM for SSH and the others | every CPM being registered | CyberArk's order: PVWA, then CPM, then the rest. It is an order, not a need: when a CPM fails, the others go on |
| PTA's configuration | every PVWA being finished | It names the PVWA and signs in through it |
| Gateway registration, PVWA trusting PTA, the hardening GPOs | all servers | They change the PVWA server, and the GPOs close the servers down |

Everything else is free: upload, checks, unpacking, prerequisites, the installation itself, hardening and the
final check of a server need no other server.

## One sign-in to the Vault at a time

Several sign-ins as the Vault Administrator at once can lock that user out. So every step that signs in to the
Vault takes the **Vault lock** of the controller first, and gives it back when its session is closed. The
registrations therefore run strictly one at a time, in the order of the table: every PVWA, every CPM, then the
others in the order in which they become ready.

A component that is ready and waits shows *Waiting for its turn at the Vault* in the window.

## Registration comes late

To keep the waiting short, a component does everything that needs no Vault first, where the product allows it
also its hardening, and registers at the end:

| Component | Order after the installation |
|---|---|
| PVWA | HTTPS, hardening, registration |
| PSM for SSH | hardening, registration |
| CPM | registration, hardening |
| PSM | registration, hardening, post-installation |

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
| The Primary Vault | Everything that signs in to it: the registrations, the DR Vault | What needs no Vault is still done on each server, then it stops |
| The first PVWA | CPM, PSM, PSM for SSH, the gateway and PTA (they need its certificate or its configuration in the Vault) | The Vault and the DR Vault |
| The DR Vault, CPM, PSM, PSM for SSH, the HTML5 Gateway, PTA | Nothing | Everything else |
| A new domain controller | The servers that join the domain | Servers that are not joined |

- A server that is not installed for this reason says so on its line: *Not continued: a server it depends on
  failed*. Nothing was started for the step it waited for.
- The HTML5 Gateway is entered into the PVWA configuration only when every PVWA, every PSM and the gateway
  are installed; PVWA trusts PTA only when both are installed. The hardening GPOs of a new domain are applied
  only when everything is installed.
- The run ends as Failed and names the step that failed first, the other servers that failed and those that
  were not installed because of it.

Nothing is undone. Correct the cause and continue with [`Resume-PASRun`](../commands/runs.md#resume-pasrun) or
the buttons of the window. Servers that are installed and verified are left as they are: only the servers that
are not finished are started again. On those, the steps that finished are checked (the window shows *Checking
what is already installed*), then the rest is installed.

A server can be tried again when the run has ended, that is when every other server is finished or has stopped.

## What it saves

Measured in the test lab with CyberArk 15.2, from clean servers:

| Lab | One after the other | At the same time |
|---|---|---|
| Vault, DR Vault, PVWA and CPM on one server, PSM, PSM for SSH | 41 minutes | 23 minutes |
| New domain, Vault, PVWA and CPM on one server, PSM (at the same time also PSM for SSH) | 36 minutes | 20 minutes |

These two were measured with 2.0.5, before PVWA and PSM for SSH registered after their hardening. With that
order (2.0.6): Vault, PVWA, CPM on its own server, PSM and PSM for SSH took 19 minutes; a Full lab with a DR
Vault installed without hardening took 21 minutes.

## The old order

```powershell
New-PASLabConfiguration ... -ExecutionMode Sequential
```

installs one component after the other: the forest, the joins, the Vault and DR Vault, then the other
components in plan order. `Parallel` is the default of new configurations. A configuration file without
`execution.mode` is installed one after the other.

## Limits

- Two instances of each component, and a lab with a DR Vault and a domain together, were not installed at the
  same time yet.
- Five installers at once worked on a small lab host. Whether steps time out on a slower host is not known.
- Once, a step on a Linux server stopped with "SSH observation timed out" while five servers were being
  installed; see [Troubleshooting](../troubleshooting/index.md#ssh-observation-timed-out).
