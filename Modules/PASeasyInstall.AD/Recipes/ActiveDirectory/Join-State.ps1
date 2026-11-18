# Nonsecret domain-join checkpoint. Only SYSTEM/Administrators can write it.
function Assert-PASeasyJoinPath {
    param([string]$Path)
    $trusted=@('S-1-5-18','S-1-5-32-544')
    try {$trusted+=([Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value}catch{}
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Domain join checkpoint path contains a reparse point'}
            $acl=Get-Acl -LiteralPath $cursor
            if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Domain join checkpoint path has an untrusted owner'}
            foreach($rule in @($acl.Access | Where-Object {$cursor -eq [IO.Path]::GetFullPath($Path)})){
                if($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership')){
                    $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                    if($sid -notin $trusted -and $sid -ne 'S-1-3-0'){throw 'Domain join checkpoint path permits untrusted writes'}
                }
            }
        }
        $next=Split-Path $cursor -Parent;if($next -eq $cursor){break};$cursor=$next
    }
}
function Get-PASeasyJoinMarkerPath {
    param([hashtable]$Settings)
    if(-not $Settings.StageRoot -or -not [IO.Path]::IsPathRooted([string]$Settings.StageRoot)){throw 'Domain join requires an absolute protected StageRoot'}
    return Join-Path ([string]$Settings.StageRoot) 'domain-join.json'
}
function Test-PASeasyJoinPending {
    param([hashtable]$Settings)
    $path=Get-PASeasyJoinMarkerPath $Settings
    Assert-PASeasyJoinPath $path
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $false}
    $record=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    return ($record.schemaVersion -eq 1 -and $record.domain -ieq [string]$Settings.Domain -and $record.bootUtc -eq $boot -and $record.hasSucceeded -is [bool] -and $record.hasSucceeded -and $record.computerName -ieq $env:COMPUTERNAME)
}
function Set-PASeasyJoinPending {
    param([hashtable]$Settings,[string]$BootUtc,[bool]$HasSucceeded=$true)
    $path=Get-PASeasyJoinMarkerPath $Settings
    $root=Split-Path $path -Parent
    Assert-PASeasyJoinPath $root
    if(-not(Test-Path -LiteralPath $root)){New-Item -Path $root -ItemType Directory -ErrorAction Stop | Out-Null}
    $acl=Get-Acl -LiteralPath $root
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @($acl.Access)){$acl.RemoveAccessRuleSpecific($rule)}
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
    Assert-PASeasyJoinPath $path
    $record=@{schemaVersion=1;domain=[string]$Settings.Domain;bootUtc=$BootUtc;hasSucceeded=$HasSucceeded;computerName=$env:COMPUTERNAME;submittedUtc=[DateTime]::UtcNow.ToString('o')}
    $record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
}
function Set-PASeasyJoinDns {
    param([hashtable]$Settings)
    $servers=@($Settings.DnsServers | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)})
    if(-not $servers.Count){throw 'Explicit AD DNS servers are required for domain join'}
    foreach($server in $servers){
        $address=$null
        if(-not [Net.IPAddress]::TryParse([string]$server,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::Broadcast)){throw 'Domain join DNS servers must be valid IPv4 addresses'}
    }
    $index=0
    if($Settings.InterfaceIndex){
        $index=[int]$Settings.InterfaceIndex
        if($index -lt 1){throw 'Invalid domain join InterfaceIndex'}
        $adapter=@(Get-NetAdapter -InterfaceIndex $index -ErrorAction Stop | Where-Object Status -eq 'Up')
    }else{
        $adapter=@(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {$_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up'})
        if($adapter.Count -eq 1){$index=[int]$adapter[0].InterfaceIndex}
    }
    if($adapter.Count -ne 1 -or $index -lt 1){throw 'Domain join requires one active default-route adapter or an explicit InterfaceIndex'}
    $current=@((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
    if(($current -join ',') -ne ($servers -join ',')){Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $servers -ErrorAction Stop}
    Clear-DnsClientCache -ErrorAction Stop
}
