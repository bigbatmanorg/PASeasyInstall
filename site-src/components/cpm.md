# CPM

| Stage | What it does |
|---|---|
| `management`, `media-upload`, `preflight`, `extract` | As for PVWA |
| `pvwa-trust-certificate` | Lab mode: copies the PVWA's public certificate, verifying its SHA-256 |
| `prerequisites` | VC++ runtimes; verifies the bundled OpenSSL runs |
| `install` | Vendor installation; creates the *Password Manager* and *Central Policy Manager Scanner* services |
| `configuretls` | Trusts the pinned PVWA certificate (Lab), or requires a trusted chain (Secure) |
| `register` | Registers the CPM user (default `PasswordManager`) in the Vault |
| `harden` | CyberArk CPM hardening; the services run as the dedicated `PasswordManagerUser` |
| `verify` | Both services are running |

In a composed deployment, CPM waits for the PVWA it trusts, and that PVWA's certificate is read over the
authenticated management channel. **Options:** `cpmUser`, `pvwaTrustCertificateFile` and `pvwaTrustCertificateSHA256`
(set automatically from the desktop).
