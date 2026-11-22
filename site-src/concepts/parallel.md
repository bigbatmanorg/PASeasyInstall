# Servers at the same time

The servers of a lab are installed at the same time. Only what really depends on another server waits.

## Lanes

The controller gives every server a **lane**: the work of that server, in plan order. The lanes run side by
side.

- Components on the same server stay one after the other: a server does one thing at a time.
- The Vault and its DR Vault are one lane. The new domain controller is one lane.
- Most of the time a lane only waits for the server: the long steps run on the server itself.

## What waits for what

| Who | Waits for | Why |
|---|---|---|
| A server that is joined to a new domain | the new forest | A join needs the DNS of the domain |
| A component on a joined server | the join of its server | The join restarts the server |
| CPM, HTML5 Gateway and PTA on another server than PVWA | the HTTPS certificate of every PVWA | They copy it to trust PVWA. PVWA creates it as its first step, so this is a short wait |
| Every step that signs in to the Vault | the Vault being installed; with a DR Vault, the whole Vault and DR sequence | The sequence restarts the Vault while it sets up replication |
| Every registration except the first PVWA's | the first PVWA being registered | The others write into the PVWA configuration the first PVWA creates in the Vault |
| CPM | every PVWA being registered | The CPM registration looks at the certificate of every registered PVWA |
| PSM, PSM for SSH and the others | every CPM being registered | CyberArk's order: PVWA, then CPM, then the rest |
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
| PSM | post-installation, hardening, registration |
| PSM for SSH | hardening, registration |
| CPM | registration, hardening |

This is the order CyberArk documents for PSM, and CyberArk's documentation allows hardening before registration
for PVWA. CPM registers first because its hardening starts services that need the registration.

## When a server fails

- The lanes that are **working** finish the component they are installing.
- The lanes that are **waiting** for their turn give up. Nothing was started for the step they waited for.
- The run ends as Failed and names the step that failed.

Nothing is undone. Correct the cause and continue: [`Resume-PASRun`](../commands/runs.md#resume-pasrun) starts
every lane again. Steps that finished are only checked.

## What it saves

Measured in the test lab with CyberArk 15.2, from clean servers:

| Lab | One after the other | At the same time |
|---|---|---|
| Vault, DR Vault, PVWA and CPM on one server, PSM, PSM for SSH | 41 minutes | 23 minutes |
| New domain, Vault, PVWA and CPM on one server, PSM (at the same time also PSM for SSH) | 36 minutes | 20 minutes |

These times were measured before registration was moved behind hardening.

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
- With a DR Vault the registrations wait for the whole Vault and DR sequence, although the Primary Vault is
  ready earlier.
- Five installers at once worked on a small lab host. Whether steps time out on a slower host is not known.
- Once, a step on a Linux server stopped with "SSH observation timed out" while five servers were being
  installed; see [Troubleshooting](../troubleshooting/index.md#ssh-observation-timed-out).
