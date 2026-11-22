# PASeasyInstall 2.0: state of things

One page that says what can be used now, what is experimental and what comes later.
Last updated 2026-11-22, after release 2.0.3. Rows marked *(not released)* are in the source after 2.0.3.

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
| Lab with a new domain *(not released)*: new forest, PVWA + CPM server and PSM server joined, Vault, PVWA, CPM, PSM, then the CyberArk hardening GPOs of the vendor packages imported, linked and applied (`New-PASLabConfiguration -DomainMode New`) | 15.2 on Windows Server 2022, 2026-11-22, once from clean servers in one run: 36 minutes, lab check Healthy; after a restart of the joined servers all services came up again and the check stayed Healthy |
| Whole lab in one run (`Install-PASLab`) | 15.0: 42 minutes; 15.2: 43 minutes; health check Healthy |
| Two instances of each component in one run (2 x PVWA, CPM, PSM, PSMP) | 15.2, once: 62 minutes, health check Healthy with 2/2 PVWA, 2/2 CPM, 4/4 PSM and PSMP |
| Media as single ZIPs or as the one full bundle ZIP | 15.0 single ZIPs, 15.2 bundle |
| VC++ runtimes for the Vault taken from the CPM, PVWA or PSM package | 15.2 bundle (media check); the installs so far had the runtime files in the folder |
| Run handling: follow, resume after a killed controller, retry one step, stop, second run blocked | 15.0 |
| `Test-PASPreflight`, `Test-PASHealth`, `Export-PASDiagnostics`, `Get-PASRunLog` | 15.0 and 15.2 |
| Server check names a wrong Linux root password, from the prompt and in the window *(not released)* | Ubuntu 24.04, 2026-11-22: right, wrong and no password; nothing is changed on the server |
| Lab check without DNS record or hosts entry for the PVWA name *(not released)* | 15.2, 2026-11-22: `Test-PASHealth` from the prompt and *Check the lab* in the window, Healthy |
| Retry of a CPM registration that failed after its Vault user was created *(not released)* | 15.2, 2026-11-22: registration ended by force right after the user was created, and again during the platform import; `Resume-PASRun -RetryStep cpm:register` ended both times with one CPM user, the CPM connected and all platforms imported |
| "Who installs" values (`-InstallerName`, `-InstallerCompany`) *(not released)* | PVWA 15.2: the installed product shows them as registered owner and company. CPM, PSM and the Vault use the same values but were not installed with them yet |

## 2. Experimental

Usable, but expect rough edges. The desktop shows PTA and HTML5 Gateway as not yet installable.

| What | State |
|---|---|
| Desktop window (`Start-PASeasyInstall`) | Rewritten on 2026-11-21 directly on the NativeHTMLKit SDK: four steps, a page per installation, an Advanced switch. A real window installed a Full lab (15.2) on real servers, including a stop with an error, *Try again*, reopening the installation and the lab check. That run was driven by a script calling the same functions as the buttons; clicking through by hand was only done with the simulated installation. Drag and drop of media is not tested by hand. Since 2026-11-22 *(not released)* the installation is started in the background: with the real installer and a window without a display (scripted walk), the window was free at once and the installation of a PVWA and a PSMP (15.2) for an existing Vault had started 4 seconds later; it finished in 11 minutes and the lab check from the window was Healthy. Not yet seen in a visible window. |
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

A lab with a new domain works (see the table in section 1). What is left:

- **Existing domain** (`-DomainMode Existing`): the servers join through a DNS server of the domain with a domain
  account. Only the join itself ran in the lab (a PSM server joined the lab's own domain that way and PSM was
  installed on it); a domain that this tool did not create was not tried. The hardening GPOs are not imported
  into an existing domain, by the owner's decision: its administrators do that.
- **GPO and the vendor's local hardening together.** On a joined server the vendor scripts still apply their local
  security template where the vendor offers an in-domain variant instead (`CPM_In_Domain_Hardening.ps1`; the INF
  step of `PVWA_Hardening.ps1`). The GPO wins where both set the same thing. PSM already skips its out-of-domain step.
- **Role combinations without a vendor GPO choice:** a server with PSM and another component gets no GPO (there is a
  "Unified" PSM + CPM backup in the PSM package; not used yet).
- **Window with a domain:** the choice on the Lab step and the extra line on the Servers step were walked with the
  simulated installation only, not with real servers.
- **`Test-PASHealth` trusts the Vault's "logged on" flag.** A component whose service is stopped can still be
  shown as connected for a while (seen on 2026-11-22 with a PSM service that could not start).
- The firewall of a joined server is turned on by the GPOs. The installer adds one rule before that
  ("PASeasyInstall management (WinRM)", its own management port, program System). It stays after the installation.

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

- **Retry of a CPM registration: one case is left.** The retry registers again with the existing CPM user. When
  the first attempt was cut after it created the CPM safes but before it added their members (a window of about
  two seconds), the vendor tool cannot finish the CPM environment: no platform is imported. The step then fails
  and says so; that CPM has to be installed again on a clean server after its Vault user and safes were deleted.
  Seen by hand on 2026-11-22 before the check was written; the check itself has unit tests only.
- **Desktop:** dropping media on the window, the smallest window size and a remote desktop session were not tried
  by hand (see NEXT.md 1.1).
- **A Vault on its own** now takes the VC++ runtimes from a CPM, PVWA or PSM package of the media selection.
  Unit-tested with a synthetic bundle; not yet installed that way on a server.
- **More combinations:** three or four instances of a component (two were tested; more CPMs need a licence
  with more CPM users); PSMP on RHEL 8, SLES and Ubuntu 22 (the media has the packages).
- **Cluster and distributed Vaults.**

## Known limitations of what works now

- The licence decides how many instances can register. The 15.2 NFR licence allows 2 CPM users.
- The PSM service restart after the last reboot was written after one failure and has not been triggered since.
- With several PVWAs, `Test-PASHealth` asks the first one of the configuration.

More technical debt is listed in [DESIGN.md](DESIGN.md).
