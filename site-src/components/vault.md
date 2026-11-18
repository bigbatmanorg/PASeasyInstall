# Vault

Installs a **new Primary Vault** on a dedicated Windows Server that is not domain-joined.

| Stage | What it does |
|---|---|
| `LocalPreflight` | On the controller: configuration and media checks (read-only) |
| `preflight` | Target identity, address ownership, OS version, existing installation |
| `management-endpoint` | Registers a restricted WinRM endpoint usable only by the configured local administrator |
| `prepare-paths` | Workspace folders with protected ownership and ACLs; management policy that limits WinRM to the controller |
| `upload-*` | Copies Server, PACLI, PAKeyGen, license, recovery key and VC++ runtimes; SHA-256 verified on the target |
| `prerequisites` | VC++ 2013 x86 and 2015–2022 x86/x64 runtimes, and a .NET check |
| `extract` | Extracts and pins the Server and PACLI media (hashes, ownership, ACLs) |
| `keygen` | Generates the Vault keys, with a protected completion receipt (contents never logged) |
| `install-server` | Runs the Vault installer silently (`setup.log` ResultCode 0) |
| `configure-primary` | Starts the Vault services, then checks that the server is up and that a PACLI login and logoff work |
| `harden-primary` | Runs CyberArk's Vault hardening (`StandardVault`); in Lab mode RDP is allowed from the controller only |
| `hardening-reboot` | Reboots and re-verifies the hardening and firewall |
| `verify-primary` | Checks that the server is up after the reboot, that the 4 Vault services run, and that a PACLI login works |

**Secrets used:** Vault Administrator and Master passwords. They are passed to PACLI through a private pipe, never
on a command line.

**After installation:** the Vault firewall accepts management connections only from the controller. To RDP to the
Vault in Lab mode, connect from the controller.
