param(
    [Parameter(Mandatory = $true)][hashtable]$Settings,
    [Parameter(Mandatory = $true)][string]$AdminPassword,
    [Parameter(Mandatory = $true)][string]$RunId
)
# PAEASY_INCLUDE_VAULT_PACLI
$ErrorActionPreference = 'Stop'
$name = Get-PAPacliTestSafeName $RunId
$pacli = Join-Path (Join-Path $Settings.PackagesRoot 'PACLI') 'Pacli.exe'
$session = $null
$exists = $false
try {
    $session = Open-PAPacliVaultSession $pacli $AdminPassword
    $safe = Open-PAPacliSafe $session $name -AllowMissing
    $exists = [bool]$safe.Exists
    if ($exists) { Close-PAPacliSafe $session $name }
} finally { if ($session) { Close-PAPacliVaultSession $session } }
if (-not $session.Closed) { throw 'PAExecUnknown: replication Safe verification session closure is unconfirmed' }
[pscustomobject]@{
    Passed = $exists
    Message = ('Safe ' + $name)
    Evidence = @('PACLI independent Safe access checked', 'PACLI logoff negative control and TERM acknowledged')
    SessionClosed = $true
}
