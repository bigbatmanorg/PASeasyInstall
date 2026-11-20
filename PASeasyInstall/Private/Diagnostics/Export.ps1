# Health check of an installed lab and sanitized export of a run's data.
# Both are read-only towards the lab, except the health check's single PVWA REST session, which is
# serialised with deployments through the Vault lock (Locks.ps1) and always logged off.

function New-PASZipFromDirectory {
    # ZIP with forward-slash entry names. Windows PowerShell 5.1's ZipFile.CreateFromDirectory writes
    # backslashes, which other unzip tools turn into flat file names.
    param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$Path,[string]$EntryPrefix='')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root=[IO.Path]::GetFullPath($Directory).TrimEnd('\','/')
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    try{
        $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
        try{
            foreach($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)){
                $name=$EntryPrefix+($f.FullName.Substring($root.Length+1) -replace '\\','/')
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$f.FullName,$name,[IO.Compression.CompressionLevel]::Optimal)
            }
        }finally{$zip.Dispose()}
    }finally{$stream.Dispose()}
}

function Get-PASHealthPvwaBaseUri {
    param($Configuration,[uri]$ApiBaseUri)
    if($ApiBaseUri){return $ApiBaseUri}
    $urls=@()
    foreach($comp in @($Configuration.components|Where-Object {$_ -and $_.type -eq 'PVWA'})){
        $o=$null;if($comp -is [System.Collections.IDictionary] -and $comp.Contains('options')){$o=$comp.options}
        if($o -and $o.Contains('pvwaUrl') -and [string]$o.pvwaUrl){$urls+=[string]$o.pvwaUrl}
        elseif($Configuration.hosts.Contains([string]$comp.host)){$urls+=('https://'+[string]$Configuration.hosts[[string]$comp.host].address+'/PasswordVault')}
    }
    $urls=@($urls|Select-Object -Unique)
    if($urls.Count -ne 1){throw 'Pass -ApiBaseUri: the configuration has no PVWA, or more than one'}
    $u=$urls[0].TrimEnd('/');if($u -notmatch '/API$'){$u+='/API'}
    return [uri]$u
}

function Get-PASHealthPinnedCertificate {
    # A CPM that trusts the lab PVWA certificate records it in its options; reuse that pin.
    param($Configuration,[string]$CertificateFile)
    if($CertificateFile){return $CertificateFile}
    foreach($comp in @($Configuration.components|Where-Object {$_ -and $_.type -eq 'CPM'})){
        if($comp -is [System.Collections.IDictionary] -and $comp.Contains('options') -and $comp.options -and $comp.options.Contains('pvwaTrustCertificateFile')){
            $f=[string]$comp.options.pvwaTrustCertificateFile
            if($f -and (Test-Path -LiteralPath $f -PathType Leaf)){return $f}
        }
    }
    # A CPM that trusts 'the PVWA of this deployment' (pvwaTrustFrom) had that certificate read from the PVWA
    # server at install time and stored in the run directory: reuse the one of the newest run of this environment.
    foreach($comp in @($Configuration.components|Where-Object {$_ -and $_.type -eq 'CPM'})){
        if(-not($comp -is [System.Collections.IDictionary] -and $comp.Contains('options') -and $comp.options -and $comp.options.Contains('pvwaTrustFrom'))){continue}
        $src=[string]$comp.options.pvwaTrustFrom
        if($src -notmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){continue}
        foreach($run in @(Get-PASRunRecords|Where-Object {[string]$_.name -eq [string]$Configuration.name})){
            $cer=Join-Path (Get-PASRunDirectory ([string]$run.id)) ('pvwa-trust-'+$src+'.cer')
            if(Test-Path -LiteralPath $cer -PathType Leaf){return $cer}
        }
    }
    return ''
}

