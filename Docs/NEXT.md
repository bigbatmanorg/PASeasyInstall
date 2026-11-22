# What is left to do

Work list for the next sessions, written on 2026-11-22 after release 2.0.3 and updated the same day after the
small fixes. Start at the top. Part 1 is what is left of the small fixes; Part 2 is the four big pieces.

Read first: [`AGENTS.md`](../AGENTS.md) (rules of this repository), [`STATUS.md`](STATUS.md) (what works, what
was tested), [`DESIGN.md`](DESIGN.md) (how a run works).

## How to work

**Keep it simple.** Every piece below comes down to the same four things:

1. deploy the server role or service;
2. connect it to the Vault (and PVWA where needed);
3. verify that the service runs and is registered;
4. show it in the window.

Do not build frameworks, option matrices or abstractions for cases nobody asked for. One way to do each thing,
readable by somebody who did not write it. When the vendor ships an automation script or an answer file, use it.

**Every task is finished only when:**

- it ran on real lab servers, from clean operating systems, without a manual step;
- the unit tests and `Tools\Check-Source.ps1` pass;
- `STATUS.md` says what was tested and with which CyberArk version; this file has the task ticked or removed;
- nothing that was not run is described as working.

**Where things are**

| What | Where |
|---|---|
| Commands | `PASeasyInstall/Public` (one file per command) |
| Run controller, steps, journals | `PASeasyInstall/Private/Run`, `Private/Engine` |
| What runs on the servers | `PASeasyInstall/Recipes/<family>` |
| Window | `PASeasyInstall/Desktop`: `Model.ps1` (data), `Views.ps1` (screens), `App.ps1` (window and events) |
| What the window may call | `PASeasyInstall/Desktop/Backend/Backend.Contract.ps1`; keep the Mock in step |
| Scripted walk through the window | `PASeasyInstall/Desktop/SelfTest.ps1` (scenario file; headless or real window) |

**Testing.** Unit tests need Windows PowerShell 5.1 and Pester 5. Lab servers, addresses, snapshots and the
test harness are described in the private lab notes of the workstation, not in this repository.
A stopped run cannot be continued after the module was changed (it pins its recipe files): when a lab run shows
a defect, fix it, reset that server and start a new run.
The window can be driven without a mouse: `App.ps1 -Backend Live -SelfTest <scenario.json>` walks the screens
through the same functions the buttons call. That is how the real installs through the window were tested.

**Releasing.** Bump `ModuleVersion` in `PASeasyInstall/PASeasyInstall.psd1`, add the release notes
(`site-src/release-notes.md` and `ReleaseNotes` in the manifest), merge to `main`, push tag `v<version>`.
The Release workflow publishes the GitHub release and the PowerShell Gallery package. Publish only when the
owner says so.

---

## Part 1: small fixes (do these first)

Done on 2026-11-22 (in the source, not released; see [STATUS.md](STATUS.md) for what was tested): the server
check verifies the Linux root password; the lab check works without name resolution; a retried CPM registration
uses the existing CPM user; the two excluded tests run in CI again; the window starts an installation in the
background; a reconciled step loses its old error text; a Vault on its own finds the VC++ runtimes in a package
of the media selection; "who installs" values. What is left:

### 1.1 Check by hand what was only tested by script

Needs a person at a Windows desktop, or a real interactive session.

- [ ] `Start-PASeasyInstall` typed into an interactive Windows PowerShell console opens the window (2.0.2 fix).
- [ ] The Servers form: a wrong address and a wrong password are named within seconds; correct entries lead to
      the plan (2.0.3). A wrong Linux root password is named too (2026-11-22, by script only).
- [ ] Dropping a media folder, and single files, on the Media step.
- [ ] The window at its smallest size (480 x 340) and in a remote desktop session.
- [ ] Press *Install* and move the window while "Starting the installation..." is shown: it must stay usable
      (2026-11-22, measured by script only).
- [ ] Advanced view of the Servers step: the two "Who installs" fields.

Fix what does not work. Nothing to build if all pass.

### 1.2 Left over from the small fixes

