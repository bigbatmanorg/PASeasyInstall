# Installing the servers at the same time

Built and tested on 2026-11-22 (owner's request of the same day). How it works in the code is in
[DESIGN.md](DESIGN.md), section "Servers at the same time". This page says why it is built this way, what was
measured and what is still open.

## Before

One run was one controller process that did everything one after the other: new forest, domain joins, Vault
(and DR), every other component in plan order, then gateway registration, PTA trust and GPOs.
Measured on a Full lab with DR, CyberArk 15.2 (2026-11-21, 41.4 minutes): Vault + DR 15.6, PVWA 7.8, CPM 3.2,
PSM 12.5, PSMP 2.3. Most of that time the controller only waited, and the PSM and PSMP servers were idle for 26
and 39 minutes before their turn came.

## What has to stay in order

| Rule | Why |
|---|---|
| One server does one thing at a time | Installers, MSI and restarts of one server cannot overlap. Components on the same server stay one after the other. |
| New forest before the domain joins | A join needs the domain's DNS. |
| Join of a server before anything is installed on it | The join restarts the server; the PSM install account is a domain account. |
| Vault installed before any registration | Registration signs in to the Vault. With a DR Vault the registrations wait for the end of the whole Vault sequence, because it restarts the Primary Vault while it sets up replication. |
| One Vault sign-in as Administrator at a time | Several at once lock the Administrator out. |
| First PVWA registered before any other component registers | PSM, PSMP, the gateway and PTA write into the PVWA configuration that the first PVWA creates in the Vault. |
| Every PVWA has its certificate before CPM, gateway or PTA start | Their preparation copies the certificates of all PVWA servers. |
| PTA is configured after every PVWA is finished | Its configuration names the PVWA. |
| Gateway registration, PTA trust and GPOs last | They change the PVWA server; the GPOs close the servers down. |

Everything else is free: upload, checks, unpacking, prerequisites, the installation itself, hardening and the
final verification of a server need no other server.

## How it is built

One lane per server inside the controller process, a few signals the lanes wait for, and the Vault lock that
existed already as the queue for the registrations. The registrations after the first PVWA run in the order
in which the servers arrive at the Vault lock, not in plan order. The engine that runs one workflow on one
server is unchanged apart from waiting at the gate. A switch keeps the old order: `execution.mode = Sequential`
(`New-PASLabConfiguration -ExecutionMode Sequential`). New lab configurations are `Parallel`.

## Measured (CyberArk 15.2, clean servers, 2026-11-22)

| Lab | One after the other | At the same time |
|---|---|---|
| Full lab with DR (Vault, DR, PVWA + CPM, PSM, PSMP) | 41 min | 23 min, lab check Healthy |
| New domain with GPOs (forest, two joins, Vault, PVWA + CPM, PSM; in parallel also PSMP) | 36 min | 20 min, through the window, lab check passed |

In that run the registrations ran strictly one at a time (PVWA, PSMP, PSM, CPM). PSM, PSMP and PVWA were ready
to register after 2, 6 and 8 minutes and then waited until the DR Vault was replicating (minute 15).

Other runs of the same day, all from clean servers, all ending Healthy:

- **New domain, PVWA + CPM, PSM, PSMP, HTML5 Gateway, GPOs.** One step stopped on the way (see "Open"), the
  run was continued with `Resume-PASRun -RetryStep` and finished; there is no clean time for this lab yet.
- **Vault, PVWA, PSMP, PTA with a provoked failure** (root of the PSMP server locked): the PSMP lane failed after
  four seconds with the usual message, the Vault finished its installation, PVWA and PTA gave up waiting and
  the run ended Failed after 8 minutes. After the account was unlocked, `Resume-PASRun` finished everything in
  another 7 minutes.

## Open

- **A step stopped with "SSH observation timed out"** once: the HTML5 Gateway step that followed PSMP on the
  same Linux server, while five servers were being installed. The transfer of the step's inputs over SSH did
  not end within two minutes. The cause is not known. The input stream is now closed after sending, so that a
  transfer that comes up short fails at once instead of waiting; whether that was the cause is not proven.
  The run could be continued by naming the step (`-RetryStep`).
- **Registrations wait for the DR Vault.** They could start when the Primary Vault is ready and pause while the
  Vault sequence restarts it. That would save about seven more minutes on a lab with DR.
- **Load.** Five installers at once on a small lab host worked. Whether steps time out on a slower host is not known.
- **Two of each component, and three or four**, were not run in parallel yet.
- **The simulated installer of the window** still installs one component after the other.
