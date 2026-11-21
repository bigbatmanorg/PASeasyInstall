# Runs detached as SYSTEM (re-registering an endpoint restarts WinRM).
# Creates a WinRM endpoint usable ONLY by the configured local management account. Sessions run as a
# temporary virtual administrator account, so the vendor's UAC remote token filtering
# (FilterAdministratorToken=1, LocalAccountTokenFilterPolicy=0) never has to be weakened.
param([Parameter(Mandatory = $true)][hashtable]$Settings)
$ErrorActionPreference = 'Stop'
$name = [string]$Settings.Management.Endpoint
$user = [string]$Settings.Management.User
if ($name -notmatch '^[A-Za-z0-9.]+$') { throw 'Invalid endpoint name' }
$sid = (New-Object Security.Principal.NTAccount($env:COMPUTERNAME, $user)).Translate([Security.Principal.SecurityIdentifier]).Value
$dir = Join-Path $env:ProgramData 'PAExec'
if (-not(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$pssc = Join-Path $dir ($name + '.pssc')
New-PSSessionConfigurationFile -Path $pssc -SessionType Default -RunAsVirtualAccount -ExecutionPolicy RemoteSigned -Description 'PAExec PAS restricted management endpoint'
$sddl = "O:NSG:BAD:P(A;;GA;;;$sid)S:P(AU;FA;GA;;;WD)(AU;SA;GXGW;;;WD)"
if (Get-PSSessionConfiguration -Name $name -ErrorAction SilentlyContinue) { Unregister-PSSessionConfiguration -Name $name -Force -NoServiceRestart }
Register-PSSessionConfiguration -Name $name -Path $pssc -SecurityDescriptorSddl $sddl -Force -NoServiceRestart | Out-Null
Restart-Service WinRM -Force
Start-Sleep -Seconds 5
$c = Get-PSSessionConfiguration -Name $name
[pscustomobject]@{
    Changed = $true
    Message = "endpoint $name restricted to $user ($sid), RunAsVirtualAccount=$($c.RunAsVirtualAccount)"
}
