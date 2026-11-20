param([Parameter(Mandatory=$true)][hashtable]$Settings)
$name=[string]$Settings.Management.Endpoint
$c=Get-PSSessionConfiguration -Name $name -ErrorAction SilentlyContinue
$sid=(New-Object Security.Principal.NTAccount($env:COMPUTERNAME,[string]$Settings.Management.User)).Translate([Security.Principal.SecurityIdentifier]).Value
$ok=($c -and $c.Enabled -and [string]$c.RunAsVirtualAccount -eq 'true' -and $c.SecurityDescriptorSddl -match "\(A;;GA;;;$sid\)" -and @([regex]::Matches($c.SecurityDescriptorSddl,'\(A;')).Count -eq 1)
$me=[Security.Principal.WindowsIdentity]::GetCurrent()
[pscustomobject]@{Passed=[bool]$ok;Message="current session identity $($me.Name)";Evidence=@("endpoint $name SDDL $($c.SecurityDescriptorSddl)","RunAsVirtualAccount=$($c.RunAsVirtualAccount)")}
