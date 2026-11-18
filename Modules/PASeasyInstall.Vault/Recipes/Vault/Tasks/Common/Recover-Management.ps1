# Staged management recovery. Runs as SYSTEM after detached installer/hardening attempts and at every boot
# while armed. It restores ONLY: the WinRM service, an HTTP.sys listener on this host's approved address,
# an inbound TCP rule from the single approved controller address and the restricted management endpoint
# (plus any outbound rule explicitly listed in the policy; none by default). It never disables the firewall.
$ErrorActionPreference='Stop'
$policyPath='C:\Cyberark\Automation\management-policy.json'
if(-not(Test-Path -LiteralPath $policyPath)){throw 'Management policy missing; refusing to open anything'}
$policy=Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$controller=[string]([Net.IPAddress]::Parse([string]$policy.ControllerAddress))
$port=[int]$policy.WinRMPort
if($port -notin @(5985,5986)){throw 'Management port not approved'}
# At boot this can run before the network is configured: wait for the approved address first.
$deadline=(Get-Date).AddMinutes(5)
do {
    $local=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { @($policy.AllowedTargetIPs) -contains $_.IPAddress -and $_.AddressState -eq 'Preferred' } | ForEach-Object { $_.IPAddress })
    if($local.Count -eq 0){Start-Sleep -Seconds 5}
} while($local.Count -eq 0 -and (Get-Date) -lt $deadline)
if($local.Count -eq 0){throw 'No local address matches the approved management policy'}
$actions=@()
# An explicit HTTP.sys listen list makes WinRM fail at boot (error 1214) when it starts before the address is
# up. Let the service control manager restart WinRM after such a failure.
$fail=(& sc.exe qfailure WinRM | Out-String)
if($fail -notmatch 'RESTART'){ & sc.exe failure WinRM reset= 86400 actions= restart/30000/restart/60000/restart/120000 | Out-Null; $actions+='WinRM restart-on-failure' }
$svc=Get-Service WinRM
if($svc.StartType -ne 'Automatic'){Set-Service WinRM -StartupType Automatic;$actions+='WinRM startup Automatic'}
if((Get-Service WinRM).Status -ne 'Running'){Start-Service WinRM;$actions+='WinRM started'}
# Vault setup can leave HTTP.sys listening on loopback only. An empty list means "all addresses".
$listen=(& netsh.exe http show iplisten | Out-String)
if($listen -match '\d+\.\d+\.\d+\.\d+|::'){
    foreach($ip in $local){
        if($listen -notmatch [regex]::Escape($ip)){
            $r=& netsh.exe http add iplisten "ipaddress=$ip" 2>&1
            if($LASTEXITCODE -ne 0 -and ($r -join ' ') -notmatch 'already'){throw "Cannot add HTTP.sys listener for $ip"}
            $actions+="HTTP.sys iplisten $ip"
        }
    }
    Restart-Service WinRM -Force
}
$rule='PAExec PAS controller WinRM'
$existing=Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
$ok=$false
if($existing){ $f=$existing | Get-NetFirewallAddressFilter; $p=$existing | Get-NetFirewallPortFilter; $ok=(@($existing).Count -eq 1 -and [string]$f.RemoteAddress -eq $controller -and [string]$p.LocalPort -eq [string]$port -and $existing.Enabled -eq 'True') }
if(-not $ok){
    if($existing){$existing | Remove-NetFirewallRule}
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress $controller -Profile Any | Out-Null
    $actions+="inbound TCP $port from $controller"
}
foreach($o in @($policy.Outbound)){
    if(-not $o){continue}
    $addr=[string]([Net.IPAddress]::Parse([string]$o.RemoteAddress))
    $e=Get-NetFirewallRule -DisplayName ([string]$o.Name) -ErrorAction SilentlyContinue
    if(-not $e){
        New-NetFirewallRule -DisplayName ([string]$o.Name) -Direction Outbound -Action Allow -Protocol TCP -RemotePort ([int]$o.Port) -RemoteAddress $addr -Profile Any | Out-Null
        $actions+="outbound TCP $($o.Port) to $addr"
    }
}
if(-not (Get-PSSessionConfiguration -Name ([string]$policy.Endpoint) -ErrorAction SilentlyContinue)){ throw "Restricted endpoint $($policy.Endpoint) missing; re-run the management-endpoint step" }
$deadline=(Get-Date).AddSeconds(60)
while((Get-Date) -lt $deadline -and (Get-Service WinRM).Status -ne 'Running'){Start-Sleep -Seconds 2}
if((Get-Service WinRM).Status -ne 'Running'){throw 'WinRM is not running after recovery'}
$stamp=[DateTime]::UtcNow.ToString('o')+' '+(($actions | Where-Object { $_ }) -join '; ')
Add-Content -LiteralPath 'C:\Cyberark\Automation\management-recovery.log' -Value $stamp
Write-Output "management recovery complete: $(@($actions).Count) change(s)"
exit 0
