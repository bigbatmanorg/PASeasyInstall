# DR Vault

Installs a **standby DR Vault together with a new Primary** (*Primary + DR* on [step 2](../gui/what-to-install.md)).
Adding DR to an existing Primary is not supported.

| Stage | What it does |
|---|---|
| `preflight` … `extract` | As for the Vault, plus the Disaster Recovery media |
| `relay-shared-keys` | Waits for the Primary's keys, then copies them to the DR server (contents never logged) |
| `install-dr-server` | Installs the Vault server on the DR server |
| `prepare-standby` | Stops the DR Vault server; the database keeps running |
| `install-padr` | Installs the Disaster Recovery module pointing at the Primary |
| `configure-padr` | Configures manual failover (`EnableFailover=No`) and starts replication |
| `first-replication` | Waits until a replication cycle and metadata replication have been observed |
| `harden-dr`, `hardening-reboot` | CyberArk hardening and a reboot |
| `replication-after-hardening` | Replication is observed again after hardening |
| `test-safe-replication` | Creates a test Safe on the Primary and confirms it reached the DR Vault |

**Failover policy:** manual. The DR Vault never promotes itself automatically.

!!! tip "Keep DR running"
    With DR configured, the Vault refuses to rotate component passwords until DR has replicated them. Error
    `CASTM057E` appears in component logs while DR is down. Start DR and it catches up within one cycle.
