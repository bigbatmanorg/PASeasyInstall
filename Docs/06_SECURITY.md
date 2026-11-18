> **Design notes.** This is internal design documentation, kept for contributors; parts of it describe plans
> and history rather than the current release. For user documentation see
> <https://bigbatmanorg.github.io/PASeasyInstall/>. PASeasyInstall is intended for building CyberArk PAM
> **labs**; production use is at your own risk. Not affiliated with or endorsed by CyberArk.

# 06 — Security and Lab Override Policy

## Security objective

Secure-by-default for real deployments, configurable for disposable labs. Do not confuse *deliberately weaker environmental security controls* with *unreliable execution*. The latter must not be optional.

## Threats identified from the supplied code

1. Vendor Ansible Vault role grants `Users` `FullControl` to sensitive PACLI/database-related paths in `tasks/vault_postinstall.yml` — never import that as a default.
2. PSM role stages a password in `Winlogon\DefaultPassword` across several installation/reboot stages — do not carry this insecure lifecycle into the new PSM recipe.
3. PVWA registration skips certificate validation; CPM registration alters `validatePVWASecureConnect` to false; PTA installer APIs use `validate_certs: false` — explicit lab overrides only.
4. PSMP shell installer hardcodes `Hardening=No` and removes files with a broad `xargs rm -rf` pipeline — replace with explicit installation/hardening and safe directory cleanup.
5. Current engine may persist arbitrary remote `Data` as JSON state despite redacting some event text — use an allowlisted nonsecret result schema; do not rely on regex redaction alone.
6. Current Vault CLI tasks may pass credentials as command-line arguments due to inherited vendor PACLI behavior; investigate secure vendor-supported alternatives, limit transient exposure, and report residual risk.
7. Lab-hardening restoration of WinRM creates a potential baseline deviation; exact network/endpoint permissions and manual recovery path must be explicit.

## Policy levels

### `Secure` (default)
- TLS validation on, trusted certificates or explicit trust provisioning; SSH host keys verified.
- Vendor-qualified hardening enabled; firewall minimum connections; least necessary ACLs.
- Qualified OS/host/component combinations; Vault/DR not joined to domain.
- Dedicated accounts where supported, no plaintext credentials in JSON, logs or scripts on disk.

### `Lab` (explicit operator selection)
- Can request supported overrides: trusted vs self-signed/untrusted TLS, WinRM HTTP, skipping vendor hardening, sandbox-only firewall exceptions, relaxed compatibility **policy checks**, test accounts and credentials, etc.
- Every override is scoped by recipe/host/connection, validated for applicability and listed in preview and final report.
- Override cannot disable target identity verification, attempt journaling, secret redaction, Vault-operation serialization, immutable plan fingerprints or unknown-result reconciliation.
- A check waived by operator must be `Waived`, never shown as `Passed`; final report is marked experimental/non-hardened where applicable.

## Credential lifecycles

- JSON stores **credential reference IDs only** (e.g. `win-admin`, `vault-admin`), never passwords.
- UI uses masked credential controls and a protected handoff; CLI accepts `PSCredential`/`SecureString` objects or a qualified secret provider. Do not assume a SecureString is automatically safe when converted to command-line arguments or passed through WinRM.
- Interactive mode may use CurrentUser DPAPI within the **same tested logon identity**; the controller deletes its encrypted handoff envelope as soon as it loads credentials. The provided validation report specifically records failures using DPAPI/NTLM from SSH-based sessions; do not assume cross-context decryption.
- Unattended mode has an explicit provisioning step and controller identity that can access an OS-backed credential provider without an interactive UI. Profile loading and scheduled-task secret retrieval are acceptance tests before advertising unattended support.
- For remote SYSTEM installs, hand off only the secrets necessary for that attempt, using restricted ACLs, short lifetime and appropriate DPAPI scope or vendor supported transient credentials. Destroy staging on successful reconciliation; on failure, preserve only nonsecret diagnostic data.
- Never make secrets available to HTML DOM, UI debug snapshots, JSON run/evidence, command-line flags, process listings, transcript logs or support bundles. Treat vendor log content as potentially sensitive by default even after best-effort sanitization.
- Windows Administrator/LocalSystem and Vault Administrator may still observe sensitive information; the installer is a privileged operator tool, not an isolation boundary from the machine administrator.

## Installation media and key material

- Input is a licensed operator-supplied media directory. Maintain SHA-256 manifest, verify source uniqueness and optionally vendor signatures when supported, and pin media hashes in the run plan.
- Reject ZIP traversal, absolute paths, symlinks, duplicate logical assets, extraction bombs and archive name trickery.
- Restrict media cache, license files, recpub.key/private key material and remote staging to approved identities; clean as vendor rules allow. Never upload vendor media to GitHub/Gallery or include it in support zip.

## Hardening and network recovery

- Test whether management will remain available **before** hardening. If final vendor baseline intentionally disables WinRM, provide a validated out-of-band verification/recovery route. Lab-only narrow management exceptions must be explicitly approved and surfaced as a security deviation.
- Snapshot rollback is a **test-lab recovery tool**, not a general production rollback guarantee. Before any snapshot restore, verify exact VM ID, name, selected baseline and external impacts.
- Do not re-run key generation, AD forest promotion, hardening, Vault initial configuration or installer setup solely because a previous attempt returned timeout.

## Security acceptance cases

1. Run with synthetic marker secrets in UI/CLI; scan all persisted state, event journal, controller logs, remote staged command lines and report bundles for leakage.
2. Multiple same-account Vault API/PACLI attempts → exactly one active authenticated operation within application; others wait or fail without logging in.
3. Certificate expired/self-signed → Secure fails validation; Lab override succeeds only where recipe implements override, reports the deviation.
4. PSM interrupted during credentials stage → no leftover Winlogon plaintext password, no persistent autologon unintended.
5. Media malicious archive → extraction refused, no file outside staging root modified.
6. Hardened Vault blocks WinRM → controller reports recoverable/observable state and does not reopen unrestricted firewall automatically.
7. Resume after modified recipe/media → refuses stale plan.
8. After exported support bundle → scan for license, keys, secrets and raw sensitive traces.
