# Start-PASEnvironment

Starts a deployment in a **detached controller process** and returns its run ID immediately.

```powershell
Start-PASEnvironment [-Config <path>] [-Configuration <object>]
    -CredentialMap <hashtable> -SecretMap <hashtable> [-PlanOnly] [-Confirm:$false]
```

| Parameter | Description |
|---|---|
| `-CredentialMap` | `@{ <server name> = [PSCredential] }`, one entry per target server (keys are the host names in the configuration). |
| `-SecretMap` | `@{ VaultAdmin = [SecureString]; VaultMaster = [SecureString]; DRPassword = [SecureString] }`. `DRPassword` only for Primary + DR. |
| `-PlanOnly` | Return the plan; start nothing. |

```powershell
$pw    = Read-Host 'Lab password' -AsSecureString
$creds = @{ vault01 = [pscredential]::new('Administrator', $pw); dr01 = [pscredential]::new('Administrator', $pw) }
$sec   = @{ VaultAdmin = $pw; VaultMaster = $pw; DRPassword = $pw }

PS> Start-PASEnvironment -Config C:\Labs\Lab01-vault.json -CredentialMap $creds -SecretMap $sec -Confirm:$false
688d8e04f1874d41a75cda4441c00553
```

Configurations from [`New-PASDeploymentConfiguration`](new-deploymentconfiguration.md) run as a coordinated set of
engine runs: the Vault (+DR) first, then one run per component server, sequentially or in parallel. A plain
local account name is used as `.\<name>` for WinRM.

Follow the deployment with [`Get-PASEnvironmentSnapshot`](snapshot-events.md).
