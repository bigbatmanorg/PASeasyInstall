# PASeasyInstall 2.0: state of things

One page that says what can be used now, what is experimental and what comes later.
Last updated 2026-11-22, for release 2.0.6. Rows marked *(2.0.6)* are new in 2.0.6.

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
| Lab with a new domain *(2.0.4)*: new forest, PVWA + CPM server and PSM server joined, Vault, PVWA, CPM, PSM, then the CyberArk hardening GPOs of the vendor packages imported, linked and applied (`New-PASLabConfiguration -DomainMode New`) | 15.2 on Windows Server 2022, 2026-11-22, once from clean servers in one run: 36 minutes, lab check Healthy; after a restart of the joined servers all services came up again and the check stayed Healthy |
| Servers installed at the same time (`execution.mode = Parallel`, the default) | 15.2, 2026-11-22, clean servers. Full lab with DR: 23 minutes (41 one after the other), lab check Healthy, registrations one at a time. New domain with PVWA + CPM, PSM, PSMP and GPOs: 20 minutes through the window. New domain with gateway: one step stopped with an SSH time-out and was continued by name (see [PARALLEL.md](PARALLEL.md)). A lab with PTA and a provoked failure on one server: the run stopped as intended and `Resume-PASRun` finished it; Healthy |
| What needs the Vault comes last *(2.0.6)*: PVWA and PSMP register after their hardening; a CPM, PSM, gateway or PTA on another server starts as soon as PVWA has created its certificate; registrations in the order PVWA, CPM, rest; the PSM server trusts the PVWA certificate | 15.2, 2026-11-22, clean servers. Vault, PVWA, CPM on its own server, PSM, PSMP: 19 minutes, lab check Healthy; the CPM server started 68 seconds into the run; PSM registration ended without the earlier API gateway warning. Not run with this order: a new domain, the gateway, PTA, two of each component |
| Installation without hardening (`New-PASLabConfiguration -SkipHardening`, switch in the window) *(2.0.6)* | 15.2, 2026-11-22, clean servers, from the prompt: Full lab with DR in 21 minutes, lab check Healthy. Afterwards the Vault, the PVWA + CPM server and the PSM server accepted a normal remote PowerShell sign-in, RDP was allowed and the Windows services the hardening disables were untouched. Not run: a new domain (no GPOs then), the switch in the window against real servers |
| A server that fails stops only what depends on it; DR Vault next to the Primary; CPM and PSM servers get a hosts entry for the PVWA name; a damaged package is not chosen *(2.0.7)* | 15.2, 2026-11-23, clean servers in two networks (CPM, PSMP and gateway in another network than the Vault). Vault, DR Vault, PVWA, CPM, PSM, PSMP, PTA with three Linux servers failing at the start: Vault, DR Vault, PVWA and PSM finished in 17 minutes (Primary ready after 8.0, DR test safe replicated after 11.5); after the causes were corrected, `Resume-PASRun` installed PSMP and PTA; lab check Healthy with PVWA, CPM, PSM, PSMP and PTA. Second lab from clean servers: Vault, PVWA, CPM, PSM and an HTML5 Gateway on a server of its own (15.0 package; the gateway package inside this 15.2 bundle is damaged and was left out by the media scan); CPM verified without a manual hosts entry. Not run: a failing first PVWA or domain controller (unit tests only), the window against real servers |
| Whole lab in one run (`Install-PASLab`) | 15.0: 42 minutes; 15.2: 43 minutes; health check Healthy |
| Two instances of each component in one run (2 x PVWA, CPM, PSM, PSMP) | 15.2, once: 62 minutes, health check Healthy with 2/2 PVWA, 2/2 CPM, 4/4 PSM and PSMP |
| Media as single ZIPs or as the one full bundle ZIP | 15.0 single ZIPs, 15.2 bundle |
| VC++ runtimes for the Vault taken from the CPM, PVWA or PSM package | 15.2 bundle (media check); the installs so far had the runtime files in the folder |
| Run handling: follow, resume after a killed controller, retry one step, stop, second run blocked | 15.0 |
| `Test-PASPreflight`, `Test-PASHealth`, `Export-PASDiagnostics`, `Get-PASRunLog` | 15.0 and 15.2 |
| Server check names a wrong Linux root password, from the prompt and in the window *(2.0.4)* | Ubuntu 24.04, 2026-11-22: right, wrong and no password; nothing is changed on the server |
| Lab check without DNS record or hosts entry for the PVWA name *(2.0.4)* | 15.2, 2026-11-22: `Test-PASHealth` from the prompt and *Check the lab* in the window, Healthy |
| Retry of a CPM registration that failed after its Vault user was created *(2.0.4)* | 15.2, 2026-11-22: registration ended by force right after the user was created, and again during the platform import; `Resume-PASRun -RetryStep cpm:register` ended both times with one CPM user, the CPM connected and all platforms imported |
| "Who installs" values (`-InstallerName`, `-InstallerCompany`) *(2.0.4)* | PVWA 15.2: the installed product shows them as registered owner and company. CPM, PSM and the Vault use the same values but were not installed with them yet |

