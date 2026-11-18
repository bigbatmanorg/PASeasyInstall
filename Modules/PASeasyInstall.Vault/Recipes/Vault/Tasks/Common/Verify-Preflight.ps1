param([Parameter(Mandatory=$true)][hashtable]$Settings,[ValidateSet('Primary','DR')][string]$Role='Primary')
$expected=$Settings.PrimaryIP; if($Role -eq 'DR'){$expected=$Settings.DRIP}
$mine=@(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $_.IPAddress })
[pscustomobject]@{Passed=($mine -contains $expected);Message="addresses $($mine -join ',')";Evidence=@("$env:COMPUTERNAME owns $expected")}
