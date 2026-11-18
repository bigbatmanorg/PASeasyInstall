# Get-PASEnvironmentPlan

Shows exactly what would happen, without contacting any server.

```powershell
Get-PASEnvironmentPlan [-Config <path>] [-Configuration <object>] [-ResolveMedia]
```

`-ResolveMedia` also resolves and fingerprints every media file (Server, PACLI, PAKeyGen, VC++, license and
recovery key) as it would be used.

```powershell
PS> $plan = Get-PASEnvironmentPlan -Config C:\Labs\Lab01-vault.json
PS> $plan | Format-List Name,ConfigDigest,ExecutionMode,Warnings

Name          : Lab01
ConfigDigest  : a66a77a8326f7af99cb1af76a4015fa62908a26fe9edd951c35417e595ef74a6
ExecutionMode : Sequential
Warnings      : {SECURITY DEVIATION: WinRM.SkipCNCheck = True, SECURITY DEVIATION: WinRM.SkipCACheck = True, SECURITY DEVIATION: Vault.AllowRDP = True}

PS> $plan.Items | Format-Table Id,Type,Host,Variant,DependsOn

Id    Type    Host    Variant    DependsOn
--    ----    ----    -------    ---------
vault Vault   vault01 Standalone {}
dr    DRVault dr01    StandardDR {vault}
```

For configurations composed by [`New-PASDeploymentConfiguration`](new-deploymentconfiguration.md), each item also
carries `Name`, `Address`, `Os` and `Media`. These are the columns the [Review plan](../gui/review.md) step shows.
