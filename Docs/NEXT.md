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

**Known:** a Linux gateway that lets users open PSM sessions in the browser. 2 cores and 4 GB are enough. It can
share the server with PSMP. Vendor pages: "Install PSM HTML5 Gateway" (container and RPM).

**Media:** use the 15.0 package. The 15.2 package inside the 15.2 bundle is cut short (it ends inside the
container image); ask the owner for a fresh download before testing 15.2.

**To do**

1. New component type in the Linux recipes. Take the container path: `html5_console.sh install -l`, then
   `html5_console.sh run` with a certificate folder and the environment values (`AcceptCyberArkEULA`,
   `EndPointAddress` = PVWA URL, gateway certificate and key). Docker on Ubuntu, Podman on RHEL-family.
2. Certificates: the gateway needs its own, and must trust the PVWA and PSM certificates. In the Lab profile,
   reuse the lab PVWA certificate that is saved with the run, and `IgnorePSMCertificateErrors` is acceptable.
3. Register the gateway for the PSM server in PVWA (PVWA configuration of the PSM server).
4. Verify: `https://<gateway>/guac/rest/healthcheck` answers 200.
5. Window: one more component on the Lab step, on the PSMP server by default.

**Done when:** a lab with PSM and the gateway installs unattended, the health URL answers, and a PSM session
opens in a browser through the gateway (this last check can be manual).

### 2.3 Secure profile

**State:** the default profile of the commands, never run. The window always uses Lab.

**To do**

1. A certificate authority in the test lab and a repeatable way to issue server certificates (the domain
   controller of 2.1 with AD CS, or a small openssl CA; pick the simpler one).
2. WinRM over HTTPS with certificates of that authority on every Windows server; no `SkipCACheck` /
   `SkipCNCheck`.
3. PVWA with a certificate of that authority; CPM trusts the authority (`-PvwaCertificateFile` with the CA
   certificate), not a pinned PVWA certificate.
4. No RDP to the hardened Vault; no lab deviation left in the plan.
5. Window: a profile choice in Advanced, and a place to give the CA certificate.

**Done when:** one full lab installs with `-SecurityProfile Secure`, the plan lists no deviation, and the lab
check is healthy.

### 2.4 PTA

The largest and least certain piece. Find out the unattended method first; do not write module code before
that works by hand.

**Known from 2026-11-21**

- The 15.2 installer (`pta_installer.sh`) installs on Rocky Linux 9.9 with 8 GB RAM and 4 cores in under
  30 minutes. Its checks look only at the operating system version (RHEL-family 8.8+ / 9.3+), 2 GB of free disk
  and a few packages (`sshpass`, `unzip`, `tar` must be there). The documented 16 GB / 8 cores are not enforced.
  Ubuntu is not supported.
- Before configuration it uses about 1.5 GB. Memory use comes from fixed Java heap sizes (Listener 2 to 8 GB,
  scheduler up to 4 GB, ActiveMQ up to 5 GB). The vendor tool `/opt/pta/utility/changeComponentResource.sh
  -c <id> -m <size>` changes them. 8 GB works in another lab; 4 GB is reported to thrash.
- Unattended configuration is not solved. The installer's REST sign-in (`/installer/api/getauthtoken` on port
  8443, user root) only works with SELinux in permissive mode: the PTA SELinux policy stops it from running
  `su`. The configuration call that works on 15.0 (`POST /installer/api/installation/`) returns 404 on 15.2.
- It is not known whether the lab licence covers PTA.

**To do**

1. Find the working unattended configuration on 15.2: try the PTA Ansible role shipped in the media
   (`PTA-Ansible-Role`), then the documented "PTA automatic installation" calls, then the wizard
   (`/opt/pta/prepwiz/run.sh`) with scripted answers. Write down what works.
2. Then the component: install, reboot, configure against the Vault and PVWA, lower the heap sizes when the
   server has less than 16 GB.
3. Vault side: syslog forwarding to PTA (`dbparm.ini` plus the `PTA.xsl` translator), and the PVWA
   trusted-connection setting. The Vault recipes for this were removed in commit `b3bffad` and can be taken from
   the history; `Recipes/LinuxComponent/Task.sh` still has PTA branches.
4. Verify: PTA services run (`appmgr`), PTA is connected to the Vault, the PVWA shows the PTA component.
5. Window: one more component, needs a RHEL-family server.

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
