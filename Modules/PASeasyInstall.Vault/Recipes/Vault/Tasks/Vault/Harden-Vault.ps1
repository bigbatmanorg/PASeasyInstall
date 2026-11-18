# Mandatory vendor hardening followed by explicit independently measured RDP policy.
# 'StandardVault' is the on-premises architecture documented by the 15.0 CAVaultHarden.ps1 usage text.
param([Parameter(Mandatory=$true)][hashtable]$Settings)
$ErrorActionPreference='Stop'
# PAEASY_INCLUDE_VAULT_RDP
$rdpPolicy=Get-PASeasyVaultRdpPolicy $Settings
Set-PASeasyVaultRdpDeny
$dir=Join-Path $Settings.InstallRoot 'Server\Hardening'
$exe=Join-Path $dir 'CAVaultHarden.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'CAVaultHarden.exe missing'}
$arch=[string]$Settings.Hardening.Architecture
if($arch -ne 'StandardVault'){throw "Unsupported on-premises hardening architecture '$arch'"}
$args2=@($arch)
if($rdpPolicy.Allow){ $args2+=@('/AllowRDP',[string]([Net.IPAddress]::Parse([string]$Settings.Management.ControllerAddress))) }
$copy=Join-Path $Settings.AutomationRoot 'hardening.log'
if(Test-Path -LiteralPath $copy){throw 'Hardening already attempted on this host; inspect before any repeat'}
$vendorLog=Join-Path $dir 'logs\Hardening.log'
if(Test-Path -LiteralPath $vendorLog){Rename-Item -LiteralPath $vendorLog -NewName ('Hardening.'+(Get-Date -Format yyyyMMddHHmmss)+'.log')}
$rdpPolicyVerified=$false
try{
$p=Start-Process -FilePath $exe -ArgumentList $args2 -WorkingDirectory $dir -Wait -PassThru -WindowStyle Hidden
if(-not(Test-Path -LiteralPath $vendorLog)){throw "CAVaultHarden produced no log (exit $($p.ExitCode))"}
Copy-Item -LiteralPath $vendorLog -Destination $copy
$text=[IO.File]::ReadAllText($vendorLog)
if($p.ExitCode -ne 0){throw "CAVaultHarden exit $($p.ExitCode); see $copy"}
$missing=@()
foreach($m in @('Vault Configuration [StandardVault]','Windows Services successfully hardened.','Windows Network Devices successfully hardened.','Windows Group Policy successfully hardened.','Windows Local users successfully hardened.','Windows Audit policy successfully hardened.','Windows Firewall successfully hardened.','Windows Registry successfully hardened.','Hardening process was completed successfully!')){
    if(-not $text.Contains($m)){$missing+=$m}
}
if($missing.Count){throw ('hardening log lacks: '+($missing -join ' | '))}
Set-PASeasyVaultRdpPolicy $Settings
$rdpPolicyVerified=$true
[pscustomobject]@{Changed=$true;Message="CAVaultHarden $($args2 -join ' ') completed (exit 0, all 7 modules hardened)"}

}finally{if(-not $rdpPolicyVerified){Set-PASeasyVaultRdpDeny}}
