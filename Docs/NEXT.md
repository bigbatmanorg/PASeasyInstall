# What is left to do

Work list for the next sessions, written on 2026-11-22 after release 2.0.3.
Start at the top. Part 1 is small fixes; Part 2 is the four big pieces.

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
The window can be driven without a mouse: `App.ps1 -Backend Live -SelfTest <scenario.json>` walks the screens
through the same functions the buttons call. That is how the real installs through the window were tested.

**Releasing.** Bump `ModuleVersion` in `PASeasyInstall/PASeasyInstall.psd1`, add the release notes
(`site-src/release-notes.md` and `ReleaseNotes` in the manifest), merge to `main`, push tag `v<version>`.
The Release workflow publishes the GitHub release and the PowerShell Gallery package. Publish only when the
owner says so.

---

## Part 1: small fixes (do these first)

Each is a short, separate change. Do them in this order.

### 1.1 Check by hand what was only tested by script

Needs a person at a Windows desktop, or a real interactive session.

- [ ] `Start-PASeasyInstall` typed into an interactive Windows PowerShell console opens the window (2.0.2 fix).
- [ ] The Servers form: a wrong address and a wrong password are named within seconds; correct entries lead to
      the plan (2.0.3).
- [ ] Dropping a media folder, and single files, on the Media step.
- [ ] The window at its smallest size (480 x 340) and in a remote desktop session.

Fix what does not work. Nothing to build if all four pass.

### 1.2 The server check does not verify the Linux root password

`Test-PASPreflight` only checks that SSH answers when the controller's SSH key does not exist yet, so a wrong
root password shows up only when PSMP is installed.

- Do: in `PASeasyInstall/Public/Test-PASPreflight.ps1`, when a credential for the Linux server was given, try a
  password sign-in the same way the first installation does (`Invoke-PASSshBootstrap` in `Private/Run/Bootstrap.ps1`
  shows how) and report the result. Read-only: do not authorise the key in a check.
- Done when: a wrong root password is reported by the check, in the window and from the prompt.

### 1.3 The lab check needs the PVWA name to resolve

`Test-PASHealth` fails with a clear message when the PVWA server name does not resolve on the controller. Every
lab test so far needed a hosts entry. The address is known from the configuration.

- Do: when the name does not resolve, connect to the PVWA address of the configuration and send the server name
  in the TLS handshake and the Host header, so that IIS presents the right certificate. Do not fall back to the
  bare IP address: IIS then presents another certificate (tried on 2026-11-21, it fails the pinned check).
- Done when: `Test-PASHealth` and "Check the lab" pass on a lab without any hosts entry or DNS record.

### 1.4 Retry of a CPM registration creates a second CPM user

When the CPM registration fails late, the vendor tool has already created the Vault user. `Resume-PASRun
-RetryStep <cpm>:register` then creates `PasswordManager1` and can hit the licence limit (ITATS937E).

- Do: before the register step runs again, find out whether the CPM user of this component exists in the Vault
  (the recipe is `Recipes/WindowsComponent/Task.ps1`, stage `Register`; the option `registrationMode = Upgrade`
  exists). Use the vendor's repair/upgrade path when it does. Try it on a server first: the behaviour of the
  vendor tool in that mode is not known.
- Done when: a registration that was made to fail late is retried and ends with one CPM user in the Vault.

### 1.5 Two tests are excluded from CI

`Tests/ci-exclude.txt` lists `ControllerLease.Tests.ps1` (one timing-dependent test) and
`VaultPadrStandby.Tests.ps1` (one assertion out of date).

- Do: fix or delete each of the two tests; empty the exclusion list.

### 1.6 Smaller things

- [ ] Starting an installation freezes the window for about half a minute. Run `Install-PASLab` the way the
      server check runs (`Start-NativeHTMLKitTask`, see `Start-PASUIServerCheck` in `Desktop/App.ps1`).
- [ ] A step that was reconciled after a resume keeps the earlier error text in its "Succeeded" message
      (seen as `Succeeded: PAExecUnknown: ...`). Clear the message when the step succeeds.
- [ ] A Vault on its own, chosen in the window, does not find the VC++ runtimes in packages that are in the media
      folder but not part of the lab. Hand the CPM, PVWA and PSM items of the media selection to
      `Resolve-PASMediaProfile -ComponentPackages` also when they are not installed.
- [ ] "Who installs": the vendor installers take a user name and a company name. Add two optional values to the
      configuration (defaults as today) and write them into `InstallationConfig.xml` of PVWA, CPM and PSM and
      into the Vault response file. One Advanced field pair in the window.
- [ ] Old versions: 2.0.0 (no window) and 2.0.1 (does not start from an interactive console) are still listed on
      the PowerShell Gallery. Ask the owner whether to unlist them.

---

## Part 2: the big pieces

In this order. Each one: get it working from the prompt first, then add it to the window.

### 2.1 Active Directory and domain-joined components

**Works today:** `Install-PASDomainController` creates a new forest (tested on Windows Server 2022).

**To do**

1. The domain controller must use itself as DNS server before the forest is created. Today that is a manual
   step (`Recipes/ActiveDirectory/AD-Task.ps1` stops with instructions). Set it in the recipe.
2. A domain option for a lab: `New-PASLabConfiguration` gets parameters for "create a new forest on this server"
   and "use this existing domain". The configuration already has an `activeDirectory` section
   (`Private/Config/Composition.ps1`); fill it.
3. Join PVWA, CPM and PSM to the domain before they are installed (the servers reboot once), with DNS pointing
   to the domain controller. PSM registered with domain accounts where the vendor asks for it
   (`registerpsmwithdomain`). The Vault servers are never joined.
4. Window: one choice on the Lab step (no domain / new domain / existing domain) and one more server line.

**Done when:** one lab with a new forest and domain-joined PVWA, CPM and PSM installs unattended, and the lab
check is healthy.

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
