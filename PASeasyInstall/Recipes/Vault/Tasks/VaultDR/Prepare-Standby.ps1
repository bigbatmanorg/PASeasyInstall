# DR standby: Vault Server, ENE and Logic Container stopped/manual, database running (oracle prepare_standby).
param([Parameter(Mandatory = $true)][hashtable]$Settings)
$ErrorActionPreference = 'Stop'
foreach ($display in @('PrivateArk Server', 'Cyber-Ark Event Notification Engine', 'CyberArk Logic Container')) {
    $s = Get-Service -DisplayName $display -ErrorAction SilentlyContinue
    if ($s) {
        if ($s.Status -ne 'Stopped') { Stop-Service -Name $s.Name -Force }
        Set-Service -Name $s.Name -StartupType Manual
    }
}
$db = Get-Service -DisplayName 'PrivateArk Database' -ErrorAction Stop
Set-Service -Name $db.Name -StartupType Automatic
if ($db.Status -ne 'Running') { Start-Service -Name $db.Name }
[pscustomobject]@{Changed = $true; Message = 'DR Vault Server stopped for standby; database running' }
