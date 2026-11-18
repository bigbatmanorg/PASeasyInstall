# PASeasyInstall — modular design (UI-first)

**Status:** Working-source skeleton, **not** native Windows or vendor acceptance evidence. The original durable engine and source recipes were redistributed; automation and GUI have **not yet been qualified on the refactored source**.

## Operator contract

- The default UI always creates a **new** Primary Vault.
- A single optional selection adds a **new DR Vault to that same Primary installation**.
- **A DR install against an existing Vault is deliberately unsupported** and rejected by both orchestrator and Core validation.
- Media, license and recovery key file paths are operator supplied. Credentials are requested separately via native Windows credential dialogs; no passwords go into project JSON or UI state.
- Advanced mode allows a component (PVWA, CPM, PSM, PSMP, PTA) to be installed against a pre-existing Vault. This path does not add DR.
- The UI reads **structured JSONL events** and projects their timestamps, source, stage, event, status and message into HTML-escaped event cards. The progress dashboard does not invent completion percentages.
- UI imports do not launch a window or server. Run `Start-PASeasyInstall.ps1` to open a native window; explicit Install invokes the **detached** legacy controller.

## Modules

```text
Modules/
  PASeasyInstall.Core/         durable execution, remoting, staging, security, logs
  PASeasyInstall.Vault/        new Primary configuration + Vault workflows
  PASeasyInstall.DR/           new Primary+DR combined configuration + DR stage contract
  PASeasyInstall.PVWA/         stand-alone PVWA config + component-specific TLS recipe
  PASeasyInstall.CPM/          stand-alone CPM config + component-specific TLS recipe
  PASeasyInstall.PSM/          stand-alone PSM config + component-specific RDS recipe
  PASeasyInstall.PSMP/         stand-alone Linux gateway configuration
  PASeasyInstall.PTA/          stand-alone Linux PTA configuration
  PASeasyInstall.AD/           optional AD and joins
  PASeasyInstall.Orchestrator/ optional composition, topologies, plan/save/start/snapshot
  PASeasyInstall.UI/           NativeHTMLKit.UI desktop + structured-event presentation
```

**Dependencies:** Component modules import Core using the manifest path beside them. Core does not import the UI. Orchestrator imports Core; it imports only a component module when needed. UI imports Orchestrator, plus NativeHTMLKit.UI at runtime. No HTTP server, database, generic plugin loader or JS runtime.

**Packaging:** Modules are independently importable but currently distributed as a *set* because Core owns shared immutable source fingerprinting and relative, reviewed recipe resolution. Use `Tools/Build-ModularPackages.ps1` to stage normal module directories and install the desired component plus Core side-by-side. This is not a Gallery release.

## Public commands

| Module | Exports |
| --- | --- |
| Core | Original deployment and recovery API; `Get-PASDeploymentSnapshot`, `Get-PASDeploymentEvents` |
| Vault | `New-PASVaultConfiguration`, `Get-PASVaultStages`, `Invoke-PASVault` |
| DR | `Add-PASDRConfiguration`, `Get-PASDRStages`, `Invoke-PASVaultPair` |
| PVWA/CPM/PSM/PSMP/PTA/AD | `New-PAS<name>Configuration`, `Get-PAS<name>Stages`, `Invoke-PAS<name>` |
| Orchestrator | `New-PASFreshEnvironment`, `New-PASExistingVaultComponent`, `Test-PASEnvironment`, `Get-PASEnvironmentPlan`, `Save-PASEnvironment`, `Start-PASEnvironment`, `Get-PASEnvironmentEvents`, `Get-PASEnvironmentSnapshot`, `Get-PASStageCatalog` |
| UI | `Start-PASeasyUI` |

Public component `Invoke-*` commands currently support **`-Stage All`** (existing durable deployment) and **`-Stage LocalPreflight`** (read-only local checks). The stage catalog is discoverable, but running arbitrary remote stages safely is **not implemented**. Do not claim it is implemented; it needs a dedicated stage target-resolution and recovery design.

## Safety boundaries preserved

1. DPAPI credential envelope, remote attempts, journals, reboot handling, source hash pinning and cross-process Vault/account serialization remain in Core.
2. The Core config validator forbids unsupported DR standalone/attach-to-existing deployments; the DR module also checks the same condition.
3. File paths for executable recipes are resolved to a fixed, reviewed list of sibling module-owned directories; never accept arbitrary includes.
4. Only the current selected component modules (and Core) participate in the source fingerprint. The GUI CSS does not invalidate in-flight controller recovery.
5. A closed UI must not terminate a detached controller. The operator must reopen a run through Core/CLI if the GUI currently cannot reattach.
6. A successful installer journal **does not mean** a verified functional CyberArk topology. Operational verification remains separate acceptance work.

## Known gaps (do not hide)

- Windows PowerShell 5.1 parser/import and GUI host end-to-end test pending; the container cannot execute them.
- Fresh Primary/DR workflow needs a complete media/licensing/key-path smoke test and a native DR standby acceptance run on the refactored source.
- UI supports the fresh-install happy path. Existing configuration reopen and reattach to old runs are incomplete; existing component deployment is an advanced skeleton, especially Linux credential handling.
- Stage-specific remote execution is **not** implemented; stages are listed for inspection.
- Some older PowerShell tests embed one-module assumptions (module names, absolute paths and packaging). They are retained as migration evidence but not all are expected to pass unchanged.
- The previous monolithic packaging scripts and historical qualification scripts remain reference material; prefer `Build-ModularPackages.ps1` for this layout.
- PVWA/CPM/PSM Windows and Linux PSMP/PTA recipes retain the existing shared dispatchers in Core; component-specific file pieces and public interfaces are separated. Complete ownership of dispatch logic can follow after new contract tests pass.
- Configuration currently checks some vendor media only at deployment time, with installation prerequisites checked by recipe stages. The UI does not make vendor-compatibility promises.

## Minimum acceptance gate

On **Windows PowerShell 5.1**:

```powershell
.\Tools\Check-Modular.ps1
.\Tools\Check-Module.ps1
Invoke-Pester -Path .\Tests\ModularArchitecture.Tests.ps1 -Output Detailed
powershell.exe -NoProfile -File .\Start-PASeasyInstall.ps1
```

Test UI interactions: Primary-only, Primary+DR show/hide, Advanced collapsed, config review, save, credentials cancelled, invalid media safely refused, structured event encoding, live status under detached execution, close/reopen safety. Then run the **whole** Pester/contract suite, classify path/mocking failures from the refactor, and qualify using disposable Windows VM snapshots. **Do not claim passing test gates until run on the target.**
