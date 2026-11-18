# Native GUI and deployment diagnostics

The optional GUI calls the module's public PowerShell commands. It does not run vendor installers directly. Importing or using the CLI does not require NativeHTMLKit; `Start-PASeasyUI` loads the public SDK/UI APIs when invoked.

```powershell
Import-Module .\PASeasyInstall\PASeasyInstall.psd1 -Force
# Run once, elevated, on the machine that will run both GUI and CLI:
Initialize-PASeasyController
Install-Module NativeHTMLKit.UI -Scope CurrentUser
Start-PASeasyUI -Config .\deployment.json
```

The observed Windows development versions are NativeHTMLKit SDK0.1.2 and NativeHTMLKit.UI0.1.1. Native credential prompts use the public Windows Credential UI with persistence disabled. No password field is bound to native markup. Startup may execute twice through the SDK launcher; file writes and deployment launches occur only in explicit callbacks after handoff.

## Configuration and credentials

Load an existing configuration or explicitly replace the editor with a template: `Vault`, `VaultDR`, `FullLab`, `ADOnly`, `ExistingVault`, or `DomainJoin`. Loading and saving preserves advanced options, distinct instance media paths, host identity files and scoped overrides. Edit unrepresented fields in JSON; reopen the UI after adding hosts to expose their address controls.

The editor includes host addresses, component selection, installation media, domain mode and security profile. Vault and DR remain workgroup members. The join-only template preserves an explicit Windows host list and DNS configuration without adding PAM components.

Supply each Windows host credential through **Set host credentials**. The editable reference field also supports a configured installer identity such as `PSMDomainInstaller`. Supply role passwords separately through **Set role password**. Its username is a role label; the configured Vault username is used for authentication. Credential values remain in the PowerShell callback cache, outside rendered controls. Start, resume, authenticated health, explicit clear and application close clear that cache.

The shared shortcut is available only with an explicitly saved Lab profile. It fills missing inputs; it is not a production default. TLS certificate, public CA file/pin and advanced component options belong in the loaded configuration. Secure PVWA requires an actual trusted target certificate; explicit Lab certificate creation and pinned leaf trust are audited deviations.

## Installation and recovery

**Validate and preview plan** calls the same `Test-PASeasyConfig` and `Get-PASeasyPlan` commands as CLI. **Start installation** submits credentials to `Start-PASeasyDeployment`, which starts an independent controller. Closing the GUI does not terminate that controller or detached target work.

**Refresh runs and logs** lists runs and reads the selected run through `Get-PASeasyRun` and bounded `Get-PASeasyLog`. This is manual refresh of observed state, not simulated progress.

To resume:

1. Reopen the same immutable module package and load the original unchanged configuration.
2. Enter its run ID and provide fresh credentials.
3. Select **Resume selected run**.

The UI requires a resumable state and matching configuration digest, then calls `Resume-PASeasyDeployment`. It never requests blind unknown retry. The public engine reconciles attempt IDs and target evidence before proceeding. Source/package mismatches remain an error; changing the UI package does not authorize replaying an old installer.

GUI runs use the current user's default DataRoot. Runs created with another user's profile or a custom CLI DataRoot require the corresponding CLI `-DataRoot` workflow. There is no GUI force-unlock or retry-all action.

## Service and authenticated health

**Probe component services** calls `Get-PASeasyComponentStatus` using only host credentials. It opens no Vault session and reports functional validation as `NotTested`. Arbitrary remote Detail text is not rendered.

**Validate authenticated PVWA and CPM status** calls `Test-PASeasyDeployment` with the cached Vault Administrator role password. Configure the PVWA URL or enter an explicit HTTPS API URI. The controlled CPM account ID is optional and enables read-only metadata; the action does not retrieve or change its password.

PVWA authenticated health requires trusted TLS, logon, an authenticated identity query and confirmed logoff. CPM status remains partial: a successful account status does not prove a new password operation or target login. Other component functional tests remain `NotTested` in this command.

All authenticated calls use the same controller-wide canonical Vault gates as installation. An uncertain session preserves its durable claim and health run ID. The UI retains that identity and configuration scope, including after another admission failure; it does not silently start a new session or discard an old claim. External session reconciliation is required before retrying an unresolved claim.

Coordination is local to one controller machine. Concurrent CLI and GUI qualification must run on that same machine; it does not provide a distributed lock between separate controllers. Operators and lab agents must serialize authenticated work across machines.

## Logs and qualification limits

`Get-PASeasyLog -Config ... -Component ... -Name ...` exposes catalog-selected remote logs through the CLI; the GUI currently displays bounded deployment events. Vendor logs may contain sensitive values and should not be pasted into diagnostics or exported without review.

The GUI does not currently expose pause-after-step, arbitrary vendor log selection, report export or controlled account mutation. Network callbacks can wait for public remoting/health timeouts; full responsiveness under those waits is not yet qualified. Desktop scaling and keyboard checks must be recorded separately from parser or mocked callback tests.

Observed parser, native prompt/cache, DPAPI handoff, public callback and live diagnostic evidence is in `Docs/Verification/windows-components.md`. A complete clean GUI/co-location install and interruption/resume qualification is still pending; unit tests do not qualify those scenarios.
