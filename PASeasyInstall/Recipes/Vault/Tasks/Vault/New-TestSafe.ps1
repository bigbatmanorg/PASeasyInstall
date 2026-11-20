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
$changed = $false
try {
    $session = Open-PAPacliVaultSession $pacli $AdminPassword
    $safe = Open-PAPacliSafe $session $name -AllowMissing
    if ($safe.Exists) { Close-PAPacliSafe $session $name }
    else {
        # Only the qualified exact-name ITATS020E negative can reach this mutation.
        Add-PAPacliTestSafe $session $name
        $safe = Open-PAPacliSafe $session $name
        if (-not $safe.Exists) { throw 'Replication Safe creation has no independent access proof' }
        Close-PAPacliSafe $session $name
        $changed = $true
    }
} finally { if ($session) { Close-PAPacliVaultSession $session } }
if (-not $session.Closed) { throw 'PAExecUnknown: replication Safe session closure is unconfirmed' }
[pscustomobject]@{
    Changed = $changed
    Message = ('test Safe ' + $name + ' independently verified')
    Data = @{
        SafeName = $name
        Pacli = ($session.Codes -join ',')
    }
}
