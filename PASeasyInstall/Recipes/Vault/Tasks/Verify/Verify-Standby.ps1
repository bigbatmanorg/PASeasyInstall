param([Parameter(Mandatory=$true)][hashtable]$Settings)
$issues=@()
$db=Get-Service -DisplayName 'PrivateArk Database' -ErrorAction SilentlyContinue
$srv=Get-Service -DisplayName 'PrivateArk Server' -ErrorAction SilentlyContinue
if(-not $db -or $db.Status -ne 'Running'){$issues+='DR database not running'}
if(-not $srv -or $srv.Status -ne 'Stopped' -or $srv.StartType -ne 'Manual'){$issues+='DR Vault Server must be stopped/manual in standby'}
[pscustomobject]@{Passed=($issues.Count -eq 0);Message=($issues -join ';');Evidence=@('DR database running, Vault Server stopped (Manual)')}
