# Configuration/service proof only. Receiver audit ingestion is a separate check.
[CmdletBinding()]param([Parameter(Mandatory)][hashtable]$Settings)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath([string]$Settings.ServerRoot)
if([string]$Settings.TrustBundleSHA256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'A reviewed syslog trust bundle SHA256 is required'}
$path=Join-Path $root 'Conf\dbparm.ini';$ca=Join-Path $root ('Conf\PASeasy-PTA-syslog-ca-'+([string]$Settings.TrustBundleSHA256).ToLowerInvariant()+'.pem')
$lines=@(Get-Content -LiteralPath $path -ErrorAction Stop | ForEach-Object {[string]$_})
$destination=if($Settings.ContainsKey('DestinationName') -and $Settings.DestinationName){[string]$Settings.DestinationName}else{[string]$Settings.Address}
$expected=@{
    SyslogServerIP=$destination;SyslogServerPort=[string][int]$Settings.Port
    SyslogServerProtocol='TLS';SyslogTLSVersions='TLS_1_2';SyslogTranslatorFile='Syslog\PTA.xsl';UseLegacySyslogFormat='No'
    SyslogTrustedCAPath=('"'+$ca+'"');SyslogSendBOMPrefix='NO'
    SyslogMessageCodeFilter='295,308,7,428,361,372,373,359,436,412,411,300,302,294,427,24,31,471,4'
}
$good=$true
foreach($key in $expected.Keys){
    $matches=@($lines | Where-Object {$_ -match ('^\s*'+[regex]::Escape($key)+'\s*=')})
    if($matches.Count -ne 1 -or $matches[0] -cne ($key+'='+$expected[$key])){$good=$false}
}
$caHash=if(Test-Path -LiteralPath $ca -PathType Leaf){(Get-FileHash $ca -Algorithm SHA256).Hash}else{''}
$service=Get-CimInstance Win32_Service -Filter "Name='PrivateArk Server'" -ErrorAction Stop
if($Settings.ContainsKey('VaultAddress')){
    $system=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $local=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|ForEach-Object {$_.IPAddress})
    if($system.PartOfDomain -or $service.State -ne 'Running' -or [string]$Settings.VaultAddress -notin $local){throw 'PTA TLS audit verification requires the running workgroup primary at its reviewed address'}
}
$loaded=$false
if($service.State -eq 'Running' -and $service.ProcessId){
    $process=Get-Process -Id $service.ProcessId -ErrorAction Stop
    $loaded=($process.StartTime.ToUniversalTime() -ge [IO.File]::GetLastWriteTimeUtc($path))
}
$translator=(Get-FileHash (Join-Path $root 'Syslog\PTA.xsl') -Algorithm SHA256).Hash
$import=(Get-FileHash (Join-Path $root 'Syslog\RFC5424Changes.xsl') -Algorithm SHA256).Hash
[pscustomobject]@{Passed=($good -and $loaded -and $caHash -ieq [string]$Settings.TrustBundleSHA256 -and $translator -ieq [string]$Settings.TranslatorSHA256 -and $import -ieq [string]$Settings.TranslatorImportSHA256);
    Message='TLS syslog configuration loaded by running Vault; receiver audit ingestion is a separate functional gate';
    Evidence=@("ConfigMatches=$good","ServiceLoadedConfig=$loaded","TrustBundleSHA256=$caHash")}
