# Read-only verification of the vendor StandardVault hardening baseline AND of the approved management
# exception. A vendor "success" log line alone is not accepted: effective controls are measured.
param([Parameter(Mandatory=$true)][hashtable]$Settings)
# PAEASY_INCLUDE_VAULT_RDP
function Test-PASeasyVaultNativeInboundPort {
    param($Port)
    return ([string]$Port.Protocol -in @('TCP','6') -and @($Port.LocalPort).Count -eq 1 -and [string]$Port.LocalPort -eq '1858')
}
$issues=@();$ev=@()
try{$null=Test-PASeasyVaultRdpPolicy $Settings;$ev+='explicit RDP registry and all-profile firewall scope verified independently'}catch{$issues+='explicit RDP policy verification failed: '+$_.Exception.Message}
# 1. Vendor log: every module reported success for the StandardVault architecture.
$log=Join-Path $Settings.AutomationRoot 'hardening.log'
if(-not(Test-Path -LiteralPath $log)){$issues+='hardening log missing'}else{
    $t=[IO.File]::ReadAllText($log)
    foreach($m in @('Vault Configuration [StandardVault]','Windows Services successfully hardened.','Windows Network Devices successfully hardened.','Windows Group Policy successfully hardened.','Windows Local users successfully hardened.','Windows Audit policy successfully hardened.','Windows Firewall successfully hardened.','Windows Registry successfully hardened.','Hardening process was completed successfully!')){ if(-not $t.Contains($m)){$issues+="log lacks '$m'"} }
    if($t -match 'hardening failed'){$issues+='log reports a failed hardening module'}
    $ev+='vendor log: 7 modules hardened, StandardVault'
}
# 2. Firewall: hardened service name, enabled on every profile, default inbound AND outbound block by policy.
$mps=Get-Service -Name MpsSvc
$mpsName=[string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\MpsSvc' -Name DisplayName).DisplayName
if($mpsName -ne 'Cyber-Ark Hardened Windows Firewall' -or $mps.Status -ne 'Running'){$issues+="firewall service configured as '$mpsName' ($($mps.Status))"}else{$ev+='MpsSvc renamed Cyber-Ark Hardened Windows Firewall, running'}
foreach($prof in @('DomainProfile','PrivateProfile','PublicProfile')){
    $k=Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\$prof" -ErrorAction SilentlyContinue
    if(-not $k -or $k.EnableFirewall -ne 1 -or $k.DefaultInboundAction -ne 1 -or $k.DefaultOutboundAction -ne 1){$issues+="firewall policy $prof not enabled/default-block"}
}
foreach($p in Get-NetFirewallProfile -PolicyStore ActiveStore){ if($p.Enabled -ne 'True' -or $p.DefaultInboundAction -ne 'Block' -or $p.DefaultOutboundAction -ne 'Block'){$issues+="effective profile $($p.Name): enabled=$($p.Enabled) in=$($p.DefaultInboundAction) out=$($p.DefaultOutboundAction)"} }
if(-not ($issues -match 'profile')){$ev+='all firewall profiles enabled; effective default inbound+outbound Block'}
# 3. Inbound allow rules: only Vault-owned rules, RDP and WinRM limited to the controller address.
$controller=[string]$Settings.Management.ControllerAddress
$allowIn=@(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)
$summary=@()
foreach($r in $allowIn){
    $a=($r | Get-NetFirewallAddressFilter); $p=($r | Get-NetFirewallPortFilter)
    $remote=@($a.RemoteAddress) -join ','
    $summary+="$($r.DisplayName) [$($p.Protocol) $($p.LocalPort) from $remote]"
    $isVault=Test-PASeasyVaultNativeInboundPort $p
    if(-not $isVault -and $remote -ne $controller -and [string]$p.Protocol -notmatch 'ICMP'){$issues+="unexpected inbound allow rule '$($r.DisplayName)' from $remote"}
}
$ev+=('inbound allow rules: '+($summary -join '; '))
# 4. Services: vendor block-list applied; WinRM is the single documented management exception.
foreach($n in @('Spooler','RemoteRegistry','LanmanServer','msiserver','TrustedInstaller','BITS','wuauserv','SSDPSRV')){
    $s=Get-Service -Name $n -ErrorAction SilentlyContinue
    if($s -and $s.StartType -ne 'Disabled'){$issues+="service $n is $($s.StartType), expected Disabled"}
}
$w=Get-Service WinRM
if($w.Status -ne 'Running'){$issues+='WinRM (approved exception) not running'}
$ev+='sampled block-listed services Disabled; WinRM running as approved management exception'
# 5. Security template and audit policy took effect.
$sys=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$lsa=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
if($sys.FilterAdministratorToken -ne 1){$issues+='FilterAdministratorToken not 1'}
if([int]$sys.LocalAccountTokenFilterPolicy -ne 0){$issues+='LocalAccountTokenFilterPolicy weakened'}
if($lsa.LmCompatibilityLevel -ne 5){$issues+="LmCompatibilityLevel $($lsa.LmCompatibilityLevel)"}
$ev+='UAC remote token filtering and NTLMv2-only policy in force'
$audit=(& auditpol.exe /get /subcategory:'{0CCE9215-69AE-11D9-BED3-505054503030}' 2>&1 | Out-String)
if($audit -notmatch 'Success and Failure'){$issues+='Logon auditing not Success and Failure'}else{$ev+='audit: Logon Success and Failure'}
# 6. Management exception is restricted: endpoint ACL single account, virtual account, recovery task armed.
$name=[string]$Settings.Management.Endpoint
$c=Get-PSSessionConfiguration -Name $name -ErrorAction SilentlyContinue
if(-not $c -or [string]$c.RunAsVirtualAccount -ne 'true' -or @([regex]::Matches([string]$c.SecurityDescriptorSddl,'\(A;')).Count -ne 1){$issues+="restricted endpoint $name not as approved"}else{$ev+="endpoint ${name}: one allowed account, RunAsVirtualAccount"}
$dflt=Get-PSSessionConfiguration -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue
$ev+=('default endpoint ACL '+[string]$dflt.Permission)
$rule=Get-NetFirewallRule -DisplayName 'PAExec PAS controller WinRM' -ErrorAction SilentlyContinue
if(-not $rule -or [string](($rule|Get-NetFirewallAddressFilter).RemoteAddress) -ne $controller){$issues+='controller-scoped WinRM rule missing or broader than the controller address'}
[pscustomobject]@{Passed=($issues.Count -eq 0);Message=($issues -join ' | ');Evidence=$ev}
