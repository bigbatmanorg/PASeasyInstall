# PASeasyInstall: contributor and coding-agent notes

PASeasyInstall builds **CyberArk PAM self-hosted labs** (Vault, DR, PVWA, CPM, PSM, PSMP, AD) from one Windows
PowerShell 5.1 controller, with PowerShell commands or a desktop wizard. It is intended for labs. Production
use is at your own risk. Read `Docs/DESIGN.md` first: it explains the layout and what a run does.

## Layout

- `PASeasyInstall/` is the **one core module**. It has **no dependency**. Importing it loads no window code:
  WPF is loaded only by the window process that `Start-PASeasyInstall` starts.
- `PASeasyInstall/Desktop/` is the desktop window, opened by the public command `Start-PASeasyInstall`. There is one module.
- `Start-PASeasyInstall.ps1` at the repository root opens the desktop from a source checkout.

## Rules

- **No vendor material in the repository.** Installation media, `license.xml`, keys, recovery files, credentials
  and customer data are supplied locally by the operator. Never commit or upload them.
- **No secrets in code, logs, journals, project JSON or rendered UI text.** Passwords exist only as SecureString in
  process memory. A lab-mode password prefill may come only from `$env:PASEASY_LAB_PASSWORD`.
- **The UI calls only the public commands** listed in `PASeasyInstall/Desktop/Backend/Backend.Contract.ps1`. It never
  calls a private function and implements no installer logic. Keep the Mock backend and the contract in sync.
  It is written on WPF, which is part of Windows (no other module, no UI framework, no C# project): `Window.xaml` is the
  shell and every style, `Model.ps1` the data, `Controls.ps1` one function per kind of control and the background
  task helper, `Views.ps1` the screens, `App.ps1` the window and events. Every installer call that can take time goes
  through `Start-PASUITask`, so the window's thread never waits. Passwords stay in their password boxes as SecureString;
  the model only knows that one was typed.
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
- **Three locks only** (`PASeasyInstall/Private/Engine/Locks.ps1`): run lock, target lock, Vault mutex. A
  parallel run adds only what lives inside its own controller process (`Private/Run/Lanes.ps1`): the signals
  its lanes wait for and one short-lived mutex while they prepare shared files. Do not add another
  coordination mechanism, and nothing that leaves files or outlives the controller.
- **PTA, the HTML5 Gateway and the domain steps are normal recipes** (`Recipes/Pta`, `Recipes/Html5Gateway`,
  `Recipes/ActiveDirectory`). Keep it that way: a new component gets its own small recipe folder and a type
  name, not special cases in the controller.

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

UI development without servers: `.\Start-PASeasyInstall.ps1 -Backend Mock`. The window can walk itself:
`powershell -STA -File PASeasyInstall\Desktop\App.ps1 -Backend Mock -SelfTest <scenario.json>` presses its own buttons
through UI Automation, checks what it shows and saves every screen as a PNG (see `Desktop/SelfTest.ps1`); it needs no
desktop session.
