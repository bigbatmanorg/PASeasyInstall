# PASeasyInstall — modular UI-first refactor

**PowerShell 5.1 CyberArk installation toolkit with an optional native desktop.** No PowerShell HTTP server, browser, JS or external database. **This is an implementation skeleton pending native Windows acceptance and vendor requalification.**

## Start the desktop

On a **Windows PowerShell 5.1** controller with `NativeHTMLKit.UI` installed:

```powershell
Install-Module NativeHTMLKit.UI -Scope CurrentUser  # if needed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-PASeasyInstall.ps1
# Same window against a dummy backend that never contacts a server (UI work, demos):
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-PASeasyInstall.ps1 -Backend Mock
```

Run it in a fresh `powershell.exe` process (as above). `-Theme v1` selects the light theme; `v2` (dark, compact) is the default.
The desktop drives the **real installer** by default (the Orchestrator in this folder's `Modules`). Nothing is
sent to any server until **Install** on step 6.

1. **Project & media** — environment name; the project file path (passwords are never saved). Drop ZIPs/folders
   or use Add files…/Add folder…: components, license and `recpub.key` are recognised by name, also inside the
   CyberArk bundle ZIP (read without extracting). The recommended installer per component is used; a dropdown
   appears only where there is a real choice (e.g. PSMP builds per Linux distribution). A plain file wins over the
   same installer inside the bundle. VC++ runtimes and the Vault Ansible role in the media folder are picked up by the
   backend automatically.
2. **What to install** — Primary, Primary + DR (DR only together with a new Primary), or Existing Vault; how many
   servers of each component (up to 4; PTA 1); the PSMP license agreement when PSMP is selected; and the order:
   **one server at a time** or **servers in parallel**.
3. **Servers** — controller address (detected; it is the only address the hardened Vault accepts for WinRM/RDP),
   Vault address(es), a hostname and address per component server. Same address = one server.
4. **Credentials** — default Windows/Linux account, optional per-server accounts; **Lab mode** (one universal
   password, prefilled, clearly insecure) or individual passwords plus Vault Administrator / Master / DR user.
5. **Review plan** — every server, installer and dependency, the security deviations, and issues to fix.
6. **Install** — readiness, then live progress per server from the controller's event journals (no estimated
   percentages).

What happens on **Install** (`Start-PASEnvironment`, also usable from scripts):

* The selection becomes one configuration (`New-PASDeploymentConfiguration`). **Lab mode** selects the `Lab`
  security profile with the audited deviations a template-built lab needs (self-signed WinRM certificates, RDP to
  the Vault from the controller, PVWA self-signed certificate pinned by CPM); individual passwords select `Secure`.
* A detached deployment controller runs it as a set of ordinary engine runs: Vault (+DR) first, then one run per
  component instance — **one at a time** in plan order, or **in parallel** with one run per server at a time.
  Registration and other authenticated Vault work stay serialised by the engine's Vault gate. CPM starts after the
  PVWA whose certificate it pins; that certificate is read from the PVWA server over the authenticated management
  channel. Closing the window does not stop the installation.
* Windows: a plain account name is used as the target's local account (`.\Administrator`).
* Linux (PSMP/PTA): the controller's per-environment SSH key (`%LOCALAPPDATA%\PASeasyInstall\ssh\<environment>`)
  is authorised on first use with the server password (sent once through `SSH_ASKPASS`, never stored). Lab trusts
  the server's host key on first use (logged as a deviation); Secure requires it in the known_hosts file first. If
  the server refuses password logins, the run stops with the public key to authorise.
* Each run's journal stays under `%LOCALAPPDATA%\PASeasyInstall` (`Runs\<runId>`, `fleets\<deploymentId>`).

Screenshots: `Docs/screenshots/integrated/` (real backend, plan only, today's lab media and addresses;
`6-install-progress-mock-parallel.png` uses the Mock backend). Dev-only `PASUI_DEV_*` switches and
`Docs/screenshots/capture.sh` are described in `Modules/PASeasyInstall.UI/App.ps1`.

