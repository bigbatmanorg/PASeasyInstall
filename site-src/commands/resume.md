# Resume-PASeasyDeployment

Resumes a failed or interrupted run **after reconciling** what already happened on the targets.

```powershell
Resume-PASeasyDeployment -RunId <id> [-CredentialMap <hashtable>] [-SecretMap <hashtable>] [-RetryFailedPreflight]
```

Both are available: `Resume-PASeasyDeployment` and `Invoke-PASeasyInstall -Resume` (which prompts for missing credentials).

- Resume uses the run's **frozen configuration**. To change the configuration (for example to accept the PSMP EULA),
  start a new run instead.
- Each attempt that was in progress is reconciled first. A finished attempt is not repeated. An installer whose
  outcome is uncertain is **never** rerun blindly.
- `-RetryFailedPreflight` explicitly allows rerunning a preflight that failed, for example after installing a
  missing package such as `unzip` on the target.

```powershell
Resume-PASeasyDeployment -RunId 476e08eea7024de4ab7cfb889cd1c5f1 -SecretMap @{ VaultAdmin = $pw } -RetryFailedPreflight -Confirm:$false
```

For a deployment composed of several runs, resume the run of the failed server.
