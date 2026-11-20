# Functions only. RDP policy is independent of vendor firewall group/display names.
function Get-PASeasyVaultRdpPolicy {
    param([hashtable]$Settings)
    if($Settings.Hardening -isnot [Collections.IDictionary] -or -not $Settings.Hardening.Contains('AllowRDP') -or $Settings.Hardening.AllowRDP -isnot [bool]){throw 'Vault AllowRDP requires an explicit Boolean'}
    $ip=$null;$address=[string]$Settings.Management.ControllerAddress
    if([Net.IPAddress]::TryParse($address,[ref]$ip) -and $ip.IsIPv4MappedToIPv6){$ip=$ip.MapToIPv4();$address=$ip.ToString()}
    if(-not [Net.IPAddress]::TryParse($address,[ref]$ip) -or [Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any) -or $ip.IsIPv6Multicast -or ($ip.AddressFamily -eq 'InterNetwork' -and ($ip.GetAddressBytes()[0] -ge 224))){throw 'Vault RDP controller requires one unicast nonloopback IP'}
    $listener=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber -ErrorAction Stop
    if($listener.PortNumber -isnot [int] -or $listener.PortNumber -ne 3389){throw 'Custom or unknown RDP listener port is unsupported; no policy mutation performed'}
    [pscustomobject]@{Allow=$Settings.Hardening.AllowRDP;Controller=$ip.ToString()}
}
function Get-PASeasyVaultRdpRuleClass {
    param($Rule,$Port,$Service)
    $protocol=[string]$Port.Protocol
    $serviceName=[string]$Service.Service
    $term=($serviceName -ieq 'TermService')
    if($protocol -notin @('TCP','UDP','6','17','Any','256')){
        if($term){throw 'RDP service rule has unsupported protocol'}
        if($protocol -notmatch '^(ICMPv4|ICMPv6|1|58|[0-9]{1,3})$'){throw 'Firewall rule protocol is unknown'}
        return 'Other'
    }
    $differentService=($serviceName -and $serviceName -notin @('Any','*') -and -not $term)
    $ports=@($Port.LocalPort);if(-not $ports.Count){throw 'Firewall rule port filter missing'}
    $rdp=$false;$other=$false
    foreach($entry in $ports){
        $value=[string]$entry
        if($value -match '^\d{1,5}$'){
            $n=[int]$value;if($n -lt 1 -or $n -gt 65535){throw 'Firewall port invalid'}
            if($n -eq 3389){$rdp=$true}else{$other=$true}
        }elseif($value -match '^(\d{1,5})-(\d{1,5})$'){
            $low=[int]$matches[1];$high=[int]$matches[2]
            if($low -lt 1 -or $high -gt 65535 -or $low -gt $high){throw 'Firewall port range invalid'}
            if($low -le 3389 -and $high -ge 3389){throw 'Broad firewall port range includes RDP; reconcile without disabling unrelated access'}
            $other=$true
        }elseif($value -in @('Any','*')){
            if($term){$rdp=$true}elseif($differentService){$other=$true}else{throw 'Unrestricted service/port allow may expose RDP; reconcile without disabling unrelated access'}
        }else{throw 'Dynamic or unknown firewall port may expose RDP'}
    }
    if($term -and $other){throw 'TermService rule has unsupported nonstandard ports'}
    if($rdp -and $other){throw 'Mixed firewall ports include RDP and unrelated access'}
    if($rdp){return 'Rdp'}
    return 'Other'
}
function Get-PASeasyVaultRdpRules {
    $result=@()
    # Do not limit to the currently active profile: a stale profile rule can become active later.
    foreach($rule in @(Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Direction Inbound -Action Allow -ErrorAction Stop)){
        if([string]$rule.Enabled -notin @('True','False')){throw 'Firewall rule enabled state is unknown'}
        if([string]$rule.Enabled -eq 'False'){continue}
        $port=@($rule|Get-NetFirewallPortFilter -ErrorAction Stop)
        $service=@($rule|Get-NetFirewallServiceFilter -ErrorAction Stop)
        if($port.Count -ne 1 -or $service.Count -ne 1){throw 'Firewall filter cardinality is unsupported'}
        if((Get-PASeasyVaultRdpRuleClass $rule $port[0] $service[0]) -eq 'Rdp'){$result+= $rule}
    }
    $result
}
function Assert-PASeasyVaultRdpFirewallProfiles {
    $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    if($profiles.Count -ne 3){throw 'Effective firewall profile set is incomplete'}
    foreach($name in @('Domain','Private','Public')){
        $profile=@($profiles|Where-Object {[string]$_.Name -ceq $name})
        if($profile.Count -ne 1 -or [string]$profile[0].Enabled -ne 'True' -or [string]$profile[0].DefaultInboundAction -ne 'Block'){throw 'Effective firewall must be enabled with default inbound Block on every profile'}
    }
}
function Set-PASeasyVaultRdpDeny {
    # Policy first, but an error must never prevent attempting the other key.
    $failed=$false
    foreach($path in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services','HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server')){
        try{
            if(-not(Test-Path -LiteralPath $path)){New-Item -Path $path -Force -ErrorAction Stop|Out-Null}
            New-ItemProperty -LiteralPath $path -Name fDenyTSConnections -PropertyType DWord -Value 1 -Force -ErrorAction Stop|Out-Null
        }catch{$failed=$true}
    }
    if($failed){throw 'RDP deny containment is unconfirmed; both registry writes were attempted'}
}
function Test-PASeasyVaultRdpPolicy {
    param([hashtable]$Settings)
    $policy=Get-PASeasyVaultRdpPolicy $Settings
    Assert-PASeasyVaultRdpFirewallProfiles
    $want=if($policy.Allow){0}else{1}
    foreach($path in @('HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server','HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services')){
        $value=Get-ItemProperty -LiteralPath $path -Name fDenyTSConnections -ErrorAction Stop
        if($value.fDenyTSConnections -isnot [int] -or $value.fDenyTSConnections -ne $want){throw 'Effective local or policy RDP deny value does not match requested policy'}
    }
    try{$effective=@(Get-CimInstance -Namespace 'Root/CIMV2/TerminalServices' -ClassName Win32_TerminalServiceSetting -ErrorAction Stop)}
    catch{throw 'Effective Terminal Services provider unavailable: unsupported or NotTested'}
    if($effective.Count -ne 1){throw 'Effective Terminal Services policy singleton unavailable: unsupported or NotTested'}
    $allow=$effective[0].AllowTSConnections;$source=$effective[0].PolicySourceAllowTSConnections
    if(($allow -isnot [int] -and $allow -isnot [uint32]) -or $allow -notin @(0,1) -or ($source -isnot [int] -and $source -isnot [uint32]) -or $source -notin @(0,1)){throw 'Effective Terminal Services policy or source is unsupported'}
    $expectedAllow=if($policy.Allow){1}else{0}
    if($allow -ne $expectedAllow){throw 'Effective Terminal Services connection policy contradicts requested RDP policy'}
    $rules=@(Get-PASeasyVaultRdpRules)
    if(-not $policy.Allow){if($rules.Count){throw 'RDP inbound allow rule remains enabled'};return $true}
    $expected=@('PAeasy-Vault-RDP-Controller-TCP','PAeasy-Vault-RDP-Controller-UDP')
    if($rules.Count -ne 2){throw 'Controller RDP must have exactly the two owned protocol rules'}
    foreach($rule in $rules){
        if([string]$rule.Name -cnotin $expected -or [string]$rule.Group -cne 'PASeasyInstall Vault RDP'){throw 'Unowned RDP rule remains enabled'}
        $port=$rule|Get-NetFirewallPortFilter -ErrorAction Stop
        $address=$rule|Get-NetFirewallAddressFilter -ErrorAction Stop
        $service=$rule|Get-NetFirewallServiceFilter -ErrorAction Stop
        $protocol=if($rule.Name -like '*-TCP'){'TCP'}else{'UDP'}
        $allowed=if($protocol -eq 'TCP'){@('TCP','6')}else{@('UDP','17')}
        if([string]$port.Protocol -notin $allowed -or @($port.LocalPort).Count -ne 1 -or [string]$port.LocalPort -ne '3389' -or [string]$service.Service -ine 'TermService' -or @($address.RemoteAddress).Count -ne 1 -or [string]$address.RemoteAddress -cne $policy.Controller -or [string]$rule.Profile -ne 'Any'){throw 'Controller RDP rule is not exactly scoped to the requested listener and controller'}
    }
    $true
}
function Set-PASeasyVaultRdpPolicy {
    param([hashtable]$Settings)
    $policy=Get-PASeasyVaultRdpPolicy $Settings
    # Fail closed even if a later ambiguous firewall filter requires reconciliation.
    # For explicit allow, registry activation happens only after exact rules exist.
    Set-PASeasyVaultRdpDeny
    Assert-PASeasyVaultRdpFirewallProfiles
    $rules=@(Get-PASeasyVaultRdpRules) # Classify all BEFORE disabling any rule.
    $writable=@()
    foreach($rule in $rules){
        if([string]$rule.PolicyStoreSourceType -ne 'Local'){throw 'RDP allow originates outside writable local policy; registry denied, explicit policy reconciliation required'}
        # ActiveStore aggregates multiple provenance types. Resolve the exact
        # writable local instance; do not assume the aggregate has durable local ownership.
        $local=@(Get-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -ErrorAction Stop)
        if($local.Count -ne 1 -or [string]$local[0].Name -cne [string]$rule.Name -or [string]$local[0].Enabled -ne 'True' -or [string]$local[0].Direction -ne 'Inbound' -or [string]$local[0].Action -ne 'Allow'){throw 'RDP writable local rule could not be identified uniquely'}
        $port=@($local[0]|Get-NetFirewallPortFilter -ErrorAction Stop);$service=@($local[0]|Get-NetFirewallServiceFilter -ErrorAction Stop)
        if($port.Count -ne 1 -or $service.Count -ne 1 -or (Get-PASeasyVaultRdpRuleClass $local[0] $port[0] $service[0]) -ne 'Rdp'){throw 'RDP local rule differs from effective policy'}
        $writable+=$local[0]
    }
    foreach($rule in $writable){$rule|Disable-NetFirewallRule -ErrorAction Stop|Out-Null}
    foreach($name in @('PAeasy-Vault-RDP-Controller-TCP','PAeasy-Vault-RDP-Controller-UDP')){
        $old=@(Get-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction SilentlyContinue)
        foreach($rule in $old){if([string]$rule.Group -cne 'PASeasyInstall Vault RDP'){throw 'Owned RDP rule name collision'};$rule|Remove-NetFirewallRule -ErrorAction Stop|Out-Null}
    }
    if($policy.Allow){foreach($protocol in @('TCP','UDP')){
        New-NetFirewallRule -PolicyStore PersistentStore -Name ('PAeasy-Vault-RDP-Controller-'+$protocol) -DisplayName ('PASeasyInstall Vault controller RDP '+$protocol) -Group 'PASeasyInstall Vault RDP' -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol $protocol -LocalPort 3389 -RemoteAddress $policy.Controller -Service TermService -ErrorAction Stop|Out-Null
    }}
    try{
        $want=if($policy.Allow){0}else{1}
        foreach($path in @('HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server','HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services')){
            New-ItemProperty -LiteralPath $path -Name fDenyTSConnections -PropertyType DWord -Value $want -Force -ErrorAction Stop|Out-Null
        }
        $null=Test-PASeasyVaultRdpPolicy $Settings
    }catch{
        # Activation is never left permissive after a scope/readback/GPO race.
        try{Set-PASeasyVaultRdpDeny}catch{throw 'RDP verification failed and deny rollback is unconfirmed; both writes attempted; explicit reconciliation required'}
        throw 'RDP requested policy was not independently verified; registry returned to deny'
    }
}
