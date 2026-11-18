# Lab and Secure profiles

Every configuration has a security profile. **Lab** applies explicit, audited deviations that a lab built from
templates needs. Each one appears on the Review plan step as `SECURITY DEVIATION: <name> = True`.

| Override | Lab | Why a lab needs it |
|---|---|---|
| `WinRM.SkipCACheck`, `WinRM.SkipCNCheck` | on | Lab servers usually carry a self-signed WinRM certificate whose name does not match the address you enter. |
| `Vault.AllowRDP` | on | Lets you RDP to the hardened Vault, from the controller only. |
| `CPM.AllowPinnedLeafTrust` | on with CPM | CPM trusts the PVWA's self-signed certificate by its exact SHA-256 fingerprint instead of a CA chain. |
| PVWA `createLabCertificate` | on | PVWA gets a self-signed certificate for its server name. |
| Linux host key trust on first use | on | The PSMP server's SSH host key is accepted on first connection and logged. |
| One universal password | desktop Lab mode | Convenience; never for production. |

The **Secure** profile applies none of these. WinRM certificates must be trusted and match, PVWA needs a real
certificate, CPM validates the PVWA chain, and SSH host keys must already be in `known_hosts`.

Other overrides exist for advanced scenarios and are always listed as deviations: `PVWA.ValidateTLS`,
`CPM.ValidatePVWA`, `WinRM.RequireHTTPS`, and `<Component>.ApplyHardening` (setting it to `False` skips hardening).