function Test-PASDRReplication {
    param([string]$Address,[pscredential]$Credential,[bool]$SkipCertificateChecks,[int]$MaxAgeMinutes)
    $out=[ordered]@{Checked=$false;Status='NotChecked';LastCycleUtc=$null;Service='';Message=''}
    $user=[string]$Credential.UserName
    if($user -and $user -notmatch '[\\@]'){$Credential=[pscredential]::new('.\'+$user,$Credential.Password)}
    $optionArgs=@{OpenTimeout=30000;OperationTimeout=120000}
    if($SkipCertificateChecks){$optionArgs.SkipCACheck=$true;$optionArgs.SkipCNCheck=$true}
    $session=$null
    try{
        # A hardened Vault server only accepts the toolkit's restricted management endpoint.
        $sessionArgs=@{ComputerName=$Address;Credential=$Credential;UseSSL=$true;SessionOption=(New-PSSessionOption @optionArgs);ErrorAction='Stop'}
        try{$session=New-PSSession @sessionArgs -ConfigurationName 'PAExec.Management'}catch{$session=New-PSSession @sessionArgs}
        $r=Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $svc=Get-Service -Name 'CyberArk Vault Disaster Recovery','PADR' -ErrorAction SilentlyContinue|Select-Object -First 1
            if(-not $svc){$svc=Get-Service -ErrorAction SilentlyContinue|Where-Object {$_.DisplayName -like '*Disaster Recovery*'}|Select-Object -First 1}
            $log=Get-ChildItem 'C:\Program Files (x86)\PrivateArk\PADR\Logs' -Filter 'padr.log' -ErrorAction SilentlyContinue|Select-Object -First 1
            $line=$null
            if($log){$line=Get-Content -LiteralPath $log.FullName -Tail 4000 -ErrorAction SilentlyContinue|Where-Object {$_ -match 'PADR0010I|PADR0099I'}|Select-Object -Last 1}
            [pscustomobject]@{Service=$(if($svc){[string]$svc.Status}else{''});Line=[string]$line}
        }
        $out.Checked=$true;$out.Service=[string]$r.Service
        if($r.Line -match '\[(\d{2})/(\d{2})/(\d{4})\s+(\d{2}):(\d{2}):(\d{2})'){
            $local=[datetime]::new([int]$Matches[3],[int]$Matches[2],[int]$Matches[1],[int]$Matches[4],[int]$Matches[5],[int]$Matches[6],[DateTimeKind]::Local)
            $out.LastCycleUtc=$local.ToUniversalTime().ToString('o')
            $age=([datetime]::UtcNow-$local.ToUniversalTime()).TotalMinutes
            $out.Status=if($out.Service -ne 'Running'){'ServiceNotRunning'}elseif($age -le $MaxAgeMinutes){'Replicating'}else{'Stale'}
            $out.Message="Last replication cycle $([math]::Round($age)) min ago; DR service $($out.Service)"
        }else{
            $out.Status=if($out.Service -ne 'Running'){'ServiceNotRunning'}else{'NoCycleFound'}
            $out.Message="No replication cycle found in padr.log; DR service '$($out.Service)'"
        }
    }catch{
        $out.Status='Unreachable';$out.Message=('DR check failed: '+$_.Exception.Message)
    }finally{if($session){Remove-PSSession $session -ErrorAction SilentlyContinue}}
    return [pscustomobject]$out
}

function Test-PASDeploymentHealth {
    <#
    .SYNOPSIS
    Checks that an installed lab works: PVWA login, the components the Vault sees as connected, and DR replication.
    .DESCRIPTION
    Opens ONE authenticated PVWA REST session with the Vault Administrator credential and checks:
    - the PVWA API answers over HTTPS. The certificate is checked normally, or pinned when
      -PvwaCertificateFile is given or the configuration's CPM pins one (lab self-signed PVWA);
    - which components the Vault reports as logged on (PVWA, CPM, PSM and PSMP);
    - "PASWS383E Vault is currently under maintenance mode". This usually means PVWA started before the
      Vault was up; recycle the PasswordVaultWebAccessPool app pool on the PVWA server.
    With -DRCredential it also reads the DR server's last PADR replication cycle over WinRM. With DR
    configured, component password rotation fails while DR is not replicating (CASTM057E).

    The session is serialised with deployments through the same Vault lock the installer uses, and is
    always logged off. Credentials are used in memory only and are never written anywhere.
    .PARAMETER Config
    Path of the deployment configuration (JSON) that installed the lab.
    .PARAMETER VaultCredential
    Vault Administrator (or another Vault user allowed to read system health).
    .PARAMETER ApiBaseUri
    PVWA API base, e.g. https://pvwa01/PasswordVault/API. Default: from the configuration.
    .PARAMETER PvwaCertificateFile
    Public certificate (.cer) of a self-signed lab PVWA to pin. The host name must still match.
    .PARAMETER DRCredential
    Windows credential of the DR server, for the replication check.
    .EXAMPLE
    Test-PASDeploymentHealth -Config .\MyLab.json -VaultCredential (Get-Credential Administrator)
    .EXAMPLE
    $h = Test-PASDeploymentHealth -Config .\MyLab.json -VaultCredential $vault -DRCredential $dr
    $h.Components | Format-Table Component,User,Address,LoggedOn,Version
    #>
    [CmdletBinding()]
    param([string]$Config,$Configuration,[Parameter(Mandatory)][pscredential]$VaultCredential,
        [uri]$ApiBaseUri,[string]$PvwaCertificateFile='',[pscredential]$DRCredential,
        [ValidateRange(10,600)][int]$TimeoutSeconds=60,[ValidateRange(5,1440)][int]$DRMaxAgeMinutes=75)
    $valid=Test-PASConfiguration -Config $Config -Configuration $Configuration
    if(-not $valid.Valid){throw ('Configuration invalid: '+($valid.Issues -join '; '))}
    $c=$valid.Configuration
    $result=[ordered]@{Healthy=$false;CheckedUtc=[DateTime]::UtcNow.ToString('o');Environment=[string]$c.name;ApiBaseUri='';
        PvwaLogin='NotTested';TlsValidation='';Components=@();Summary=@();DR=$null;Issues=@();Message=''}
    $issues=New-Object System.Collections.ArrayList
    $base=Get-PASHealthPvwaBaseUri $c $ApiBaseUri
    if($base.Scheme -ne 'https'){throw 'The PVWA API must be HTTPS'}
    $result.ApiBaseUri=$base.AbsoluteUri
    $pinFile=Get-PASHealthPinnedCertificate $c $PvwaCertificateFile
    $pin=''
    if($pinFile){$pin=(New-Object Security.Cryptography.X509Certificates.X509Certificate2($pinFile)).Thumbprint;$result.TlsValidation='PinnedCertificate+HostName'}
    else{$result.TlsValidation='SystemTrust+HostName'}
    $vaultLock=$null
    $previousCallback=[Net.ServicePointManager]::ServerCertificateValidationCallback
    $previousProtocol=[Net.ServicePointManager]::SecurityProtocol
    $token=$null
    try{
        # One authenticated Vault session at a time on this controller: wait for a running deployment step.
        $vaultLock=Enter-PASVaultLock -Address ([string]$c.vault.address) -TimeoutSeconds 60
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        if($pin){
            $expected=$pin
            [Net.ServicePointManager]::ServerCertificateValidationCallback={param($s,$cert,$chain,$errors)
                ($cert.GetCertHashString() -eq $expected) -and (($errors -band [Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) -eq 0)}.GetNewClosure()
        }
        $api=$base.AbsoluteUri.TrimEnd('/')
        $body=@{username=$VaultCredential.UserName;password=$VaultCredential.GetNetworkCredential().Password;concurrentSession=$false}|ConvertTo-Json -Compress
        try{
            $token=Invoke-RestMethod -Method Post -Uri ($api+'/auth/CyberArk/Logon') -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        }catch{
            $details=if($_.ErrorDetails){[string]$_.ErrorDetails.Message}else{''}
            $text=$details+' '+[string]$_.Exception.Message
            if($text -match 'PASWS383E'){
                $result.PvwaLogin='VaultMaintenanceMode'
                [void]$issues.Add('PVWA reports PASWS383E (Vault maintenance mode). It most likely started before the Vault was up: recycle the PasswordVaultWebAccessPool app pool on the PVWA server.')
            }else{
                $result.PvwaLogin='Failed';[void]$issues.Add('PVWA login failed: '+$_.Exception.Message)
            }
            throw 'PVWA login failed'
        }finally{$body=$null}
        $result.PvwaLogin='Succeeded'
        $headers=@{Authorization=$token}
        $summary=Invoke-RestMethod -Uri ($api+'/ComponentsMonitoringSummary') -Headers $headers -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        $result.Summary=@($summary.Components|ForEach-Object {[pscustomobject]@{Component=[string]$_.ComponentName;Connected=[int]$_.ConnectedComponentCount;Total=[int]$_.ComponentTotalCount}})
        $rows=@()
        foreach($id in @('PVWA','CPM','SessionManagement')){
            try{$d=Invoke-RestMethod -Uri ($api+'/ComponentsMonitoringDetails/'+$id) -Headers $headers -TimeoutSec $TimeoutSeconds -ErrorAction Stop}catch{continue}
            foreach($x in @($d.ComponentsDetails)){
                $rows+=[pscustomobject]@{Component=$id;User=[string]$x.ComponentUserName;Address=[string]$x.ComponentIP;LoggedOn=[bool]$x.IsLoggedOn;Version=[string]$x.ComponentVersion;LastLogonUtc=$(if($x.LastLogonDate){[DateTimeOffset]::FromUnixTimeSeconds([long]$x.LastLogonDate).UtcDateTime.ToString('o')}else{$null})}
            }
        }
        $result.Components=$rows
        foreach($row in @($rows|Where-Object {-not $_.LoggedOn})){[void]$issues.Add("$($row.Component) $($row.User) ($($row.Address)) is not logged on to the Vault")}
        $expectedTypes=@($c.components|Where-Object {$_}|ForEach-Object {[string]$_.type})
        foreach($t in @('PVWA','CPM')){if($expectedTypes -contains $t -and -not @($rows|Where-Object {$_.Component -eq $t}).Count){[void]$issues.Add("No $t is registered in the Vault")}}
        if(($expectedTypes -contains 'PSM' -or $expectedTypes -contains 'PSMP') -and -not @($rows|Where-Object {$_.Component -eq 'SessionManagement'}).Count){[void]$issues.Add('No PSM/PSMP is registered in the Vault')}
    }catch{
        if(-not $issues.Count){[void]$issues.Add('Health check failed: '+$_.Exception.Message)}
    }finally{
        if($token){
            try{Invoke-RestMethod -Method Post -Uri ($base.AbsoluteUri.TrimEnd('/')+'/auth/Logoff') -Headers @{Authorization=$token} -TimeoutSec $TimeoutSeconds -ErrorAction Stop|Out-Null}
            catch{[void]$issues.Add('PVWA logoff failed; the session expires on its own')}
        }
        $token=$null
        [Net.ServicePointManager]::ServerCertificateValidationCallback=$previousCallback
        [Net.ServicePointManager]::SecurityProtocol=$previousProtocol
        Exit-PASVaultLock $vaultLock
    }
    $dr=@($c.components|Where-Object {$_ -and $_.type -eq 'DRVault'})
    if($dr.Count -and $DRCredential){
        $drHost=$c.hosts[[string]$dr[0].host]
        $skip=($c.security.profile -eq 'Lab' -and $c.security.overrides.Contains('WinRM.SkipCACheck') -and [bool]$c.security.overrides['WinRM.SkipCACheck'])
        $result.DR=Test-PASDRReplication -Address ([string]$drHost.address) -Credential $DRCredential -SkipCertificateChecks $skip -MaxAgeMinutes $DRMaxAgeMinutes
        if($result.DR.Status -ne 'Replicating'){[void]$issues.Add('DR: '+$result.DR.Message+'. With DR configured, component password rotation fails until DR replicates (CASTM057E).')}
    }elseif($dr.Count){
        $result.DR=[pscustomobject]@{Checked=$false;Status='NotChecked';LastCycleUtc=$null;Service='';Message='Pass -DRCredential to check DR replication'}
    }
    $result.Issues=@($issues)
    $result.Healthy=($result.PvwaLogin -eq 'Succeeded' -and $issues.Count -eq 0)
    $result.Message=if($result.Healthy){'All checked components are connected to the Vault'}else{"$($issues.Count) issue(s) found"}
    return [pscustomobject]$result
}

function Get-PASRunDataSecretHits {
    param([string]$Text)
    $hits=@()
    if($Text -match '-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----'){$hits+='private key'}
    if($Text.Contains((-join [char[]](67,121,98,101,114,97,114,107,48,49,33)))){$hits+='lab password'}
    if($Text -match '"cipher"\s*:\s*"[0-9a-fA-F]{40,}'){$hits+='DPAPI credential cipher'}
    if($Text -match '(?i)"(password|secret|apikey)"\s*:\s*"[^"]{4,}"'){$hits+='password field'}
    return $hits
}

function Export-PASDeploymentData {
    <#
    .SYNOPSIS
    Writes a sanitized ZIP of one run (configuration, plan, status and event journals) for support or documentation.
    .DESCRIPTION
    Takes the run id returned when the deployment was started. Credential envelopes, lock files and the
    generated payload folder (scripts and per-component inventories) are never included. Every file is
    scanned for private keys, credential ciphers and password fields; a file with a hit is left out and
    listed in the result.
    .PARAMETER RunId
    32-character run id.
    .PARAMETER Path
    ZIP file to create. Default: .\PASeasyInstall-run-<RunId>.zip
    .EXAMPLE
    Export-PASDeploymentData -RunId 688d8e04f1874d41a75cda4441c00553
    .EXAMPLE
    Export-PASDeploymentData -RunId $id -Path C:\Temp\lab-run.zip -Force
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,[string]$Path='',[switch]$Force,[string]$DataRoot='')
    if(-not $DataRoot){$DataRoot=Get-PASDataRoot}
    if(-not $Path){$Path=Join-Path (Get-Location).ProviderPath ("PASeasyInstall-run-$RunId.zip")}
    $Path=[IO.Path]::GetFullPath($Path)
    if((Test-Path -LiteralPath $Path) -and -not $Force){throw "File exists: $Path (use -Force)"}
    $runDir=Join-Path (Join-Path $DataRoot 'Runs') $RunId
    if(-not(Test-Path -LiteralPath (Join-Path $runDir 'run.json') -PathType Leaf)){throw "No run $RunId under $DataRoot"}
    $sources=@(@{Root=$runDir;Prefix=('runs/'+$RunId)})
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('pas-export-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage|Out-Null
    $included=New-Object System.Collections.ArrayList;$excluded=New-Object System.Collections.ArrayList
    try{
        foreach($s in $sources){
            foreach($f in @(Get-ChildItem -LiteralPath $s.Root -Recurse -File -Force)){
                $rel=$f.FullName.Substring($s.Root.Length).TrimStart('\','/')
                $name=$f.Name
                if($name -like 'credentials-*' -or $name -like 'auth-*' -or $name -like '*.lock' -or $name -like '.*' -or $rel -match '(^|[\\/])Payloads[\\/]'){continue}
                if($f.Extension -notin @('.json','.jsonl','.psd1','.txt','.log')){continue}
                $text=[IO.File]::ReadAllText($f.FullName)
                $hits=@(Get-PASRunDataSecretHits $text)
                $target=($s.Prefix+'/'+($rel -replace '\\','/'))
                if($hits.Count){[void]$excluded.Add([pscustomobject]@{File=$target;Reason=($hits -join ', ')});continue}
                $dest=Join-Path $stage ($target -replace '/','\')
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force|Out-Null
                [IO.File]::WriteAllText($dest,$text,(New-Object Text.UTF8Encoding($false)))
                [void]$included.Add($target)
            }
        }
        $manifest=[ordered]@{schemaVersion=1;runId=$RunId;exportedUtc=[DateTime]::UtcNow.ToString('o');files=@($included);excluded=@($excluded)}
        [IO.File]::WriteAllText((Join-Path $stage 'export-manifest.json'),($manifest|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force}
        New-PASZipFromDirectory -Directory $stage -Path $Path
    }finally{Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
    return [pscustomobject]@{Path=$Path;RunId=$RunId;Files=$included.Count;Excluded=@($excluded)}
}
