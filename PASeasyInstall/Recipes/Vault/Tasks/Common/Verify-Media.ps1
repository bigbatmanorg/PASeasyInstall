param([Parameter(Mandatory = $true)][hashtable]$Settings, [Parameter(Mandatory = $true)][string[]]$Components)
# PAEASY_INCLUDE_VAULT_WORKSPACE
$ErrorActionPreference = 'Stop'
$issues = @()
$evidence = @()
foreach ($component in $Components) {
    try {
        $null = Test-PASeasyVaultExtractedMedia $Settings $component
        $evidence += ($component + ' archive hash, extracted file hashes, owner and ACL verified')
    } catch { $issues += ($component + ' media requires reconciliation') }
}
[pscustomobject]@{Passed = ($issues.Count -eq 0); Message = ($issues -join '; '); Evidence = $evidence }
