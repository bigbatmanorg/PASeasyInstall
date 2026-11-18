# PASeasyInstall: contributor and coding-agent notes

PASeasyInstall builds **CyberArk PAM self-hosted labs** (Vault, DR, PVWA, CPM, PSM, PSMP, AD) from one Windows
PowerShell 5.1 controller, through a native desktop UI or the command line. It is intended for labs. Production
use is at your own risk.

## Rules

- **No vendor material in the repository.** Installation media, `license.xml`, keys, recovery files, credentials
  and customer data are supplied locally by the operator. Never commit or upload them.
- **No secrets in code, logs, journals, project JSON or rendered UI text.** Passwords exist only as SecureString in
  process memory. A lab-mode password prefill may come only from `$env:PASEASY_LAB_PASSWORD`.
- **The UI talks to the backend only through** `Modules/PASeasyInstall.UI/Backend/Backend.Contract.ps1`. Keep the
  Mock backend and the contract in sync. Use only the public NativeHTMLKit.UI API: no web view, JavaScript or HTTP server.
- **Windows PowerShell 5.1 compatibility:** files containing non-ASCII characters must be saved as UTF-8 *with* BOM.
- **The module is not Authenticode-signed.** Every PowerShell process the toolkit starts must pass
  `-ExecutionPolicy Bypass`, which `Tests/ExecutionPolicyLaunch.Tests.ps1` enforces.
- **Never blindly rerun an installer whose outcome is uncertain.** Reconcile the recorded attempt, then resume.
- A successful process exit is not proof that a component works. Use component health and functional checks.
- **PTA** code is kept for future work but is not part of this release (not in the UI, not in the public commands).

## Build and test

```powershell
.\Tools\Check-Modular.ps1                     # parser, manifests, sample plans (no remote operations)
Invoke-Pester -Path .\Tests                   # Pester 5; some tests are Windows-only
```

UI development without servers: `.\Start-PASeasyInstall.ps1 -Backend Mock`.
