# Windows Server 2022 Active Directory lab forest creation. Never invoked on existing DC.
[CmdletBinding()]
param([ValidateSet('Preflight','Install','Verify')][string]$Stage,
      [hashtable]$Settings,[string]$SafeModePassword='',
      [string]$PAExecAttemptDirectory='')
$ErrorActionPreference='Stop'
$domain=[string]$Settings.Domain
if($domain -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{2,252}$'){throw 'Invalid AD DNS domain'}
function Get-DomainIdentity {
    $cs=Get-CimInstance Win32_ComputerSystem
    return @{Joined=[bool]$cs.PartOfDomain;Domain=[string]$cs.Domain;Role=[int]$cs.DomainRole}
}
function Get-ADStatus {
    $id=Get-DomainIdentity
    if($id.Role -in @(4,5) -and $id.Domain -ieq $domain){return $true}
    return $false
}
function Assert-PASeasyADPromotionTarget {
    if(@(Get-Service -Name 'PrivateArk Server','CyberArk Vault Disaster Recovery' -ErrorAction SilentlyContinue).Count){
        throw 'Vault and DR hosts cannot be promoted to domain controllers'
    }
}
function Get-PASeasyADPromotionRebootScript {
    $code={
        [CmdletBinding()]param([Parameter(Mandatory)][string]$Checkpoint)
        $ErrorActionPreference='Stop'
        $record=Get-Content -LiteralPath $Checkpoint -Raw | ConvertFrom-Json
        if($record.schemaVersion -ne 1 -or $record.attemptId -notmatch '^[a-f0-9]{32}$' -or $record.taskName -ne ('PAeasy-AD-Promotion-Reboot-'+$record.attemptId)){throw 'Invalid AD reboot checkpoint identity'}
        if([int]$record.waitSeconds -notin 1..3600 -or [int]$record.graceSeconds -notin 0..300){throw 'Invalid AD reboot checkpoint time bounds'}
        function Read-Boot { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
        function Remove-Bootstrap { Unregister-ScheduledTask -TaskName $record.taskName -TaskPath '\PAExec\' -Confirm:$false -ErrorAction SilentlyContinue }
        if((Read-Boot) -ne [string]$record.bootUtc){Remove-Bootstrap;return}
        $deadline=[DateTime]::UtcNow.AddSeconds([int]$record.waitSeconds)
        $terminal=$null
        do {
            if((Read-Boot) -ne [string]$record.bootUtc){Remove-Bootstrap;return}
            if(Test-Path -LiteralPath $record.statusPath){
                $observed=Get-Content -LiteralPath $record.statusPath -Raw | ConvertFrom-Json
                if($observed.attemptId -ne $record.attemptId -or $observed.bootUtc -ne $record.bootUtc){throw 'AD reboot status does not match immutable attempt and boot'}
                if($observed.state -eq 'Succeeded'){$terminal=$observed;break}
                if($observed.state -in @('Failed','Interrupted','NotStarted')){Remove-Bootstrap;return}
            }
            Start-Sleep -Seconds 2
        } while([DateTime]::UtcNow -lt $deadline)
        if(-not $terminal){throw 'AD promotion has no confirmed successful terminal outcome; reboot not authorized'}
        $promotion=Get-Content -LiteralPath $record.promotionMarker -Raw | ConvertFrom-Json
        if($promotion.schemaVersion -ne 2 -or $promotion.attemptId -ne $record.attemptId -or $promotion.domain -ine $record.domain -or $promotion.bootUtc -ne $record.bootUtc){throw 'AD promotion marker does not match successful attempt'}
        $published=[DateTimeOffset]::Parse([string]$terminal.endedUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $grace=$published.AddSeconds([int]$record.graceSeconds)
        while([DateTime]::UtcNow -lt $grace){
            if((Read-Boot) -ne [string]$record.bootUtc){Remove-Bootstrap;return}
            Start-Sleep -Seconds 2
        }
        if((Read-Boot) -ne [string]$record.bootUtc){Remove-Bootstrap;return}
        $claim=Join-Path (Split-Path -Parent $Checkpoint) 'reboot-requested'
        try {$stream=[IO.File]::Open($claim,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose()}
        catch [IO.IOException] {if(Test-Path -LiteralPath $claim){return};throw}
        & shutdown.exe /r /t 5 /d p:4:1 /c 'PASeasyInstall confirmed AD promotion recovery reboot'
        if($LASTEXITCODE -ne 0){throw "AD recovery shutdown failed with exit $LASTEXITCODE; reconcile before retry"}
        Write-Output 'AD promotion recovery reboot requested from original successful attempt'
    }
    return $code.ToString()
}
function Register-PASeasyADPromotionReboot {
    param([hashtable]$Settings,[string]$AttemptDirectory,[string]$Domain)
    if(-not $AttemptDirectory){throw 'AD promotion requires the durable attempt directory context'}
    $attempt=[IO.Path]::GetFullPath($AttemptDirectory).TrimEnd('\')
    $attemptId=Split-Path $attempt -Leaf
    if($attemptId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid durable AD attempt identity'}
    $root=Split-Path (Split-Path $attempt -Parent) -Parent
    if((Split-Path (Split-Path $attempt -Parent) -Leaf) -ne 'attempts'){throw 'Invalid AD attempt directory layout'}
    $statusPath=Join-Path $attempt 'status.json'
    $status=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if($status.state -ne 'Running' -or $status.attemptId -ne $attemptId){throw 'AD promotion requires a running matching durable attempt'}
    $componentRoot=[IO.Path]::GetFullPath([string]$Settings.StageRoot).TrimEnd('\')
    if(-not $componentRoot.StartsWith(($root+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'AD recovery root must remain within the protected stage root'}
    $trusted=@('S-1-5-18','S-1-5-32-544',(Get-Acl -LiteralPath $attempt).GetOwner([Security.Principal.SecurityIdentifier]).Value)
    try {$trusted+=([Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value}catch{}
    $ancestor=$componentRoot
    while($ancestor){
        if(Test-Path -LiteralPath $ancestor){
            $item=Get-Item -LiteralPath $ancestor -Force
            if(-not $item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AD recovery path contains a non-directory or reparse ancestor'}
            if((Get-Acl -LiteralPath $ancestor).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'AD recovery path has an untrusted ancestor owner'}
        }
        $next=Split-Path $ancestor -Parent;if($next -eq $ancestor){break};$ancestor=$next
    }
    $current=$root
    $relative=$componentRoot.Substring($root.Length).TrimStart('\').Split('\')
    foreach($part in @($relative)+@('promotion-recovery',$attemptId)){
        $current=Join-Path $current $part
        if(-not(Test-Path -LiteralPath $current)){New-Item -Path $current -ItemType Directory -ErrorAction Stop | Out-Null}
        $acl=Get-Acl -LiteralPath $current
        if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'AD recovery directory owner changed while staging'}
        $acl.SetAccessRuleProtection($true,$false)
        foreach($rule in @($acl.Access)){$acl.RemoveAccessRuleSpecific($rule)}
        foreach($sid in @('S-1-5-18','S-1-5-32-544')){
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
        }
        Set-Acl -LiteralPath $current -AclObject $acl -ErrorAction Stop
    }
    $scriptPath=Join-Path $current 'reboot.ps1';$checkpoint=Join-Path $current 'checkpoint.json'
    if(Test-Path -LiteralPath $checkpoint){throw 'AD reboot checkpoint already exists; reconcile original attempt'}
    $taskName='PAeasy-AD-Promotion-Reboot-'+$attemptId
    $record=@{schemaVersion=1;attemptId=$attemptId;taskName=$taskName;domain=$Domain;bootUtc=[string]$status.bootUtc;statusPath=$statusPath;promotionMarker=(Join-Path $componentRoot 'forest-promotion.done');waitSeconds=2400;graceSeconds=45;createdUtc=[DateTime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($scriptPath,(Get-PASeasyADPromotionRebootScript),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($checkpoint,($record|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$scriptPath+'" -Checkpoint "'+$checkpoint+'"'
    $action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $current
    $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $triggers=@((New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(45))),(New-ScheduledTaskTrigger -AtStartup))
    $taskSettings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(45)) -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -TaskPath '\PAExec\' -Action $action -Trigger $triggers -Principal $principal -Settings $taskSettings -Force | Out-Null
    return $record
}

if($Stage -eq 'Preflight'){
    Assert-PASeasyADPromotionTarget
    if((Get-CimInstance Win32_OperatingSystem).ProductType -notin @(2,3)){throw 'AD DS requires Windows Server'}
    $identity=Get-DomainIdentity
    if($identity.Joined -and -not(Get-ADStatus)){throw 'Host belongs to another domain; refusing forest promotion'}
    $routes=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric)
    if(-not $routes.Count){throw 'AD requires an explicit IPv4 route'}
    $network=Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $routes[0].InterfaceIndex -ErrorAction Stop
    if($network.Dhcp -ne 'Disabled'){throw 'AD forest creation requires static IPv4 addressing; DHCP is not qualified'}
    $addresses=@(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $network.InterfaceIndex -ErrorAction Stop | Where-Object {$_.AddressState -eq 'Preferred'})
    if($Settings.Contains('Address') -and [string]$Settings.Address -notin @($addresses.IPAddress)){throw 'AD target address does not match approved static IPv4 identity'}
    $dns=@((Get-DnsClientServerAddress -InterfaceIndex $network.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
    if(-not @($dns | Where-Object {$_ -eq '127.0.0.1' -or $_ -in @($addresses.IPAddress)}).Count){throw 'New AD DNS must resolve through the selected local DC address'}
    $featureChanged=$false
    if(-not(Get-Command Test-ADDSForestInstallation -ErrorAction SilentlyContinue)){
        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -ErrorAction Stop | Out-Null
        $featureChanged=$true
    }
    if(-not(Get-Command Test-ADDSForestInstallation -ErrorAction SilentlyContinue)){
        Import-Module ADDSDeployment -ErrorAction Stop
    }
    if(-not(Get-Command Test-ADDSForestInstallation -ErrorAction SilentlyContinue)){throw 'ADDSDeployment prereq cmdlet unavailable'}
    return [pscustomobject]@{Changed=$featureChanged;Message='Static IPv4/DNS and Active Directory prerequisites ready'}
}
if($Stage -eq 'Install'){
    Assert-PASeasyADPromotionTarget
    if(Get-ADStatus){return [pscustomobject]@{Changed=$false;Message='Matching domain controller already installed';Data=@{RebootRequired=$false}}}
    if(-not $SafeModePassword){throw 'ADSafeMode secret is required for forest creation'}
    $identity=Get-DomainIdentity
    if($identity.Joined){throw 'Cannot create new forest on domain-joined host'}
    $password=ConvertTo-SecureString -String $SafeModePassword -AsPlainText -Force
    Import-Module ADDSDeployment -ErrorAction Stop
    $netbios=$domain.Split('.')[0].ToUpperInvariant()
    if($Settings.Options -and $Settings.Options.Contains('domainNetbios')){$netbios=[string]$Settings.Options.domainNetbios}
    if($netbios -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$'){throw 'Invalid AD NetBIOS domain name'}
    $check=@(Test-ADDSForestInstallation -DomainNetbiosName $netbios -DomainName $domain -InstallDns -SafeModeAdministratorPassword $password -Force -ErrorAction Stop)
    $blocking=@($check|Where-Object{$_.PSObject.Properties['Severity'] -and $_.Severity -eq 'Error'})
    if($blocking.Count){throw 'AD forest prerequisite test reported errors; see target installation logs'}
    # Register before mutation. The bootstrap waits for this SAME runner's terminal success
    # plus promotion marker, then gives the controller a grace period before its own reboot.
    $recovery=Register-PASeasyADPromotionReboot -Settings $Settings -AttemptDirectory $PAExecAttemptDirectory -Domain $domain
    Install-ADDSForest -DomainNetbiosName $netbios -DomainName $domain -InstallDns -SafeModeAdministratorPassword $password -NoRebootOnCompletion -Force -ErrorAction Stop | Out-Null
    $marker=Join-Path ([string]$Settings.StageRoot) 'forest-promotion.done'
    New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force | Out-Null
    $promoted=@{schemaVersion=2;domain=$domain;netbios=$netbios;attemptId=$recovery.attemptId;bootUtc=$recovery.bootUtc;completedUtc=[DateTime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($marker,($promoted|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Changed=$true;Message='Forest promotion completed; durable success-gated reboot recovery armed';Data=@{RebootRequired=$true}}
}
if($Stage -eq 'Verify'){
    if(-not(Get-ADStatus)){throw "Domain controller for '$domain' is not ready"}
    Import-Module ActiveDirectory -ErrorAction Stop
    $actual=(Get-ADDomain -ErrorAction Stop).DNSRoot
    if($actual -ine $domain){throw "Unexpected domain: $actual"}
    $ntds=Get-Service -Name NTDS -ErrorAction Stop
    $dns=Get-Service -Name DNS -ErrorAction Stop
    if($ntds.Status -ne 'Running' -or $dns.Status -ne 'Running'){throw 'AD DS and DNS must both be running'}
    if(-not(Test-Path (Join-Path $env:SystemRoot 'SYSVOL\sysvol'))){throw 'SYSVOL not ready'}
    $forest=Get-ADForest -ErrorAction Stop
    if($forest.RootDomain -ine $domain){throw 'AD forest root mismatch'}
    $srv=@(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.'+$domain) -Type SRV -Server 127.0.0.1 -ErrorAction Stop | Where-Object {$_.Type -eq 'SRV'})
    if(-not $srv.Count){throw 'AD LDAP DNS SRV records missing'}
    foreach($share in @('SYSVOL','NETLOGON')){if(-not(Get-SmbShare -Name $share -ErrorAction SilentlyContinue)){throw "AD $share share missing"}}
    return [pscustomobject]@{Changed=$false;Message="AD $domain forest, services, SYSVOL/NETLOGON shares and LDAP SRV ready"}
}
