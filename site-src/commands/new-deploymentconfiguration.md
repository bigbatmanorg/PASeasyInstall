# New-PASDeploymentConfiguration

Composes **one configuration for a whole lab**: Vault (Primary, Primary + DR, or an existing Vault) plus any number
of component instances. It contacts no server and installs nothing. This is what the desktop calls behind the
scenes.

```powershell
New-PASDeploymentConfiguration -Environment <name> -VaultMode Primary|PrimaryDR|Existing
    [-Instances <hashtable[]>] [-ControllerAddress <ip>] [-PrimaryAddress <ip>] [-DRAddress <ip>]
    [-ExistingVaultAddress <ip>] [-Username <name>] [-LinuxUsername <name>]
    [-PrimaryUsername <name>] [-DRUsername <name>] [-Media <hashtable>]
    [-ExecutionMode Sequential|Parallel] [-SecurityProfile Secure|Lab] [-AcceptEula]
```

| Parameter | Description |
|---|---|
| `-Environment` | Lab name, for example `Lab01`. |
| `-VaultMode` | `Primary`, `PrimaryDR` (new Primary and DR together) or `Existing`. |
| `-Instances` | `@{Type='PVWA'; Name='PAS-PVWA'; Address='10.10.0.21'; Username=''}` per server. `Type` is `PVWA`, `CPM`, `PSM` or `PSMP` (up to 4 each). Instances with the same `Address` share one server. Linux instances may add `IdentityFile` / `KnownHostsFile`. |
| `-ControllerAddress` | The address the servers use to reach the controller. The hardened Vault allows only this address. |
| `-PrimaryAddress`, `-DRAddress`, `-ExistingVaultAddress` | Vault addresses for the chosen mode. |
| `-Username`, `-LinuxUsername` | Default accounts (`Administrator`, `root`). `-PrimaryUsername` / `-DRUsername` override them for the Vault servers. |
| `-Media` | From [`Get-PASMediaSelection`](media.md), or `@{Vault='C:\…\Server-Rls-v15.0.zip'; …}`. |
| `-ExecutionMode` | `Sequential` (one server at a time) or `Parallel` (the Vault/DR first, then PVWA, then the other component servers concurrently). |
| `-SecurityProfile` | `Secure` (default) or `Lab`, which adds the audited lab deviations. See [Lab and Secure profiles](../concepts/profiles.md). |
| `-AcceptEula` | Required when PSMP is included. |

## Example

```powershell
$cfg = New-PASDeploymentConfiguration -Environment Lab01 -VaultMode Primary `
        -PrimaryAddress 10.10.0.11 -ControllerAddress 10.10.0.10 `
        -Instances @(
          @{ Type = 'PVWA'; Name = 'PAS-APP'; Address = '10.10.0.21' }
          @{ Type = 'CPM';  Name = 'PAS-CPM'; Address = '10.10.0.21' }   # co-located with PVWA
        ) -Media $media -SecurityProfile Lab
```
