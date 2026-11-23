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
| Primary Vault installed before any registration | Registration signs in to the Vault. Until 2.0.6 the registrations also waited for the DR Vault; that was not needed (see "Third round"). |
| One Vault sign-in as Administrator at a time | Several at once lock the Administrator out. |
| First PVWA registered before any other component registers | PSM, PSMP, the gateway and PTA write into the PVWA configuration that the first PVWA creates in the Vault. |
| Every PVWA has its certificate before CPM, gateway or PTA start | Their preparation copies the certificates of all PVWA servers. |
| PTA is configured after every PVWA is finished | Its configuration names the PVWA. |
| Gateway registration and PTA trust after their own component prerequisites | They mutate the first PVWA one at a time, but do not wait for unrelated DR, PSMP or other servers. Domain GPO finalization remains at the end. |

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

## Second round (2026-11-22, evening): what needs the Vault comes last

Owner's requests after trying 2.0.5: a CPM on its own server must not wait for PVWA before it even starts; the
registrations must follow the vendor's order (PVWA, CPM, then the rest); and registration should come after
hardening where that is possible, so that a server waits for the Vault only when it has nothing else to do.

- **PVWA creates its certificate as its first step.** Everything that has to trust PVWA (CPM, PSM, gateway, PTA
  on other servers) copies the public certificate then and starts about a minute into the run.
- **Order of the registrations:** every PVWA, every CPM, then PSM, PSMP and the rest.
- **Registration after hardening:** CyberArk's documentation allows it for PVWA and CPM ("it's possible to
  perform hardening before registration") and documents it for PSM (post-installation, hardening,
  registration). What the lab showed (15.2):

| Component | Result | Order now |
|---|---|---|
| PVWA | works | hardening, registration |
| PSMP (Ubuntu 24.04) | works | hardening, registration |
| CPM | hardening fails before registration: it starts the CPM services under a local user and the scanner service of an unregistered CPM does not start | registration, hardening |
| PSM | the registration on a hardened server does its work, and the vendor's `Execute-Stage.ps1` then reports the step as failed with the empty error "The operation completed successfully" | registration, hardening, post-installation |

- **PSM trusts PVWA.** The vendor's PSM registration calls the PVWA API (`ApiKeyManager`). Without trust to the
  PVWA certificate that call fails ("SSL peer certificate or SSH remote key was not OK"); before hardening the
  vendor only warns, so nobody noticed. The installer now adds the public PVWA certificate to the trusted
  roots of the PSM server (Lab), and both `ApiKeyManager` calls succeed.
- **Found on the way:** the PSMP package installation collided with Ubuntu's own package jobs because it now
  starts within the first minute; it waits for them.

Measured, clean servers, 15.2: see [STATUS.md](STATUS.md).

## Third round (2026-11-23): a failure stops only what depends on it

Owner's own test of 2.0.6 on a new lab (nine servers in two networks): PTA was pointed at an Ubuntu server by
mistake and failed after 90 seconds. Every server that was waiting for its turn at the Vault gave up, the Vault
and the DR Vault went on for 13 minutes, and nothing else was installed. Every *Continue* looked at the finished
Vault and DR steps again, which the window showed as an installation.

- **Failure of a lane** (`Set-PASLaneFailed`): signals are needs (`Vault`, `PvwaRegistered`, `Cert:`, `Done:`,
  `Domain`) or orders (`Registered:`). A failed lane fails the needs it owed and releases the orders. PTA, CPM,
  PSM, PSMP, the gateway and the DR Vault owe no need: their failure stops nobody.
- **The DR Vault has its own lane.** Its workflow always waited for the milestones of the Primary by itself;
  only the controller ran it after the Primary. The other servers register when the Primary is ready. The
  replication test (a test safe on the Primary, then on the DR Vault) runs at the end of the DR lane; its one
  sign-in takes the Vault lock like every other.
- **Server check:** a PTA server must be RHEL-family with 8 GB. Before, every Linux server was judged as a PSMP
  server, so PTA on Ubuntu passed.
- **Found on the way:** the CPM Scanner calls PVWA by name and ends when the name does not resolve. The old lab
  hid it (one network, the name resolved by broadcast). CPM and PSM servers now get hosts entries (Lab).

Measured on the new lab (15.2, clean servers, CPM in another network than the Vault): with four lanes failing
at the start (two Linux servers that refused the root password, PTA with a locked root, CPM with the unresolved
name), the Primary Vault was ready after 8.0 minutes, PVWA registered three seconds later, the DR Vault was
replicating after 10.7 minutes and its test safe had arrived after 11.5; Vault, DR Vault, PVWA and PSM were
finished after 17.3 minutes.

## Fourth round (2026-11-23, afternoon): owner's second test, 2.0.7

The run was scheduled as designed (Primary ready after 8 minutes, everything but CPM finished after 21). What
was wrong or looked wrong:

- **The Vault line stayed on "Verify primary"** although the Vault was ready: the test safe belonged to the
  Vault component and was created after the DR Vault replicated. Now the Vault lane creates it right after the
  Primary is ready, and the DR Vault waits for it.
- **Two minutes in `verify-primary`:** two Vault services are delayed-start services. The step starts them.
- **Retry looked like a new installation:** every lane was started again and revalidated. Finished lanes are
  now skipped.
- **CPM registration failed twice** with "Receive object failed" and "failed to decompress data file" while the
  Vault's own log shows no error at those moments: data damaged on the way between a Windows guest on one
  Proxmox node and the Vault on the other. The same NICs stalled iSCSI writes earlier. The lab kit now switches
  LSO, RSC and checksum offload off on the Windows guests. Not proven to be the cause; nothing in the product
  was changed for it.

## Open

- **A step stopped with "SSH observation timed out"** once: the HTML5 Gateway step that followed PSMP on the
  same Linux server, while five servers were being installed. The transfer of the step's inputs over SSH did
  not end within two minutes. The cause is not known. The input stream is now closed after sending, so that a
  transfer that comes up short fails at once instead of waiting; whether that was the cause is not proven.
  The run could be continued by naming the step (`-RetryStep`).
- **Load.** Five installers at once on a small lab host worked. Whether steps time out on a slower host is not known.
- **Two of each component, and three or four**, were not run in parallel yet.
- **PSM in the vendor's order.** Find out why `Execute-Stage.ps1` reports the registration on a hardened PSM
  server as failed although it worked; then PSM could register last too.

## Lab stabilization update (2026-11-23)

The scheduler now launches one **integration lane** beside server lanes. `GatewayRegistration` waits for
verified PVWA + PSM + HTML5 Gateway components; `PtaTrust` waits for verified PVWA + PTA.
A failed dependency skips only the dependent integration. An unrelated ready integration still runs.
Missing or cyclic cross-lane dependencies are rejected before remote dispatch; waits are cancellable
and bounded. A resumed run rechecks successful component readiness instead of unconditionally skipping
entire saved lanes. Details and qualification: [LAB-STABILIZATION.md](LAB-STABILIZATION.md).
