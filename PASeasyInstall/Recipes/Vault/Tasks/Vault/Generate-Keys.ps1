param([Parameter(Mandatory = $true)][hashtable]$Settings)
$ErrorActionPreference = 'Stop'
# PAEASY_INCLUDE_VAULT_KEYS
Invoke-PASeasyKeyGeneration $Settings
