# Security model

- **Passwords live only in memory.** The desktop keeps them in password fields and converts them to
  `SecureString` only when you click Install. They never appear in the project file, logs, journals or the rendered
  UI.
- **Hand-off to the detached controller.** Credentials are passed as a DPAPI-protected envelope readable only by the
  same Windows user on the same machine. It is deleted as soon as the controller has read it.
- **On the targets**, stage inputs that contain secrets are encrypted with the target machine's DPAPI and deleted after
  use. Vault passwords reach PACLI through a private pipe, never on a command line.
- **WinRM over HTTPS only** by default (`WinRM.RequireHTTPS`). Each target gets a restricted endpoint usable only by the
  configured local administrator account.
- **Hardening** uses CyberArk's own hardening for every component. The Vault firewall allows management only from
  the controller address.
- **Linux:** the controller uses its own SSH key per environment. The server password is used once, through
  `SSH_ASKPASS`, to authorise that key. Secure mode requires a known host key; Lab mode trusts the key on first use
  and logs it.
- **Unsigned module:** every PowerShell process the toolkit starts uses an explicit `-ExecutionPolicy Bypass`. See
  [Execution policy](../getting-started/execution-policy.md).

Nothing in PASeasyInstall collects telemetry or contacts any service other than your servers. The PowerShell Gallery
is contacted only if you install from it.
