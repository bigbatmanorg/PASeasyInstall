# Windows remote domain join for eligible component hosts (never Vault, DR, or DC).
[CmdletBinding()]
param([ValidateSet('Check','Join','Verify')][string]$Stage,[hashtable]$Settings,[string]$DomainPassword='')
$ErrorActionPreference='Stop';$domain=[string]$Settings.Domain
. (Join-Path $PSScriptRoot 'Join-State.ps1')
if($domain -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{2,252}$'){throw 'Invalid AD DNS domain'}
$cs=Get-CimInstance Win32_ComputerSystem
if($cs.DomainRole -in @(4,5)){throw 'A domain controller cannot be a domain-join target'}
if(@(Get-Service -Name 'PrivateArk Server','CyberArk Vault Disaster Recovery' -ErrorAction SilentlyContinue).Count){throw 'Vault and DR hosts must remain workgroup members; refusing domain join'}
if($cs.PartOfDomain){
    if($cs.Domain -ine $domain){throw "Host joined to another domain: $($cs.Domain)"}
    if($Stage -eq 'Verify'){
        if(-not(Test-ComputerSecureChannel -ErrorAction Stop)){throw 'Domain membership exists but the machine secure channel is broken'}
        $srv=@(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.'+$domain) -Type SRV -ErrorAction Stop | Where-Object {$_.Type -eq 'SRV'})
        if(-not $srv.Count){throw 'Domain LDAP SRV records unavailable after join'}
        return [pscustomobject]@{Changed=$false;Message="Joined $domain with verified machine secure channel and LDAP SRV"}
    }
    return [pscustomobject]@{Changed=$false;Message="Already joined to $domain"}
}
if($Stage -eq 'Check'){
    Set-PASeasyJoinDns $Settings
    Resolve-DnsName -Name $domain -ErrorAction Stop | Out-Null
    $srv=@(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.'+$domain) -Type SRV -ErrorAction Stop | Where-Object {$_.Type -eq 'SRV'})
    if(-not $srv.Count){throw 'Domain LDAP SRV records unavailable before join'}
    return [pscustomobject]@{Changed=$false;Message='Domain DNS resolves'}
}
if($Stage -eq 'Verify'){throw "Domain join not complete: $domain"}
if(Test-PASeasyJoinPending $Settings){return [pscustomobject]@{Changed=$false;Message='Successful domain join already submitted this boot; reboot required'}}
if(Test-Path -LiteralPath (Get-PASeasyJoinMarkerPath $Settings)){throw 'An earlier domain join submission exists with unresolved membership; reconcile target before retry'}
if(-not $DomainPassword){throw 'DomainJoinPassword secret required'}
$user=[string]$Settings.JoinUser
if(-not $user){throw 'Domain join user not configured'}
$password=ConvertTo-SecureString -String $DomainPassword -AsPlainText -Force
$cred=[Management.Automation.PSCredential]::new($user,$password)
Set-PASeasyJoinDns $Settings
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
# Fail closed on checkpoint path BEFORE invoking native join.
Assert-PASeasyJoinPath (Get-PASeasyJoinMarkerPath $Settings)
# An intent record survives a killed native call; it never proves success but blocks blind retry.
Set-PASeasyJoinPending -Settings $Settings -BootUtc $boot -HasSucceeded $false
$result=Add-Computer -DomainName $domain -Credential $cred -Force -PassThru -ErrorAction Stop
if($result.HasSucceeded -isnot [bool] -or -not $result.HasSucceeded){throw 'Add-Computer did not confirm successful domain join submission; reconcile target before retry'}
Set-PASeasyJoinPending -Settings $Settings -BootUtc $boot
return [pscustomobject]@{Changed=$true;Message="Joined $domain; reboot required"}
