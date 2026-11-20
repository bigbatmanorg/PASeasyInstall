param([Parameter(Mandatory=$true)][hashtable]$Settings,[Parameter(Mandatory=$true)][string[]]$Components)
# PAEASY_INCLUDE_VAULT_WORKSPACE
$ErrorActionPreference='Stop'
$changed=$false
foreach($component in $Components){if(Expand-PASeasyVaultMedia $Settings $component){$changed=$true}}
[pscustomobject]@{Changed=$changed;Message='Vault media admitted, extracted and pinned; stable ownership verified'}
