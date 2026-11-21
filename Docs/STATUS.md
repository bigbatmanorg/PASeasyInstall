# PASeasyInstall 2.0: state of things

One page that says what can be used now, what is experimental and what comes later.
Last updated 2026-11-21 (branch `refactor/simple-core`).

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
| Run handling: follow, resume after a killed controller, retry one step, stop, second run blocked | 15.0 |
| `Test-PASPreflight`, `Test-PASHealth`, `Export-PASDiagnostics`, `Get-PASRunLog` | 15.0 and 15.2 |

## 2. Experimental

Usable, but expect rough edges. The wizard should label these "experimental".

| What | State |
|---|---|
| Desktop window (`Start-PASeasyInstall`) | Rewritten on 2026-11-21 directly on the NativeHTMLKit SDK: four steps, a page per installation, an Advanced switch. Tested headless with the simulated installation; not yet seen on a real desktop and never run against real servers. |
| PTA | Not in the module yet. Proven by hand: the 15.2 installer installs on Rocky Linux 9.9 with 8 GB RAM and 4 cores (the documented 16 GB / 8 cores are not enforced). Connecting it to the Vault and PVWA is not done: the installer's REST sign-in only works with SELinux in permissive mode, and the configuration call that worked on 15.0 returns 404 on 15.2. |
| HTML5 Gateway | Not in the module yet. Investigated only: container or RPM install, 2 cores / 4 GB, can share a server with PSMP in theory. Only the 15.0 package can be tested: the 15.2 package in the media bundle is truncated. |

## 3. Later (roadmap)

Not started, or deliberately postponed.

- **Domain-joined components.** The forest can be created, but joining PVWA/CPM/PSM to it is not tested and
  `New-PASLabConfiguration` has no option for it.
- **Secure profile.** WinRM with trusted certificates, no lab deviations. Never run. Needs a certificate
  authority in the test lab.
- **PTA and HTML5 Gateway as installable components** of the module and the wizard (see Experimental).
- **PSMP on RHEL 8, SLES and Ubuntu 22.** The media has the packages; only Ubuntu 24.04 and Rocky 9 were tested.
- **Three or four instances of a component.** Two of each were tested. More CPMs need a licence with more CPM users.
- **"Who installs" values.** The vendor installers take a user name and a company name; they stay at the vendor
  defaults ("Windows User", "My Company"). Install paths can already be changed through component options.
- **Retry of a CPM registration that failed late.** The vendor tool has by then created the CPM's Vault user and
  a retry creates another one (`PasswordManager1`), which can hit the licence limit of CPM users. Until fixed:
  delete the leftover Vault user before retrying, or install that CPM again on a clean server.
- **Cluster and distributed Vaults.**

## Known limitations of what works now

- `Test-PASHealth` needs the PVWA server name to resolve on the controller (DNS or hosts file).
- The licence decides how many instances can register. The 15.2 NFR licence allows 2 CPM users.
- The PSM service restart after the last reboot was written after one failure and has not been triggered since.
- With several PVWAs, `Test-PASHealth` asks the first one of the configuration.
- A step that was reconciled after a resume keeps the earlier error text in its "Succeeded" message.

More technical debt is listed in [DESIGN.md](DESIGN.md).
