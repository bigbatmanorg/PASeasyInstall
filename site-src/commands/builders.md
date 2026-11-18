# New-PASFreshEnvironment / New-PASExistingVaultComponent

Single-purpose builders, kept for scripts. For whole labs, prefer
[`New-PASDeploymentConfiguration`](new-deploymentconfiguration.md).

## New-PASFreshEnvironment

A new Primary Vault, or a Primary + DR pair.

```powershell
New-PASFreshEnvironment -PrimaryIP <ip> -ControllerIP <ip> -MediaRoot <folder>
    [-Environment <name>] [-Username <name>] [-WithDR -DRIP <ip>]
    [-LicenseFile <path>] [-PublicRecoveryKey <path>] [-SecurityProfile Secure|Lab]
```

```powershell
$cfg = New-PASFreshEnvironment -Environment Lab01 -PrimaryIP 10.10.0.11 -DRIP 10.10.0.12 -WithDR `
        -ControllerIP 10.10.0.10 -MediaRoot C:\CyberArk\media `
        -LicenseFile C:\CyberArk\media\license.xml -PublicRecoveryKey C:\CyberArk\media\recpub.key
```

## New-PASExistingVaultComponent

One component for an existing Vault.

```powershell
New-PASExistingVaultComponent -Component PVWA|CPM|PSM|PSMP -TargetAddress <ip> -VaultAddress <ip>
    -MediaZip <path> [-Environment <name>] [-Username <name>] [-Options <hashtable>]
```

```powershell
$psm = New-PASExistingVaultComponent -Component PSM -TargetAddress 10.10.0.24 -VaultAddress 10.10.0.11 `
        -MediaZip 'C:\CyberArk\media\Privileged Session Manager-Rls-v15.0.zip'
```
