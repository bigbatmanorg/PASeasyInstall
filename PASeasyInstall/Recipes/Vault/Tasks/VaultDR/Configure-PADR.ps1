# Manual standby. FailoverMode is observed state, NOT the automatic failover policy.
param([Parameter(Mandatory = $true)][hashtable]$Settings)
$ErrorActionPreference = 'Stop'
# PAEASY_INCLUDE_VAULT_PADR
Assert-PASeasyPadrNotActivated $Settings
$service = Get-Service -DisplayName 'CyberArk Vault Disaster Recovery' -ErrorAction Stop
# Keep an interrupted policy write from restarting a formerly automatic service after boot.
Set-Service -Name $service.Name -StartupType Manual
if ($service.Status -ne 'Stopped') { Stop-Service -Name $service.Name -Force -ErrorAction Stop }
# Re-read only after quiescence: never clear a state written by a racing native failover.
Assert-PASeasyPadrNotActivated $Settings
$conf = Join-Path $Settings.InstallRoot 'PADR\Conf'
$changed = Set-PASeasyPadrIniValue (Join-Path $conf 'PADR.ini') 'EnableFailover' 'No'
$changed = (Set-PASeasyPadrIniValue (Join-Path $conf 'Vault.ini') 'ADDRESS' ([Net.IPAddress]::Parse([string]$Settings.PrimaryIP).ToString())) -or $changed
Assert-PASeasyPadrManualStandby $Settings
Set-Service -Name $service.Name -StartupType Automatic
Start-Service -Name $service.Name -ErrorAction Stop
Assert-PASeasyPadrManualStandby $Settings
$service = Get-Service -Name $service.Name -ErrorAction Stop
if ($service.Status -ne 'Running' -or $service.StartType -ne 'Automatic') { throw 'PADR did not reach running/automatic standby' }
[pscustomobject]@{
    Changed = $changed
    Message = 'PADR manual standby: EnableFailover=No; FailoverMode=No; primary address verified; service running'
}