Not in the desktop yet: reopening a saved project (the file is written for review and CLI use), resume/reconcile of a
failed run (use `Resume-PASeasyDeployment` on the failed unit's engine run), AD forest/join, PTA certificate options.

## PowerShell execution policy (unsigned module)

PASeasyInstall is not Authenticode-signed. How to run it under each execution policy:

- **Default Windows Server policy (`RemoteSigned`)**: nothing to do. Files installed with `Install-Module`
  carry no internet zone mark, so they run as they are.
- **Copied as a ZIP instead of `Install-Module`**: unblock the files once:
  `Get-ChildItem -Path <folder> -Recurse | Unblock-File`
- **`AllSigned` or `Restricted` policy**: allow unsigned code for the current PowerShell window only. This changes
  nothing machine-wide and ends when the window closes:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Start-PASeasyInstall
```

  Or start it in one line: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command Start-PASeasyInstall`
- **Policy enforced by Group Policy** (`Get-ExecutionPolicy -List` shows `MachinePolicy` or `UserPolicy`):
  PowerShell does not let the commands above override it. Ask your administrator for an exception for the
  controller, or run from a controller without that policy.

The background processes PASeasyInstall starts on the controller, and the scripts it runs on target servers,
start with an explicit `-ExecutionPolicy Bypass`, so they work on hosts whose local policy is `AllSigned`. A policy
enforced by Group Policy on a target still applies.

## Source organization

```text
Modules/PASeasyInstall.Core/          shared durable runner, source assets, events, recovery
Modules/PASeasyInstall.Vault/         new Primary Vault installer
Modules/PASeasyInstall.DR/            add new DR only to the same fresh Primary deployment
Modules/PASeasyInstall.PVWA/          PVWA module
Modules/PASeasyInstall.CPM/           CPM module
Modules/PASeasyInstall.PSM/           PSM module
Modules/PASeasyInstall.PSMP/          Linux gateway module
Modules/PASeasyInstall.PTA/           threat analytics module
Modules/PASeasyInstall.AD/            AD setup and joins
Modules/PASeasyInstall.Orchestrator/  composition (media inventory, multi-instance, sequential/parallel runs), plans
Modules/PASeasyInstall.UI/            optional NativeHTMLKit desktop (App, Presentation, Theme.v1/v2, Backend contract + Mock)
```

All component manifests can be imported separately with Core; no component requires UI. Deployment recipes use the old security/staging/recovery engine, rather than duplicate it. The DR module coordinates the paired Primary/DR recipe implementation.

## Example: Primary only or paired DR, without GUI

```powershell
Import-Module .\Modules\PASeasyInstall.Orchestrator\PASeasyInstall.Orchestrator.psd1
$c = New-PASFreshEnvironment -Environment Lab01 `
    -PrimaryIP 192.0.2.11 -ControllerIP 192.0.2.10 -MediaRoot C:\Media `
    -LicenseFile C:\Media\License.xml -PublicRecoveryKey C:\Media\Keys\recpub.key

# Alternative paired install, starting with a *fresh* Primary:
$c = New-PASFreshEnvironment -Environment Lab02 `
    -PrimaryIP 192.0.2.11 -DRIP 192.0.2.12 -WithDR `
    -ControllerIP 192.0.2.10 -MediaRoot C:\Media

Test-PASEnvironment -Configuration $c
Get-PASEnvironmentPlan -Configuration $c
Save-PASEnvironment -Configuration $c -Path .\vault-pair.json
# For actual deployment, provide target PSCredentials and Vault role SecureStrings in memory:
# Start-PASEnvironment -Config .\vault-pair.json -CredentialMap $creds -SecretMap $secrets
```

## Example: add PSM to an existing Vault (advanced)

```powershell
Import-Module .\Modules\PASeasyInstall.PSM\PASeasyInstall.PSM.psd1
$psm = New-PASPSMConfiguration -Environment PSMExpansion `
  -VaultAddress 192.0.2.11 -TargetAddress 192.0.2.21 `
  -MediaZip C:\Media\PSM.zip
Get-PASPSMStages
Invoke-PASPSM -Configuration $psm -PlanOnly
# Invoke-PASPSM -Configuration $psm -CredentialMap $creds -SecretMap $secrets
```

Remote stage-specific execution is **not yet enabled**. `Invoke-PASPSM -Stage LocalPreflight` performs read-only configuration/media checks. `-Stage All` uses the existing durable workflow; use `Get-PASPSMStages` to inspect stage names. Partial stage execution needs additional guarded engine support.

## Build and verify

```powershell
.\Tools\Check-Modular.ps1
Invoke-Pester -Path .\Tests\ModularArchitecture.Tests.ps1
.\Tools\Build-ModularPackages.ps1 -Output C:\Temp\PASeasyInstallPackages
```

Tests and vendor qualification must be rerun against this refactor. The Windows/NativeHTMLKit runtime was **not** available in the build environment; this archive is **not certified as a successful Windows GUI smoke test**. Existing Windows/Linux lab evidence belongs to earlier source digests and cannot be transferred unconditionally. Review [architecture, gaps and acceptance](Docs/MODULAR_ARCHITECTURE.md).

Historical design and qualification documents are still included in `Docs/` and `Agent/` for context but may refer to the old monolithic file layout. The previous package builder targets that obsolete layout; use `Tools/Build-ModularPackages.ps1` instead. Do not run old archival qualification scripts against live targets without a separate review.