- [ ] The two tests that were excluded from CI (`ControllerLease.Tests.ps1`, `VaultPadrStandby.Tests.ps1`) pass
      on the Windows Server controller, repeatedly; the exclusion list is empty. Whether they pass on a
      GitHub-hosted runner shows with the first CI run of this branch. If `ControllerLease` fails there, move it
      to `Tests/ci-exclude-hosted.txt`.
- [ ] Install a Vault on its own from the bundle ZIP, without VC++ runtime files in the media folder, once on a
      server (the lookup is unit-tested only).
- [ ] Install CPM, PSM and a Vault once with `-InstallerName` / `-InstallerCompany` (only PVWA was installed
      with them).
- [ ] CPM retry, the one case that cannot be repaired (STATUS.md 3.5): provoke it once through a run, to see the
      message of the step. Cutting the registration about one second after the credential file appears hits it.
- [ ] Old versions: 2.0.0 (no window) and 2.0.1 (does not start from an interactive console) are still listed on
      the PowerShell Gallery. Ask the owner whether to unlist them.
- [ ] Release these changes as 2.0.4 when the owner says so (the release notes have a "Not released yet" section).

---

## Part 2: the big pieces

In this order. Each one: get it working from the prompt first, then add it to the window.

### 2.1 Active Directory and domain-joined components

