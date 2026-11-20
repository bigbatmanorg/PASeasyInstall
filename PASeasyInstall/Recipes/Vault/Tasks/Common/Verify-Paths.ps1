param([Parameter(Mandatory=$true)][hashtable]$Settings,[string]$Role='Primary')
# PAEASY_INCLUDE_VAULT_WORKSPACE
$ErrorActionPreference='Stop'
try {
    Protect-PASeasyVaultWorkspace $Settings -ValidateOnly
    $policy=Join-Path $Settings.AutomationRoot 'management-policy.json'
    $entry=Assert-PASeasyVaultEntry $policy -Protected
    if($entry.PSIsContainer){throw 'Management policy is not a file'}
    $record=Get-Content -LiteralPath $policy -Raw -Encoding UTF8|ConvertFrom-Json
    if($record.schemaVersion -ne 1 -or $record.Role -cne $Role){throw 'Management policy identity differs'}
    [pscustomobject]@{Passed=$true;Message='Vault workspace ownership and protected ACLs verified';Evidence=@('all workspace trees admitted','stable SYSTEM/Administrators ownership','management policy staged')}
} catch {[pscustomobject]@{Passed=$false;Message='Vault workspace validation failed; inspect trusted path ownership and ACLs';Evidence=@()}}
