> **Design notes.** This is internal design documentation, kept for contributors; parts of it describe plans
> and history rather than the current release. For user documentation see
> <https://bigbatmanorg.github.io/PASeasyInstall/>. PASeasyInstall is intended for building CyberArk PAM
> **labs**; production use is at your own risk. Not affiliated with or endorsed by CyberArk.

# 09 — Source Review and Evidence Traceability

Inspected **11 uploaded ZIPs** (not a complete checkout of every upstream repository). Vendor roles and earlier attempts are a reference, not proof of complete support. No live target was contacted and no vendor installer was executed as part of this design review.

## Files and findings

| Uploaded archive | Concrete inspected paths | Findings relevant to architecture |
|---|---|---|
| `PASeasyInstall-main.zip` | `Docs/DESIGN.md`, `Docs/LOCAL_VALIDATION_REPORT.md`, `PASeasyInstall/{Runs,Profiles,Secrets,Media,Observe}.ps1`, `Controllers/Invoke-Deployment.ps1`, `Proven/PSSteps/Private/{Engine,Detached,Adapters,Common}.ps1`, `Proven/Vault/Workflows/*.psd1` | Working two-mode Vault/DR scaffold, detached task runner, journaling, workarounds for GUI job object, successful real-lab runs; target-specific workflow/API structure needs replacement |
| `nativehtmlkit-powershell-main.zip` | `README.md`, `docs/guides/{background-work,packaging-and-distribution,security}.md`, `examples/{06-log-tail,15-data-table,18-background-jobs}.ps1` | Native PowerShell SDK 0.1.2 works on Windows PS5.1 and PS7; UI work belongs outside deployment callbacks |
| `nativehtmlkit_ui-main.zip` | `README.md`, `docs/powershell/{README,getting-started}.md`, `docs/LIMITATIONS.md`, `powershell/NativeHTMLKit.UI/` | UI library 0.1.1 supports state, form/layout/components; has known compact layout workaround and incomplete advanced widgets |
| `Vault Ansible Role-Rls-v15.0(2).zip` | `tasks/{main,vault_install,vault_postinstall,vault_hardening,vaultdr_install}.yml`, `defaults/main.yml` | Rich installation automation; `Users FullControl` ACL in `vault_postinstall.yml`; AWS/Azure-oriented defaults; don't assume safe generic template |
| `PVWA Ansible Role-Rls-v15.0(2).zip` | `tasks/{pvwa_prerequisites,pvwa_install,pvwa_registration,pvwa_hardening}.yml`, `defaults/main.yml` | IIS/install/registration/hardening phases; selected `validate_certs: false` registration paths |
| `CPM Ansible Role-Rls-v15.0(2).zip` | `tasks/{cpm_prerequisites,cpm_install,cpm_registration,cpm_hardening}.yml` | Installer/registration flow; `CPMRegisterComponentConfig.xml` modifies `validatePVWASecureConnect` to false |
| `PSM Ansible Role-Rls-v15.0(2).zip` | `tasks/{psm_prerequisites,psm_install,psm_postinstall,psm_hardening}.yml` | Auto-logon password exposure in `Winlogon\DefaultPassword`, RDS role/hardening/reboot issues; requires careful design rather than direct port |
| `PSMP Ansible Role-Rls-v15.0(2).zip` | `tasks/{main,psmp_installation,psmp_postinstall}.yml`, `files/{CARKpsmp-install,register}.sh` | RHEL 8.6 target, `Hardening=No`, broad install directory cleanup, default postinstall copies registration script but does not show it being executed |
| `PTA-Ansible-Role-Rls-v15.0.0(2).zip` | nested `pta_ansible.zip` → `tasks/{main,pta_installation,pta_configurations}.yml` | Recursive duplicate role contents, EL8/EL9, OS-wide dnf updates, TLS skip for installer API, SELinux disable/re-enable around config/reboots, significant recoverability requirements |
| `cyberark-admincenter-main.zip` | `cyberark_paths.csv`, `web-gui/api/cyberark_client.py` | 267 path entries, 119 log entries, no PTA entries; health/API concepts; no reason to ship Django/Python |
| `psPASadmin-master.zip` | `psPASadmin/Private/{Health,Session}.ps1`, `psPASadmin/Private/Controllers.MainWindow.ps1` | `psPAS`-based `Get-PASComponentSummary` / `Get-PASComponentDetail` health capabilities; do not ship WPF/psPAS module merely for a few diagnostics |

## Precisely what was qualified before

The supplied `Docs/LOCAL_VALIDATION_REPORT.md` is dated **2026-11-14** and reports a live Windows Server 2022 / CyberArk Vault **15.0.0.76** lab test:

- Standalone primary: **22/22 steps**, independent verification, hardening and PACLI logon/logoff.
- Primary with DR: **49/49 steps**, DR replication and test Safe checks.
- GUI acceptance: **24/24 native Windows checks** using the then-current UI4ME interface (not NativeHTMLKit).
- Fault injection: killed controller and reconciled remote installer without duplicate launch.
- Documented limitations: Windows Update hardening race, protected management exception, DPAPI/NTLM identity issues for SSH logons, vendor PACLI password command-line exposure, two-target-only scope.

These reported results are **behavioral evidence to reproduce**, not tests performed here and not evidence the new application/code is already qualified. The old native UI is a different toolkit and must be completely retested under NativeHTMLKit.

## Source coverage gaps

- No separate **Active Directory Ansible role** appears among the 11 uploads. AD installation design instead uses Microsoft Windows Server ADDSDeployment native cmdlets and needs new test evidence.
- Supplied archives do **not** contain complete CyberArk licensed installation media for all seven components or a general matrix of production-supported OS/version combinations. Preflight compatibility must be derived from the actual supplied vendor media/documentation and verified target OS builds.
- PTA logs and full operational verification are absent from the admin-center path catalog; these must be qualified on a real target.
- A limited sample of vendor role code may assume AWS/Azure and should not be adopted as local deployment defaults.
- Source files may have vendor and third-party license constraints. Do not copy binaries, installer licenses or proprietary source into Gallery without a license review.

## External references consulted (context, not a substitute for target qualification)

- CyberArk PAS Orchestrator README: https://github.com/cyberark/pas-orchestrator/blob/master/README.md — documents single-component-per-server limitation, idempotence caveat after installation failures.
- CyberArk article on same-user sessions: https://community.cyberark.com/s/article/The-session-has-been-stopped-because-the-same-user-connected-elsewhere — explains same-user invalidation in certain login scenarios.
- Microsoft module manifests: https://learn.microsoft.com/en-us/powershell/scripting/developer/module/how-to-write-a-powershell-module-manifest
- PowerShell Gallery publishing: https://learn.microsoft.com/en-us/powershell/gallery/how-to/publishing-packages/publishing-a-package
- Microsoft AD forest prerequisites: https://learn.microsoft.com/en-us/powershell/module/addsdeployment/test-addsforestinstallation?view=windowsserver2022-ps
- Microsoft AD forest installation: https://learn.microsoft.com/en-us/powershell/module/addsdeployment/install-addsforest?view=windowsserver2022-ps
- Microsoft Task Scheduler principal: https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtaskprincipal?view=windowsserver2025-ps

## Source integration policy

Copy/adapt only **behaviorally necessary** source after unit/characterization tests. Keep original copyright/license notices in adapted files as required. Remove all standalone engine namespaces, module manifests and imported upstream build scripts. `PASeasyInstall` contains the complete source of its runner and owns its long-term maintenance. Future improvements are made in this product repo; there is no runtime/source-sync dependency.
