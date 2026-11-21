# PASeasyInstall: contributor and coding-agent notes

PASeasyInstall builds **CyberArk PAM self-hosted labs** (Vault, DR, PVWA, CPM, PSM, PSMP, AD) from one Windows
PowerShell 5.1 controller, with PowerShell commands or a desktop wizard. It is intended for labs. Production
use is at your own risk. Read `Docs/DESIGN.md` first: it explains the layout and what a run does.

## Layout

- `PASeasyInstall/` is the **one core module**. It has **no dependency**, in particular no GUI dependency: it
  must import and work without NativeHTMLKit.
- `PASeasyInstall/Desktop/` is the desktop window, opened by the public command `Start-PASeasyInstall`. There is one module.
- `Start-PASeasyInstall.ps1` at the repository root opens the desktop from a source checkout.

## Rules

- **No vendor material in the repository.** Installation media, `license.xml`, keys, recovery files, credentials
  and customer data are supplied locally by the operator. Never commit or upload them.
- **No secrets in code, logs, journals, project JSON or rendered UI text.** Passwords exist only as SecureString in
  process memory. A lab-mode password prefill may come only from `$env:PASEASY_LAB_PASSWORD`.
- **The UI calls only the public commands** listed in `PASeasyInstall/Desktop/Backend/Backend.Contract.ps1`. It never
  calls a private function and implements no installer logic. Keep the Mock backend and the contract in sync.
  It is written directly on the NativeHTMLKit SDK (HTML and CSS in `PASeasyInstall/Desktop/Web`, no UI library, no web view,
  JavaScript or HTTP server): `Model.ps1` is the data, `Views.ps1` the screens as HTML text, `App.ps1` the window and events.
- **One function prefix: `PAS`.** No `PASeasy`, `PAExec` or `PAE` prefixes in new function names.
- **One public command per file** in `PASeasyInstall/Public/`, named after the command, with comment-based help
  (synopsis, description, parameters, at least one example). `FunctionsToExport` in `PASeasyInstall.psd1` must
  list exactly these files. `Tests/PublicSurface.Tests.ps1` and `Tools/Check-Source.ps1` enforce it.
- **New code: one statement per line.** No `;`-joined statements, no one-line `if(){}else{}` chains. Older
  dense code is tidied only when it is changed anyway.
- **Windows PowerShell 5.1 compatibility:** files containing non-ASCII characters must be saved as UTF-8 *with* BOM.
- **The modules are not Authenticode-signed.** Every PowerShell process the toolkit starts must pass
  `-ExecutionPolicy Bypass`, which `Tests/ExecutionPolicyLaunch.Tests.ps1` enforces.
- **Never blindly rerun an installer whose outcome is uncertain.** A step that ended Failed or Unknown is not
  repeated automatically. Resume reconciles the recorded attempt; only the operator repeats a step, by name
  (`Resume-PASRun -RetryStep`).
- A successful process exit is not proof that a component works. Use the verify step and `Test-PASHealth`.
- **Three locks only** (`PASeasyInstall/Private/Engine/Locks.ps1`): run lock, target lock, Vault mutex. Do not
  add another coordination mechanism.
- **PTA was removed** from the PowerShell code. It will be re-added later as a normal component recipe. Do not
  add PTA special cases to the controller. (PTA shell branches still exist in `Recipes/LinuxComponent`; see the
  debt list in `Docs/DESIGN.md`.)

## Build and test

```powershell
.\Tools\Check-Source.ps1                      # parser, both manifests, export list == Public folder (no remote operations)
.\Tools\Invoke-CITests.ps1                    # Check-Source, then the Pester suite CI runs
Invoke-Pester -Path .\Tests                   # Pester 5; some tests are Windows-only
.\Tools\Build-PortableRelease.ps1             # both Gallery packages and the portable ZIP, under .\dist
```

Tests share `Tests/TestHelpers.ps1` (repository paths, `Import-PASTestModule`). Private functions are reached with
`InModuleScope PASeasyInstall { ... }` or `Mock -ModuleName PASeasyInstall`. `Tests/OnTarget/` holds manual checks
that run on a disposable server; CI does not run them.

UI development without servers: `.\Start-PASeasyInstall.ps1 -Backend Mock`.
