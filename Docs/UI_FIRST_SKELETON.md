> **Design notes.** This is internal design documentation, kept for contributors; parts of it describe plans
> and history rather than the current release. For user documentation see
> <https://bigbatmanorg.github.io/PASeasyInstall/>. PASeasyInstall is intended for building CyberArk PAM
> **labs**; production use is at your own risk. Not affiliated with or endorsed by CyberArk.

# UI-first skeleton — 2026-11-18

## Intent

Make PASeasyInstall an interactive **native desktop application launched from the command line**. The operator should not have to hand-author JSON for ordinary single-instance installations. The GUI prepares the existing PowerShell v2 configuration, shows a selection, collects secrets with native Windows dialogs, and calls the existing deployment/recovery API only on explicit request.

This is a UI/product-flow pass. **It is not a new CyberArk installer implementation or a claim of complete vendor qualification.** No browser, GraphQL endpoint, Node application, HTTP service, database, or parallel scheduler has been added. The term “GraphQL interface” was treated as “graphical interface,” based on the requested user workflow.

## Launch

From the repository root on a Windows machine with NativeHTMLKit.UI installed:

```powershell
powershell.exe -NoProfile -File .\Start-PASeasyInstall.ps1
powershell.exe -NoProfile -File .\Start-PASeasyInstall.ps1 -Config 'C:\PAM\my-lab.json'
```

Or use the existing exported entrypoint:

```powershell
Import-Module .\PASeasyInstall\PASeasyInstall.psd1
Start-PASeasyUI
```

The launcher never creates a configuration or deploys anything on startup. A nonexisting configuration path opens a **new Primary Vault draft in memory**, with **empty** target address fields. An existing file is opened through the public validator. `Start-PASeasyUI` does not run on `Import-Module`.

## Six-page native wizard (no browser or server)

The window has a compact row of native step-navigation buttons. Switching steps keeps form state, and all choices are explicit. Inactive components have their host/media fields collapsed (but input state preserved) using the documented `Add-NHKUiWhen` primitive. Server details for an active component appear in a responsive grid; Vault-vs-existing-Vault and AD-dependent fields also toggle. All six steps are built from the supported NativeHTMLKit.UI PowerShell 0.1.1 public API.

## UI sections and actions

1. **New / open** — choose a template (`Vault`, `VaultDR`, `FullLab`, `ExistingVault`, `ADOnly`, or `DomainJoin`) or open a JSON configuration. New presets are prepared in memory and cannot overwrite an existing file without opening it.
2. **Environment** — name, security policy, media root, Vault/controller addresses, AD mode, domain, join host and DNS information. Domain operations are opt-in.
3. **Components and targets** — choose deploy or skip for Vault, DR Vault, PVWA, CPM, PSM, PSMP, PTA; edit the host ID, address, remote account and (where applicable) media path. Shared host ID means co-location. Conflicting addresses/users for one host ID are rejected.
4. **Review / save** — preview uses `Test-PASeasyConfig` and `Get-PASeasyPlan` in memory; it needs no vendor media and makes no target changes. Save writes the existing JSON v2 schema atomically. The review digest tracks exactly what the user reviewed.
5. **Credentials / deployment** — one action prompts for the Windows host credentials, PSM installer reference (when required), and role passwords used by the selected components. Passwords are held in memory, never stored in the JSON or bound to markup. There are manual override buttons and an explicit Lab-only shared password shortcut. A separate one-time elevated controller initialization action is available. Deployment is allowed only if the saved JSON and current form match the reviewed preview and `-CheckMedia` succeeds. The real controller is detached.
6. **Runs / diagnostics** — actual run history, bounded real controller events, guarded resume, read-only service probes, and existing authenticated PVWA/CPM health integration.

## Architecture boundaries

```text
Start-PASeasyInstall.ps1
       |
NativeHTMLKit.UI (optional; loaded at UI start)
       |
UI/Start.ps1
UI/Configuration.ps1 and UI/Credentials.ps1 (adapter only)
       |
PASeasyInstall public PowerShell commands
       |
Existing v2 planning, durable run controller, recipes and diagnostics
```

