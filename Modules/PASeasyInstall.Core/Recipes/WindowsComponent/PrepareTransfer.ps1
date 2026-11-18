[CmdletBinding()]param([Parameter(Mandatory)][hashtable]$Settings,[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Workspace.ps1')
if($ValidateOnly){Protect-PASeasyComponentWorkspace -Settings $Settings -ValidateOnly}
else{Protect-PASeasyComponentWorkspace -Settings $Settings -PrepareTransfer}
[pscustomobject]@{Passed=$true;Message='Media destination ownership and ACL prepared before upload'}