**Done on 2026-11-22** (in the source, not released): `New-PASLabConfiguration -DomainMode New|Existing`, the domain
controller sets its own DNS, PVWA/CPM/PSM servers are joined before they are installed, the PSM install account
becomes a local administrator of the PSM server, and a lab that creates its domain imports the vendor's hardening
GPOs and applies them to the joined servers (owner's request of 2026-11-22). One lab with a new forest and joined
PVWA, CPM and PSM installed unattended and is healthy. The window has the choice and the extra server line.

**Left** (details in [STATUS.md](STATUS.md) 3.2):

- [ ] Run the window with a new domain against real servers (only the simulated installation was walked).
- [ ] Try `-DomainMode Existing` against a domain that was not created by this tool. The hardening GPOs are
      imported only into a domain the lab creates (owner's decision of 2026-11-22); an existing domain is not changed.
- [ ] Use the vendor's in-domain hardening variants on joined servers (`CPM_In_Domain_Hardening.ps1`, PVWA without
      its INF step), so that the local template and the GPO do not both set the same things.
- [ ] A GPO for a server that holds PSM together with CPM ("Unified" backup in the PSM package).
- [ ] `registerpsmwithdomain`: PSM is registered with local PSMConnect users, as in a workgroup. Domain users for
      PSM were not needed for a healthy lab and are not set up.
- [ ] `Test-PASHealth` should also look at the services, not only at the Vault's "logged on" flag.

### 2.2 HTML5 Gateway

**Done on 2026-11-22** (in the source, not released): component type `HTML5GW` (container with the vendor script,
Docker on Ubuntu), the lab PVWA certificate in its trust folder, registration in the PVWA configuration, the
health page as verification, one more component in the window. Results and limits: [STATUS.md](STATUS.md) 3.4.

**Left**

- [ ] Open a PSM session in a browser through the gateway (by hand; see STATUS.md 3.4 for what the browser needs).
- [ ] Ask the owner for a complete 15.2 gateway package; then let the media selection skip a package that is cut short.
- [ ] Run it on a RHEL-family server (Podman).
- [ ] A gateway certificate of your own (with the Secure profile, 2.3).
- [ ] Add a gateway to a lab that is installed already.

### 2.3 Secure profile

**Out of scope for the lab for now** (owner's decision of 2026-11-22). The profile stays the default of the
commands and stays untested; the window keeps using Lab. What it would need is listed in
[STATUS.md](STATUS.md) 3.1.

### 2.4 PTA

The largest piece. **The unattended configuration is solved** (found on 2026-11-22 with the help of the
`CyberArk-VMware-Lab` project, which configures PTA the same way). Nothing of it is in the module yet.

**What works by hand on PTA 15.2.2 (Rocky Linux 9.9, 8 GB, 4 cores)**

1. Install as before: `pta_installer.sh` (needs `sshpass`, `unzip`, `tar`), then a restart. After it `ptaweb`
   listens on 8443 with the installer application; `appmgr` is not active yet.
2. The server must resolve the PVWA name (hosts entry), and its own name must not point to 127.0.0.1 only.
3. `setenforce 0`. With SELinux enforcing the sign-in of the installer application answers 401.
4. `POST https://localhost:8443/installer/api/getauthtoken` with form fields `username=root` and `password=<root
   password>` returns `{"Authorization": "<token>"}`.
5. `GET https://localhost:8443/installer/api/installation` with `Authorization: Bearer <token>` returns
   `{"status":"NOT_STARTED"}`. **No slash at the end:** with a trailing slash 15.2 answers 404, which is what
   looked like "the call does not exist on 15.2" on 2026-11-21. When the status is SUCCESS or FAILED, a `DELETE`
   on the same address resets it first.
6. `POST` to the same address, JSON body:
   `{"vault":{"ip","port":"1858","timezone":"Europe/Berlin","adminUser","adminPassword","daysActivity":"180"},
   "pvwa":{"connectionMethod":"https","host","port":"443","appContext":"PasswordVault"},
   "syslogInbound":{"inbound_514":"tls","inbound_11514":"tcp,tls"},"skipRestart":"true"}`.
   The status is RUNNING for about a minute (the application does not answer for a moment while it restarts),
   then SUCCESS.
7. `setenforce 1` again. PTA keeps running under enforcing.

**Result in the lab:** all PTA services run (`appmgr`, `ptaweb`, `ptadb`, `ptalistenerd`, `ptaservicesd`, ...),
`Vault.ini` has the Vault address, PTA read the PVWA version, the Vault has the user `PTAAppUser` (so the NFR
licence allows a PTA user), the PTA web page answers, about 3.3 GB of the 8 GB are used with the default heap
sizes. **Not there yet:** the Vault lists PTA as 0 of 1 connected, and PVWA cannot reach PTA (503).

**To do**

1. The component: install, restart, steps 2 to 7. Recipe next to `Recipes/Html5Gateway` (own small `Task.sh`);
   the old PTA branches in `Recipes/LinuxComponent/Task.sh` drive the wizard differently and can go.
2. What `CyberArk-VMware-Lab` (`Scripts/11-InstallPTA-Primary.ps1`, steps 6e to 6j) does after the wizard, to be
   tried one by one: the personal safe of `PTAAppUser` (PVWA REST), the PVWA certificate into PTA's Java trust
   store, the PTA certificate into the trusted roots of the PVWA server, DiamondWebApp, restart of `appmgr`.
3. Vault side (`Scripts/Configure-VaultSyslogToPTA.ps1` there): `dbparm.ini` with `AllowNonStandardFWAddresses`
   for the PTA address and a `[SYSLOG]` section with `Syslog\PTA.xsl`, then a Vault restart; on PTA a plain TCP
   listener on 11514. The Vault recipes for this were removed in commit `b3bffad`.
4. Lower the heap sizes (`/opt/pta/utility/changeComponentResource.sh`) only if 8 GB turn out too small under
   load; at rest it was not needed.
5. Verify: `appmgr` active, Vault shows PTA connected, PVWA shows the PTA component; then the lab check.
6. Window: one more component, needs a RHEL-family server.

**Done when:** a lab with PTA installs unattended on a RHEL-family server with 8 GB, PTA is connected to the
Vault, and the lab check reports it.

---

## Not on this list

- Cluster and distributed Vaults: out of scope by the owner's decision.
- More combinations (three or four instances of a component, PSMP on RHEL 8, SLES and Ubuntu 22): test them when
  somebody needs them.
- Tidying of code carried over from 1.0 (old internal names, dense code): only where a task above touches it.
- The NativeHTMLKit module itself: its interactive-console defect is tracked in its own project (B-0100) and
  needs a release there. PASeasyInstall works around it since 2.0.2.
