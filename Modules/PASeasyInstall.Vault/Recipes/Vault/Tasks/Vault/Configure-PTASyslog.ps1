# Runs as a durable SYSTEM attempt; never edits an unrelated SIEM destination.
[CmdletBinding()]param([Parameter(Mandatory)][hashtable]$Settings)
$ErrorActionPreference='Stop'
$address=$null
if(-not [Net.IPAddress]::TryParse([string]$Settings.Address,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'PTA syslog requires a reviewed IPv4 destination'}
$destination=$address.ToString()
if($Settings.ContainsKey('DestinationName') -and $Settings.DestinationName){
    $destination=[string]$Settings.DestinationName
    if($destination -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'){throw 'Invalid PTA syslog DNS name'}
    $resolved=@([Net.Dns]::GetHostAddresses($destination)|Where-Object {$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|ForEach-Object {$_.ToString()}|Sort-Object -Unique)
    if($resolved.Count -ne 1 -or $resolved[0] -ne $address.ToString()){throw 'PTA syslog DNS name does not uniquely resolve to the reviewed target IPv4 address'}
}
if([int]$Settings.Port -notin @(514,11514)){throw 'Unqualified PTA TLS syslog port'}
$root=[IO.Path]::GetFullPath([string]$Settings.ServerRoot).TrimEnd('\')
$service=Get-CimInstance Win32_Service -Filter "Name='PrivateArk Server'" -ErrorAction Stop
if(-not $service -or $service.PathName -notmatch ('^"?'+[regex]::Escape((Join-Path $root 'dbmain.exe'))+'"?\s')){throw 'Vault installation path does not match its installed service'}
if($Settings.ContainsKey('VaultAddress')){
    $system=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $local=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|ForEach-Object {$_.IPAddress})
    if($system.PartOfDomain -or $service.State -ne 'Running' -or [string]$Settings.VaultAddress -notin $local){throw 'PTA TLS audit setup requires the running workgroup primary at its reviewed address; standby DR is refused'}
}
$trusted=@('S-1-5-18','S-1-5-32-544')
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Vault syslog configuration requires an elevated task identity'}
$trusted+=$identity.User.Value
try{$trusted+=([Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value}catch{}
function Assert-SyslogPath([string]$Path){
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'PTA syslog path has a reparse ancestor'}
            $acl=Get-Acl -LiteralPath $cursor
            if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'PTA syslog path has an untrusted owner'}
        }
        $next=Split-Path $cursor -Parent;if($next -eq $cursor){break};$cursor=$next
    }
    if(Test-Path -LiteralPath $Path){
        $acl=Get-Acl -LiteralPath $Path
        foreach($rule in @($acl.Access)){
            if($rule.AccessControlType -eq 'Allow' -and -not($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership')){
                if($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Vault syslog application path allows untrusted writes'}
            }
        }
    }
}
$conf=Join-Path $root 'Conf';$path=Join-Path $conf 'dbparm.ini'
if([string]$Settings.TrustBundleSHA256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'A reviewed syslog trust bundle SHA256 is required'}
# Immutable content paths preserve old trust during a reviewed certificate rotation.
$caPath=Join-Path $conf ('PASeasy-PTA-syslog-ca-'+([string]$Settings.TrustBundleSHA256).ToLowerInvariant()+'.pem')
$restartPath=Join-Path $conf 'PASeasy-PTA-syslog-restart.json'
foreach($p in @($root,$conf,$path,$caPath,$restartPath)){Assert-SyslogPath $p}
$dependents=@((Get-Service -Name 'PrivateArk Server' -ErrorAction Stop).DependentServices)
foreach($dependent in $dependents){if($dependent.Name -ne 'Cyber-Ark Event Notification Engine'){throw 'An unqualified Vault dependent service requires explicit restart review'}}
$translator=Join-Path $root 'Syslog\PTA.xsl'
$import=Join-Path $root 'Syslog\RFC5424Changes.xsl'
foreach($p in @($translator,$import)){Assert-SyslogPath $p;if(-not(Test-Path $p -PathType Leaf)){throw 'Native Vault PTA syslog translator is missing'}}
if((Get-FileHash $translator -Algorithm SHA256).Hash -ine [string]$Settings.TranslatorSHA256){throw 'Native PTA translator differs from the reviewed media mapping'}
if((Get-FileHash $import -Algorithm SHA256).Hash -ine [string]$Settings.TranslatorImportSHA256){throw 'Native PTA translator import differs from the reviewed media mapping'}
$caBytes=[Convert]::FromBase64String([string]$Settings.TrustBundleBase64)
if($caBytes.Length -gt 65536 -or $caBytes.Length -lt 100){throw 'Unexpected syslog trust bundle size'}
$caText=[Text.Encoding]::ASCII.GetString($caBytes)
if($caText -match 'PRIVATE KEY' -or $caText -notmatch '-----BEGIN CERTIFICATE-----'){throw 'Only a public PEM certificate bundle may be staged'}
$certificates=[regex]::Matches($caText,'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----')
if(-not $certificates.Count){throw 'Syslog certificate bundle is invalid'}
foreach($match in $certificates){
    try{$certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($match.Groups[1].Value))}
    catch{throw 'Syslog certificate bundle contains an invalid certificate'}
    try{
        if($certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or $certificate.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow){throw 'Syslog trust certificate is outside its validity period'}
    }finally{$certificate.Dispose()}
}
$sha=[Security.Cryptography.SHA256]::Create()
try{$caHash=([BitConverter]::ToString($sha.ComputeHash($caBytes))).Replace('-','')}finally{$sha.Dispose()}
if($caHash -ine [string]$Settings.TrustBundleSHA256){throw 'Syslog trust bundle differs from its reviewed SHA256'}
if(Test-Path $caPath){if((Get-FileHash $caPath -Algorithm SHA256).Hash -ine $caHash){throw 'Existing syslog trust bundle differs; explicit certificate rotation is required'}}
$bytes=[IO.File]::ReadAllBytes($path)
if(@($bytes|Where-Object{$_ -gt 127}).Count){throw 'DBParm encoding requires explicit review; refusing an implicit encoding conversion'}
$text=[Text.Encoding]::ASCII.GetString($bytes)
$lines=@($text -split '\r?\n')
$wanted=[ordered]@{
    SyslogServerIP=$destination;SyslogServerPort=[string][int]$Settings.Port
    SyslogServerProtocol='TLS';SyslogTLSVersions='TLS_1_2';SyslogTranslatorFile='Syslog\PTA.xsl'
    SyslogTrustedCAPath=('"'+$caPath+'"')
    SyslogMessageCodeFilter='295,308,7,428,361,372,373,359,436,412,411,300,302,294,427,24,31,471,4'
    SyslogSendBOMPrefix='NO';UseLegacySyslogFormat='No'
}
$inSyslog=$false;$sections=0;$seen=@{};$changed=$false
for($index=0;$index -lt $lines.Count;$index++){
    $line=[string]$lines[$index]
    if($line -match '^\s*\[([^\]]+)\]\s*$'){$inSyslog=($Matches[1] -ieq 'SYSLOG');if($inSyslog){$sections++};continue}
    if($line -match '^\s*(Syslog\w+|UseLegacySyslogFormat)\s*=\s*(.*?)\s*$'){
        $key=$Matches[1];$value=$Matches[2]
        if(-not $inSyslog){throw 'Syslog settings outside the SYSLOG section need explicit review'}
        if($seen.ContainsKey($key)){throw 'Duplicate syslog settings need explicit review'}
        $seen[$key]=$true
        if(-not $wanted.Contains($key)){throw 'An existing syslog parameter requires explicit merge review'}
        if($key -eq 'SyslogServerIP' -and $value -notin @($wanted[$key],$address.ToString())){throw 'An existing SIEM destination requires explicit merge review'}
        $replacement=$key+'='+$wanted[$key]
        if($line -cne $replacement){$changed=$true;$lines[$index]=$replacement}
    }
}
if($sections -ne 1){throw 'Expected exactly one SYSLOG section'}
$output=New-Object 'System.Collections.Generic.List[string]'
$inSyslog=$false
foreach($line in $lines){
    if($line -match '^\s*\[([^\]]+)\]\s*$'){
        if($inSyslog){foreach($key in $wanted.Keys){if(-not $seen.ContainsKey($key)){$output.Add($key+'='+$wanted[$key]);$changed=$true}}}
        $inSyslog=($Matches[1] -ieq 'SYSLOG')
    }
    $output.Add($line)
}
if($inSyslog){foreach($key in $wanted.Keys){if(-not $seen.ContainsKey($key)){$output.Add($key+'='+$wanted[$key]);$changed=$true}}}
if(-not(Test-Path $caPath)){
    $file=[IO.File]::Open($caPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($caBytes,0,$caBytes.Length);$file.Flush($true)}finally{$file.Dispose()}
}
$acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
([IO.FileInfo]::new($caPath)).SetAccessControl($acl)
if($changed){
    $tmp=Join-Path $conf ('paeasy-syslog-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $backup=Join-Path $conf ('dbparm-before-paeasy-syslog-'+[guid]::NewGuid().ToString('N')+'.bak')
    try{
        $file=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$configBytes=[Text.Encoding]::ASCII.GetBytes(($output -join "`r`n"));$file.Write($configBytes,0,$configBytes.Length);$file.Flush($true)}finally{$file.Dispose()}
        [IO.File]::Replace($tmp,$path,$backup)
        $file=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        try{$file.Flush($true)}finally{$file.Dispose()}
    }finally{if(Test-Path $tmp){Remove-Item $tmp -Force}}
}
# If an earlier attempt wrote config but died before restart, the service start
# time proves whether this exact config could have been loaded. No blind skip.
$service=Get-CimInstance Win32_Service -Filter "Name='PrivateArk Server'" -ErrorAction Stop
$process=if($service.ProcessId){Get-Process -Id $service.ProcessId -ErrorAction Stop}else{$null}
$restarted=$false
if($changed -or (Test-Path $restartPath) -or -not $process -or $process.StartTime.ToUniversalTime() -lt [IO.File]::GetLastWriteTimeUtc($path)){
    $configHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if(Test-Path $restartPath){
        $restart=Get-Content -LiteralPath $restartPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if($restart.schemaVersion -ne 1 -or $restart.configSHA256 -ne $configHash){throw 'Pending syslog restart no longer matches the reviewed config'}
        $restore=@($restart.services)
        if(-not($restore -contains 'PrivateArk Server') -or @($restore|Where-Object {$_ -notin @('PrivateArk Server','Cyber-Ark Event Notification Engine')}).Count){throw 'Pending syslog restart has unqualified service names'}
    }else{
        $restore=@('PrivateArk Server')+@($dependents|Where-Object {$_.Status -eq 'Running' -or $_.Status -eq 'StartPending'}|ForEach-Object {$_.Name})
        $record=@{schemaVersion=1;configSHA256=$configHash;services=@($restore)} | ConvertTo-Json -Compress
        $file=[IO.File]::Open($restartPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$recordBytes=[Text.Encoding]::UTF8.GetBytes($record);$file.Write($recordBytes,0,$recordBytes.Length);$file.Flush($true)}finally{$file.Dispose()}
    }
    foreach($dependent in $dependents){
        if($dependent.Status -ne 'Stopped'){Stop-Service -Name $dependent.Name -ErrorAction Stop}
    }
    Restart-Service -Name 'PrivateArk Server' -ErrorAction Stop
    $restarted=$true
    foreach($name in @($restore|Where-Object {$_ -ne 'PrivateArk Server'})){Start-Service -Name $name -ErrorAction Stop}
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    do{
        Start-Sleep -Seconds 2
        $pending=@($restore|Where-Object {(Get-Service -Name $_ -ErrorAction Stop).Status -ne 'Running'})
        if(-not $pending.Count){break}
    }while([DateTime]::UtcNow -lt $deadline)
    if($pending.Count){throw 'Vault or its previously running dependents did not start after TLS syslog configuration'}
    Remove-Item -LiteralPath $restartPath -Force -ErrorAction Stop
}
[pscustomobject]@{Changed=($changed -or $restarted);Message='Vault TLS syslog configured; independent PTA audit ingestion still required';Data=@{Metadata=('TLS syslog '+$destination+':'+[int]$Settings.Port);Hash=$caHash}}
