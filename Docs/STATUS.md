# PASeasyInstall 2.0: state of things

One page that says what can be used now, what is experimental and what comes later.
Last updated 2026-11-22, for release 2.0.3.

PASeasyInstall builds **labs**. Everything below was tested with the **Lab** security profile on
Windows Server 2022 and Ubuntu 24.04, from a Windows Server 2022 controller.

## 1. Works now

Tested on real servers, from clean operating systems, without any manual step.

| What | Tested with |
|---|---|
| Primary Vault | CyberArk 15.0 and 15.2 |
| Primary + DR Vault (replication verified) | 15.0 and 15.2 |
| PVWA | 15.0 and 15.2 |
| CPM (also on the PVWA server) | 15.0 and 15.2 |
| PSM | 15.0 and 15.2 |
| PSMP on Ubuntu 24.04 | 15.0 and 15.2 |
| PSMP on Rocky Linux 9.9 (RHEL 9 package) | 15.2, once |
| New Active Directory forest (`Install-PASDomainController`) | Windows Server 2022 |
| Whole lab in one run (`Install-PASLab`) | 15.0: 42 minutes; 15.2: 43 minutes; health check Healthy |
| Two instances of each component in one run (2 x PVWA, CPM, PSM, PSMP) | 15.2, once: 62 minutes, health check Healthy with 2/2 PVWA, 2/2 CPM, 4/4 PSM and PSMP |
| Media as single ZIPs or as the one full bundle ZIP | 15.0 single ZIPs, 15.2 bundle |
| VC++ runtimes for the Vault taken from the CPM, PVWA or PSM package | 15.2 bundle (media check); the installs so far had the runtime files in the folder |
| Run handling: follow, resume after a killed controller, retry one step, stop, second run blocked | 15.0 |
| `Test-PASPreflight`, `Test-PASHealth`, `Export-PASDiagnostics`, `Get-PASRunLog` | 15.0 and 15.2 |

## 2. Experimental

Usable, but expect rough edges. The desktop shows PTA and HTML5 Gateway as not yet installable.

| What | State |
|---|---|
| Desktop window (`Start-PASeasyInstall`) | Rewritten on 2026-11-21 directly on the NativeHTMLKit SDK: four steps, a page per installation, an Advanced switch. A real window installed a Full lab (15.2) on real servers, including a stop with an error, *Try again*, reopening the installation and the lab check. That run was driven by a script calling the same functions as the buttons; clicking through by hand was only done with the simulated installation. Drag and drop of media is not tested by hand. |
| PTA | Not in the module yet. Proven by hand: the 15.2 installer installs on Rocky Linux 9.9 with 8 GB RAM and 4 cores (the documented 16 GB / 8 cores are not enforced). Connecting it to the Vault and PVWA is not done: the installer's REST sign-in only works with SELinux in permissive mode, and the configuration call that worked on 15.0 returns 404 on 15.2. |
| HTML5 Gateway | Not in the module yet. Investigated only: container or RPM install, 2 cores / 4 GB, can share a server with PSMP in theory. Only the 15.0 package can be tested: the 15.2 package in the media bundle is truncated. |

## 3. Next (roadmap after 2.0.0)

The ordered work list with the steps of each item is in [NEXT.md](NEXT.md).

Deferred on purpose so that 2.0.0 could ship as a lab installer that works. In the order they are planned.

### 3.1 Secure profile

WinRM with trusted certificates and none of the lab shortcuts. It is the default of the commands, but it has
never been run. What it needs:

- a certificate authority in the test lab, and server certificates for WinRM and PVWA issued by it;
- CPM trusting that authority instead of a pinned PVWA certificate; no RDP to the hardened Vault;
- one full lab run with it, and a profile choice in the desktop (today the window always uses Lab).

### 3.2 Active Directory and domain-joined components

`Install-PASDomainController` creates a forest and was tested. Missing:

- an option of `New-PASLabConfiguration` (and of the desktop) to create or use a domain;
- joining PVWA, CPM and PSM to it, and a run that proves it;
- the domain controller must use itself as DNS server before the forest is created (today a manual step).

### 3.3 PTA

Not in the module. Known from the 2026-11-21 tests:

- The 15.2 installer installs on Rocky Linux 9.9 with 8 GB RAM and 4 cores. Its own checks look only at the
  operating system version, 2 GB of free disk and a few packages; the documented 16 GB / 8 cores are not enforced.
  Memory use comes from fixed Java heap sizes; the vendor tool `/opt/pta/utility/changeComponentResource.sh`
  changes them. Ubuntu is not supported.
- Still to solve: connecting it to the Vault and PVWA without the interactive wizard. The installer's REST
  sign-in only works with SELinux in permissive mode, and the configuration call that worked on 15.0 returns
  "not found" on 15.2. Candidates: the PTA Ansible role in the media, or driving the wizard.
- Then: Vault syslog forwarding to PTA, the PVWA trusted-connection setting, and a health check.
- The earlier PTA controller code was removed in commit `b3bffad` and can be taken from the history; the
  Linux recipe (`Recipes/LinuxComponent/Task.sh`) still has its PTA branches.

### 3.4 HTML5 Gateway

Not in the module. Known: a Linux gateway (container on Ubuntu or RHEL-family, or an RPM on RHEL-family with
Tomcat), 2 cores and 4 GB, it must trust the PVWA and PSM certificates and needs its own; it can share a
server with PSMP in theory. Only the 15.0 package can be used: the 15.2 package in the media bundle is cut
short and has to be downloaded again.

### 3.5 Smaller items

- **Retry of a CPM registration that failed late.** The vendor tool has by then created the CPM's Vault user and
  a retry creates another one (`PasswordManager1`), which can hit the licence limit of CPM users. Until fixed:
  delete the leftover Vault user before retrying, or install that CPM again on a clean server.
- **Desktop:** starting an installation blocks the window for about half a minute; the root password of a Linux
  server is not verified by the server check (only that SSH answers), so a wrong one shows up when PSMP is installed;
  dropping media on the window was not tried by hand; a Vault on its own does not look for the VC++ runtimes in
  packages that are in the media folder but not part of the lab.
- **`Test-PASHealth`** needs the PVWA name to resolve on the controller (DNS or hosts file).
- **"Who installs" values.** The vendor installers take a user name and a company name; they stay at the vendor
  defaults ("Windows User", "My Company"). Install paths can already be changed through component options.
- **More combinations:** three or four instances of a component (two were tested; more CPMs need a licence
  with more CPM users); PSMP on RHEL 8, SLES and Ubuntu 22 (the media has the packages).
- **Cluster and distributed Vaults.**

## Known limitations of what works now

- The licence decides how many instances can register. The 15.2 NFR licence allows 2 CPM users.
- The PSM service restart after the last reboot was written after one failure and has not been triggered since.
- With several PVWAs, `Test-PASHealth` asks the first one of the configuration.
- A step that was reconciled after a resume keeps the earlier error text in its "Succeeded" message.

More technical debt is listed in [DESIGN.md](DESIGN.md).