## 2. Experimental

Usable, but expect rough edges.

| What | State |
|---|---|
| Desktop window (`Start-PASeasyInstall`) | Rewritten in WPF on 2026-11-22 (no NativeHTMLKit, no other dependency): four steps, a page per installation, an Advanced switch. Tested without a desktop session, through UI Automation: six walks with the simulated installer (Full lab, Advanced, new domain with gateway and PTA, a failed step retried, the accounts dialog, a server that does not answer, a saved lab file with dropped media, Stop). With the real installer the window installed a lab with a new domain (15.2: forest, two joins, Vault, PVWA + CPM, PSM, PSMP, GPOs) on clean servers in 20 minutes, checked it and opened the installation again from the start page. In 2.0.6 the Media step takes folders and files by path or picker (drag and drop removed: a dropped folder froze the window on the owner's desktop), CPM can have its own server in every lab, and Advanced has the hardening switch; these were walked with the simulated installer only. **Seen on a real desktop by the owner only for 2.0.5; not systematically tested there:** visibility, icon, mouse and keyboard, the file dialogs and a drag from Explorer are untested. |
| PTA (component type `PTA`) *(2.0.4)* | Installs with the vendor's `pta_installer.sh` and is configured with the vendor's `ptaAutomaticConfiguration.py`. 2026-11-22, once from clean servers in one run: Vault and PVWA 15.2 and PTA 15.2.2 on Rocky Linux 9.9 (8 GB, 4 cores) in 20 minutes; all PTA services run, the lab check lists PTA as connected (`PTAAppUser`, 15.2.2). Not done: Vault syslog forwarding to PTA, so PTA gets no Vault audit yet; the window with PTA was walked with the simulated installation only |
| HTML5 Gateway (component type `HTML5GW`) *(2.0.4)* | Installs with `html5_console.sh` from the 15.0 package on Ubuntu 24.04 (Docker), on the PSMP server, 4 GB. 2026-11-22, one lab from clean servers (15.2 Vault, PVWA, CPM, PSM, PSMP; gateway 15.0): the gateway step took about two minutes, its health page answers 200, PVWA has the gateway entry for the PSM server, lab check Healthy. The controller process of that run crashed once during the Vault upload (Windows PowerShell remoting exception on the shared controller VM); `Resume-PASRun` continued it without any other step by hand. Not done: a PSM session opened in a browser through the gateway |

## 3. Next (roadmap after 2.0.0)

The ordered work list with the steps of each item is in [NEXT.md](NEXT.md).

Deferred on purpose so that 2.0.0 could ship as a lab installer that works. In the order they are planned.

### 3.1 Lab-only scope

PASeasyInstall is designed only for **disposable CyberArk labs**. Production deployment support and
Secure/production qualification are **not planned**. The existing Secure CLI settings remain legacy
configuration surface, not an advertised supported deployment mode. Stabilization and repeatable
end-to-end lab validation take priority. See [LAB-STABILIZATION.md](LAB-STABILIZATION.md).

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

Installs and connects (see the table in section 2). What is left:

- **Vault syslog forwarding to PTA.** PTA analyses the Vault audit, which the Vault sends by syslog. That needs
  `dbparm.ini` on the Vault (`AllowNonStandardFWAddresses` for the PTA address and a `[SYSLOG]` section with the
  `PTA.xsl` translator) and a Vault restart. Not built; without it PTA is connected but sees no Vault events.
- **Root password.** The PTA installer application signs in as root of its own server, so the installation needs
  the root password of the PTA server (not only an SSH key), and sets SELinux to permissive for that one call.
- **firewalld.** The vendor's configuration tool installs and enables firewalld with only its port forwarding;
  the recipe then opens the ports PTA listens on (80, 443, 8080, 8443, 514, 11514).
- **Trust in a lab:** PTA trusts the lab PVWA certificate (Java trust stores); the PVWA server trusts the
  certificate PTA presents (trusted on first use, listed as a lab deviation) and gets a hosts entry for the PTA
  name. The Secure profile has no way for this yet.
- **Vault time zone.** PTA wants the time zone of the Vault server as a tz database name. Default UTC with a
  warning in the plan; `VaultTimezone` of the PTA instance or the field in the window's Advanced view sets it.
- **Only in a lab that also installs a PVWA**, and the media folder needs a PSMP package: the CyberArk package
  signing key the PTA installer checks comes from there.
- **Memory:** about 3.2 GB of 8 GB in use after the installation, with the vendor's default heap sizes. Not
  watched under load. Rocky Linux 9 only; RHEL 8 was not run. Ubuntu is not supported by the vendor.
- The old PTA branches in `Recipes/LinuxComponent/Task.sh` and `Verify.sh` are unused now and can be removed.

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
- **Desktop:** the native folder and file pickers, the smallest window size and a remote desktop session were not tried
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
