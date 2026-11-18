# Commands

Everything the desktop does is a PowerShell command. Commands never print passwords. Credentials are passed as
`PSCredential` and `SecureString` objects only.



| Command | Purpose |
|---|---|
| [`Start-PASeasyInstall`](start-paseasyinstall.md) | Open the desktop |
| [`Invoke-PASeasyInstall`](invoke-paseasyinstall.md) | Run a saved project from a script: plan, install or resume |
| [`Get-PASMediaInventory`, `Get-PASMediaSelection`](media.md) | Detect installers, license and keys in files, folders and the bundle ZIP |
| [`New-PASDeploymentConfiguration`](new-deploymentconfiguration.md) | Compose one configuration for a whole lab |
| [`Test-PASEnvironment`](test-environment.md) | Validate a configuration (optionally with media checks) |
| [`Get-PASEnvironmentPlan`](environment-plan.md) | Show the plan without contacting any server |
| [`Save-PASEnvironment`](save-environment.md) | Save a validated configuration as JSON |
| [`Start-PASEnvironment`](start-environment.md) | Start the deployment (detached) |
| [`Get-PASEnvironmentSnapshot`, `Get-PASEnvironmentEvents`](snapshot-events.md) | Follow a deployment |
| [`Resume-PASeasyDeployment`](resume.md) | Resume a failed or interrupted run after reconciling it |
| [`Get-PASStageCatalog`](stage-catalog.md) | List a component's stages |
| [`Test-PASEnvironmentHealth`](health.md) | Check that an installed lab is healthy |
| [`Export-PASRunData`](export-rundata.md) | Export a sanitized bundle of a run for support or documentation |
| [`Close-PASDeployment`](close-deployment.md) | Close an unresolved deployment record after you reset its servers |
| [`New-PASFreshEnvironment`, `New-PASExistingVaultComponent`](builders.md) | Build single-purpose configurations |

## A complete lab from a script

```powershell
Import-Module PASeasyInstall

$inventory = Get-PASMediaInventory -Path C:\CyberArk\media
$media     = Get-PASMediaSelection -Inventory $inventory

$instances = @(
  @{ Type = 'PVWA'; Name = 'PAS-PVWA'; Address = '10.10.0.21' }
  @{ Type = 'CPM';  Name = 'PAS-CPM';  Address = '10.10.0.22' }
  @{ Type = 'PSM';  Name = 'PAS-PSM';  Address = '10.10.0.23' }
  @{ Type = 'PSMP'; Name = 'PAS-PSMP'; Address = '10.10.0.31' }
)
$cfg = New-PASDeploymentConfiguration -Environment Lab01 -VaultMode PrimaryDR `
        -PrimaryAddress 10.10.0.11 -DRAddress 10.10.0.12 -ControllerAddress 10.10.0.10 `
        -Instances $instances -Media $media -ExecutionMode Parallel -SecurityProfile Lab -AcceptEula

Test-PASEnvironment -Configuration $cfg -CheckMedia
Get-PASEnvironmentPlan -Configuration $cfg
Save-PASEnvironment -Configuration $cfg -Path C:\Labs\Lab01.json

Invoke-PASeasyInstall -Config C:\Labs\Lab01.json -Wait   # prompts for the passwords, follows progress
```