The engine, vendor recipes, data-root layout, run journal and public commands are **unchanged**. `PASeasyInstall.psd1` remains importable without NativeHTMLKit.UI. CLI usage is supported even though this pass prioritizes GUI UX.

## Safety / intentionally strict behavior

- New drafts do not show the sample `192.0.2.x` addresses as real targets. Existing profiles can still contain the original example values; deployment rejects documentation-only TEST-NET addresses for selected targets and controller/Vault addresses.
- Unchecked components are removed from the draft deployment selection. Disabling the primary Vault means an existing Vault address must be entered for other PAM components.
- For co-located PVWA/CPM/PSM, use the same host ID, address and remote user; for different servers, give them distinct IDs.
- A previously reviewed plan is invalidated for deployment if any form field or saved configuration changes. A separate media check occurs before credential handoff / launch.
- No action silently installs, retries an unknown attempt, turns off security policy, creates a domain, saves passwords or starts a Vault login.
- Old multi-instance configurations are loaded and preserved. Their individual host IDs and addresses are **not editable in this first GUI**; edits that would falsely apply a single target to multiple instances are rejected. Inspect JSON for those exceptional cases.
- The UI does not present successful workflow execution as proof of complete CyberArk functional qualification. Existing operational gaps (DR failover, PTA, PSMP session and complete topology) remain.

## Known limits, deliberate deferrals

- NativeHTMLKit is not installed in the build container. The rewritten window and callbacks have **not been visually smoke-tested or run on a real Windows PowerShell 5.1 desktop** here.
- Advanced recipe options, certificates, Linux SSH identity files, custom multiple component instances, extended domain join inventories, and security policy overrides are preserved from existing JSON but are not fully editable through the first UI.
- The six-page wizard and collapsing optional fields are implemented using the public NativeHTMLKit.UI component contract. Dynamic add/remove hosts, native file/folder pickers and progress bars remain for later UX passes.
- Current remote operations and health callbacks can block UI rendering for long remoting timeouts. Prove the native SDK’s callback/task contract before adding background threads or inventing an HTTP worker.
- The UI uses installation **completion** semantics of the existing engine. Separate installation/operational acceptance reporting is not introduced in this UX pass.
- Creating a config is possible from UI only when all enabled target addresses are filled. Preview is schema-level; live vendor validation remains explicit at installation.

## Local acceptance checks

1. Start the command-line launcher with no config; confirm one native window opens, the Primary Vault preset is in memory, target address is blank and no file exists.
2. Choose Vault + PVWA (or any subset), enter real addresses, preview: it states exactly what will deploy and skip and does not contact servers. Save to a temporary JSON and re-open it.
3. Open an ExistingVault preset, select PVWA while skipping Vault, edit host ID/address and confirm the persisted `vault.existing=true` and selected `components`/`hosts` fields.
4. Give PVWA and CPM the same host ID but conflicting addresses: preview/save must reject. Give different IDs: preview/save must succeed.
5. Open a JSON with two PVWA instances and distinct media files: both remain intact after editing unrelated fields; changing its single displayed target is rejected.
6. After preview and save, change a target and press START: no controller is launched; an unsaved-change error is shown. Re-save/re-preview, and verify missing vendor media prevents start before any target mutation.
7. Cancel a native credential prompt: no installation occurs; check process memory/cache is cleared on start/resume/close.
8. Verify service and authenticated status use existing public commands; an actual `Succeeded` run must not be described as fully functionally verified.
9. Run the existing suite, new UI-first tests, and `Tools/Check-UIFirst.ps1 -RunPester` on PowerShell 5.1 and NativeHTMLKit.UI on the Windows VM; record tests and actual GUI screenshots.
10. Confirm that `Import-Module PASeasyInstall` succeeds without NativeHTMLKit.UI installed; only the GUI entrypoint requires it.

## Status

**Source-implemented draft; unverified on native Windows runtime.** The UI and unit tests were authored against the repo's existing `Add-NHKUi*` functions, but no PowerShell runtime or Windows GUI is present in the build environment. Do not label this “fully working/qualified” until the local agent records the checks above. This restriction does not apply to code structure, but does apply to runtime claims.
