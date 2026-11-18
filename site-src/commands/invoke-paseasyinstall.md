# Invoke-PASeasyInstall

Installs (or plans, or resumes) a lab from a saved project, from the command line: the script-friendly counterpart
of the desktop.

```powershell
Invoke-PASeasyInstall [-Config] <path> [-PlanOnly] [-CredentialMap <hashtable>] [-SecretMap <hashtable>]
    [-LabPassword <SecureString>] [-Wait] [-PollSeconds <5-600>]
Invoke-PASeasyInstall -Resume <runId> [-RetryFailedPreflight] [-CredentialMap …] [-SecretMap …] [-LabPassword …] [-Wait]
```

| Parameter | Description |
|---|---|
| `-Config` | A project saved by the desktop, or written with [`New-PASDeploymentConfiguration`](new-deploymentconfiguration.md) and [`Save-PASEnvironment`](save-environment.md). |
| `-PlanOnly` | Validate and show the plan; contact no server. |
| `-CredentialMap` | `@{ <server id> = PSCredential }`. Servers that are missing are prompted for. |
| `-SecretMap` | `@{ VaultAdmin / VaultMaster / DRPassword / ADSafeMode / DomainJoinPassword = SecureString }` |
| `-LabPassword` | One password for every server and secret. Lab profile only. |
| `-Wait` | Stream progress events until the deployment ends, then return the final run status (the same object as `Get-PASEnvironmentSnapshot`). |
| `-Resume` | Resume a failed or interrupted engine run by its run ID. For a composed deployment, pass the run ID of the failed unit (shown by `Get-PASEnvironmentSnapshot`). |
| `-RetryFailedPreflight` | With `-Resume`: run a failed read-only preflight again, for example after installing a missing OS package. |

It validates the configuration and the installer media, asks for anything it still needs in secure prompts, starts
the detached installer and returns the deployment ID. The installation keeps running if you close the console.
Passwords stay in memory and never reach the project file, logs or command lines.

## Examples

```powershell
# What would happen
Invoke-PASeasyInstall -Config C:\Labs\Lab01.json -PlanOnly

# Install Lab01 from its saved project with one lab password, and follow progress
Invoke-PASeasyInstall -Config C:\Labs\Lab01.json -LabPassword (Read-Host -AsSecureString 'Lab password') -Wait

# Start and follow separately
$id = Invoke-PASeasyInstall -Config C:\Labs\Lab01.json
Get-PASEnvironmentSnapshot -RunId $id

# Resume a failed unit after installing a missing package on its server
Invoke-PASeasyInstall -Resume 476e08eea7024de4ab7cfb889cd1c5f1 -RetryFailedPreflight
```

<!-- TODO(parent): add a real captured -PlanOnly / -Wait transcript from the test campaign. -->
