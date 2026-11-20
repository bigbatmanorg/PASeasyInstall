# Primary-only Vault configuration. Does NOT create or enable a DR user.
# Safe to inspect before retry, but the existing preflight still requires a clean machine.
# Preserve AdminPassword as an input because the Verify-Primary.ps1 postcondition
# needs authenticated PACLI; the configuration body itself does not use it.
param([Parameter(Mandatory=$true)][hashtable]$Settings,
      [Parameter(Mandatory=$true)][string]$AdminPassword)
$ErrorActionPreference='Stop'
$names=@('PrivateArk Database','PrivateArk Server','CyberArk Logic Container','Cyber-Ark Event Notification Engine')
$changed=$false
foreach($name in $names){
    $svc=Get-Service -DisplayName $name -ErrorAction Stop
    if ($svc.StartType -ne 'Automatic') { Set-Service -Name $svc.Name -StartupType Automatic; $changed=$true }
    if ($svc.Status -ne 'Running') { Start-Service -Name $svc.Name; $changed=$true }
}
[pscustomobject]@{Changed=$changed;Message='Primary Vault services configured (no DR user created)'}
