param([Parameter(Mandatory=$true)][hashtable]$Settings)
$ErrorActionPreference='Stop'
# PAEASY_INCLUDE_VAULT_KEYS
try{
    $null=Test-PASeasyKeyReceipt $Settings
    [pscustomobject]@{Passed=$true;Message='Generated keys match their protected completion receipt';Evidence=@('four nonempty files: trusted stable ACLs, exact lengths and SHA256 receipt match; contents never logged')}
}catch{
    [pscustomobject]@{Passed=$false;Message='Generated key material is not independently verified; preserve partial state for reconciliation';Evidence=@()}
}
