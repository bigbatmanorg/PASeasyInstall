> **Design notes.** This is internal design documentation, kept for contributors; parts of it describe plans
> and history rather than the current release. For user documentation see
> <https://bigbatmanorg.github.io/PASeasyInstall/>. PASeasyInstall is intended for building CyberArk PAM
> **labs**; production use is at your own risk. Not affiliated with or endorsed by CyberArk.

# 05 — Configuration, CLI and Packaging Contract

## Configuration philosophy

One **versioned JSON file** describes the desired environment, not the steps used to achieve it. Both UI and CLI read/write the same schema. No credentials in the file. File can be checked into a private project when it contains only nonsecret infrastructure details; it must not contain vendor media or licenses.

### Sections

- `schemaVersion`: integer, begins at 1; unknown major versions rejected.
- `name`: friendly environment name; `environmentId`: stable machine-readable identifier used for run locking and history.
- `media.root`: folder of externally supplied licensed CyberArk packages. Preflight discovers and validates exact expected files/hashes/version; ambiguous matching is an error.
- `hosts`: unique host records with address, OS, transport and credential reference. Host IDs are the basis of placement and shared prerequisites.
- `components`: named instances with component type, variant, desired action (`Install` or `Existing`) and host reference; `options` is limited and validated by the selected recipe.
- `activeDirectory`: `None`, `Create`, `Existing`; chosen DC, domain and eligible join hosts; test-account option.
- `vaultAccess`: specific selected Vault component ID and Vault credential reference to use for registration/authenticated checks.
- `security`: secure baseline or lab profile, explicit recipe-qualified overrides. Overrides must appear in final evidence.

Draft machine schema: `schema/deployment.schema.json`. Example files: `examples/full-lab.json`, `examples/vault-only.json`. For `ADOnly`, `components` is an empty array and `activeDirectory.mode` must not be `None`. If a new Primary and DR are selected together, use the coordinated `PrimaryWithDR` topology recipe. A schema-valid configuration is **not** sufficient for deployment: `Test-PASeasyConfiguration` performs cross-reference, compatibility, identity, media, credential-source and remote preflight checks.

## CLI exported surface (proposed)

| Command | Input | Result / semantics |
|---|---|---|
| `New-PASeasyConfiguration` | `-Template VaultOnly|PrimaryDR|FullLab|ExistingVault|ADOnly -Path` | Creates commented-free JSON template, does not deploy |
| `Test-PASeasyConfiguration` | `-Path` or `-InputObject`; optional `-Online` | Structured issues (`Error/Warning/Deviation`), remote probes only with `-Online` |
| `Get-PASeasyPlan` | `-Path` or `-InputObject` | Canonical plan including dependencies, resources, hashes and policy warnings |
| `Start-PASeasyDeployment` | config, credential resolver/credential map, `-Detached` or `-Wait` | Explicit approval/`-Confirm` supported; returns run ID and status; creates durable controller |
| `Get-PASeasyDeployment` | `-RunId` / `-Latest` | Current run + steps + timestamps; no secrets |
| `Resume-PASeasyDeployment` | `-RunId` + fresh credentials if needed | Reconcile original attempts, then continue |
| `Test-PASeasyDeployment` | `-RunId` or environment | Independent read-only verification and optional flagged functional tests |
| `Get-PASeasyComponent` | environment/run and component/host filter | Status, version, health, last-check evidence |
| `Get-PASeasyLog` | component/host/source, `-Tail`, `-Follow` | Bounded sanitized controller/remote log stream |
| `Show-PASeasyInstall` | optional config/run | Launch optional NativeHTMLKit GUI after checking/pinning SDK/UI modules |

Command names are a **design contract**, not claims about existing implementations. Limit exported functions to this surface initially. Include PowerShell `Get-Help` documentation, structured output and stable error codes such as `CONFIG_INVALID`, `MEDIA_MISSING`, `PLAN_DRIFT`, `TARGET_UNKNOWN`, `ATTEMPT_UNCERTAIN`, `VAULT_GATE_BUSY`, `CREDENTIAL_UNAVAILABLE`, `RECIPE_UNQUALIFIED`.

### Interactive CLI example

```powershell
Install-Module PASeasyInstall -Scope CurrentUser
Import-Module PASeasyInstall
New-PASeasyConfiguration -Template PrimaryDR -Path .\lab.json
Test-PASeasyConfiguration -Path .\lab.json -Online
Get-PASeasyPlan -Path .\lab.json | Format-Table
$hostAdmin = Get-Credential # PowerShell object, not JSON password
$vaultAdmin = Get-Credential
$creds = @{ 'win-admin' = $hostAdmin; 'vault-admin' = $vaultAdmin }
Start-PASeasyDeployment -Path .\lab.json -CredentialMap $creds -Wait
Get-PASeasyDeployment -Latest
Test-PASeasyDeployment -RunId '<run-id>'
```

### Headless/unattended example

```powershell
# First provision a supported secret store readable by the qualified controller identity.
# This command resolves only nonsecret refs from the JSON in the controller context.
Start-PASeasyDeployment -Path .\lab.json -SecretProvider WindowsCredentialManager -Detached -Confirm:$false
Get-PASeasyDeployment -Latest
```

**Qualification caveat:** the above unattended provider option is a proposed interface; it must not be advertised as usable until scheduled-task logon identity, profile loading, secret retrieval and Windows remoting have been tested together. `-Confirm:$false` requires an explicitly validated deployment plan and acknowledgement of policy deviations; no secret API keys are placed on command lines.

## Module packaging

- A single `PASeasyInstall.psd1` + `PASeasyInstall.psm1` package; no `RequiredModules` entry for PSSteps.
- No `RequiredModules` entry for NativeHTMLKit because CLI-only installation must work. `Show-PASeasyInstall` imports `NativeHTMLKit.UI` and `NativeHTMLKit` **on demand**, with pinned qualified versions and actionable error if absent. An optional offline UI bundle can package those Gallery modules alongside the installer without changing the core module's public dependency contract.
- MIT provenance of adapted engine code is retained as required, including copyright notices; inspect license obligations of any vendor role code before copying. Licensed vendor media, keys, passwords, snapshots and environment logs are never packaged.
- `Test-ModuleManifest`, PowerShell Script Analyzer, Pester, test install in a clean Windows host, import without UI modules, explicit function export list, module versioning and package file audit before Gallery publication. Microsoft documents the requirement for manifests and package metadata.
- Module installation directory is read-only; all mutable state and media extraction must be under configured data/cache roots, never under `$PSScriptRoot` in the Gallery installation.

## Configuration evolution

- Schema v1 is strict at the top level; recipe-specific `options` are checked by the recipe. Unrecognized security flags are **errors**, not ignored.
- A deprecated key gets a documented migration transform and warnings, never an automatic semantic reinterpretation of previous runs.
- Old frozen plans continue to be inspected; executing/resuming an old run under a new code version is allowed only when a compatibility migration/probe explicitly proves safety.
- Don't offer a generic `-Force` flag that bypasses safety verification or replays irreversible steps.
