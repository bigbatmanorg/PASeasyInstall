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

Usable, but expect rough edges. The desktop shows PTA as not yet installable.

| What | State |
|---|---|
| Desktop window (`Start-PASeasyInstall`) | Rewritten on 2026-11-21 directly on the NativeHTMLKit SDK: four steps, a page per installation, an Advanced switch. A real window installed a Full lab (15.2) on real servers, including a stop with an error, *Try again*, reopening the installation and the lab check. That run was driven by a script calling the same functions as the buttons; clicking through by hand was only done with the simulated installation. Drag and drop of media is not tested by hand. Since 2026-11-22 *(not released)* the installation is started in the background: with the real installer and a window without a display (scripted walk), the window was free at once and the installation of a PVWA and a PSMP (15.2) for an existing Vault had started 4 seconds later; it finished in 11 minutes and the lab check from the window was Healthy. Not yet seen in a visible window. |
| PTA | Not in the module yet. Proven by hand on 2026-11-22: PTA 15.2.2 installs on Rocky Linux 9.9 with 8 GB and 4 cores and can be configured without the wizard, through the installer's own REST interface (the steps are in NEXT.md 2.4). After it all PTA services run and the Vault has the PTA user; the Vault does not list PTA as connected yet and PVWA cannot reach it: certificates, PVWA settings and Vault syslog are still to do. |
| HTML5 Gateway (component type `HTML5GW`) *(not released)* | Installs with `html5_console.sh` from the 15.0 package on Ubuntu 24.04 (Docker), on the PSMP server, 4 GB. 2026-11-22, one lab from clean servers (15.2 Vault, PVWA, CPM, PSM, PSMP; gateway 15.0): the gateway step took about two minutes, its health page answers 200, PVWA has the gateway entry for the PSM server, lab check Healthy. The controller process of that run crashed once during the Vault upload (Windows PowerShell remoting exception on the shared controller VM); `Resume-PASRun` continued it without any other step by hand. Not done: a PSM session opened in a browser through the gateway |

## 3. Next (roadmap after 2.0.0)

The ordered work list with the steps of each item is in [NEXT.md](NEXT.md).

Deferred on purpose so that 2.0.0 could ship as a lab installer that works. In the order they are planned.

### 3.1 Secure profile

Out of scope for the lab for now (owner's decision of 2026-11-22). WinRM with trusted certificates and none of
the lab shortcuts is the default of the commands, but it has never been run. What it would need:

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

Not in the module. The unattended configuration, which was the open question, works by hand on 15.2 (see the
table in section 2 and NEXT.md 2.4 for the exact calls). Left: the component itself, the trust between PTA and
PVWA in both directions, the PVWA settings for PTA, Vault syslog forwarding to PTA, and a health check.
Ubuntu is not supported by the vendor; the documented 16 GB / 8 cores are not enforced by the installer.

### 3.4 HTML5 Gateway

Installs as a container with the vendor's own script (see the table in section 2). What is left:

- **A session in the browser was not opened.** That is the last proof and needs a person: sign in to PVWA, connect
  to an account through PSM and choose the HTML5 connection. The browser must resolve the PVWA name and the
  gateway name (hosts entries), and it will warn about the gateway's own certificate.
- **Certificate of the gateway:** the container makes its own for its host name. A certificate of your own is
  not supported yet (the container takes one through the settings GWCert, GWKey and GWCAFile).
- **PSM certificate:** in the Lab profile the gateway does not check the certificate of the PSM server
  (`IgnorePSMCertificateErrors`). The Secure profile was not run.
- **Only in a lab that also installs a PVWA:** the gateway is entered into the PVWA configuration from a PVWA
  server of the same run. Adding a gateway later to an installed lab is not possible yet.
- **Registration by PACLI.** The vendor has no tool for the PVWA entry. The installer takes `PVConfiguration.xml`
  from the Vault safe `PVWAConfig` with PACLI (on the PVWA server), adds the gateway and the reference in every
  PSM server entry, stores it and restarts the PVWA application. All PSM servers get the last gateway.
- **RHEL family (Podman):** the recipe has that branch, taken from the vendor script; only Ubuntu 24.04 with
  Docker was run.
- **Media:** the 15.2 gateway package inside the 15.2 bundle is cut short; the unpack step says so. With that
  bundle in the media folder the 15.0 package has to be chosen by hand (`$media.HTML5GW = ...`), because the
  higher version wins. In the window this cannot be chosen yet.

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
