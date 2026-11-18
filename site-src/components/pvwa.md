# PVWA

| Stage | What it does |
|---|---|
| `management` | Restricted management endpoint for the configured administrator |
| `media-upload`, `preflight`, `extract` | Copies and verifies the PVWA installer and locates the vendor scripts |
| `prerequisites` | VC++ runtimes and the 29 IIS / .NET Windows features PVWA requires |
| `install` | Vendor installation (install and application directories configurable) |
| `configuretls` | Binds a TLS certificate. In **Lab** mode a self-signed certificate for the server name is created and trusted on this server. |
| `register` | Registers PVWA in the Vault with the Vault Administrator password |
| `harden` | CyberArk PVWA hardening: legacy SSL/TLS off, unused services disabled |
| `verify` | Checks that the services and the application run |

**Options:** `pvwaUrl` (default `https://<server>/PasswordVault`) and `createLabCertificate` (Lab mode).

After installation, sign in at `https://<pvwa>/PasswordVault`. Self-signed certificates in Lab mode must be accepted
or imported on the client.

!!! note "If PVWA reports *Vault is currently under maintenance mode*"
    PVWA started while the Vault was still booting. Recycle the `PasswordVaultWebAccessPool` app pool on the PVWA
    server, or always start the Vault before PVWA. See [Troubleshooting](../troubleshooting/index.md).
