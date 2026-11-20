# Release-surface helpers: environment health check and sanitized run-data export.
# Both are read-only towards the lab, except the health check's single PVWA REST session, which is
# serialised with deployments through the engine's Vault gate and always logged off.

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
    # A CPM that trusts 'the PVWA of this deployment' had that certificate read over the authenticated management
    # channel at install time and stored with the composed deployment: reuse the newest one for this environment.
    foreach($comp in @($Configuration.components|Where-Object {$_ -and $_.type -eq 'CPM'})){
        if(-not($comp -is [System.Collections.IDictionary] -and $comp.Contains('options') -and $comp.options -and $comp.options.Contains('pvwaTrustFrom'))){continue}
        $src=[string]$comp.options.pvwaTrustFrom
        if($src -notmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){continue}
        $root=Get-PASFleetRoot
        if(-not(Test-Path -LiteralPath $root)){continue}
        foreach($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending)){
            $cer=Join-Path $d.FullName ('pvwa-trust-'+$src+'.cer')
            if(-not(Test-Path -LiteralPath $cer -PathType Leaf)){continue}
            $f=Read-PASFleetJson (Join-Path $d.FullName 'fleet.json')
            if($f -and [string]$f.name -eq [string]$Configuration.name){return $cer}
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

function Test-PASEnvironmentHealth {
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

    The session is serialised with deployments through the same Vault gate the installer uses, and is
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
    Test-PASEnvironmentHealth -Config .\MyLab.json -VaultCredential (Get-Credential Administrator)
    .EXAMPLE
    $h = Test-PASEnvironmentHealth -Config .\MyLab.json -VaultCredential $vault -DRCredential $dr
    $h.Components | Format-Table Component,User,Address,LoggedOn,Version
    #>
    [CmdletBinding()]
    param([string]$Config,$Configuration,[Parameter(Mandatory)][pscredential]$VaultCredential,
        [uri]$ApiBaseUri,[string]$PvwaCertificateFile='',[pscredential]$DRCredential,
        [ValidateRange(10,600)][int]$TimeoutSeconds=60,[ValidateRange(5,1440)][int]$DRMaxAgeMinutes=75)
    $valid=Test-PASEnvironment -Config $Config -Configuration $Configuration
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
    $core=Get-PASOwnCoreModule
    $dataRoot=& $core {Get-PASDataRoot}
    $healthRun=[guid]::NewGuid().ToString('N')
    $gates=New-Object System.Collections.ArrayList
    $previousCallback=[Net.ServicePointManager]::ServerCertificateValidationCallback
    $previousProtocol=[Net.ServicePointManager]::SecurityProtocol
    $token=$null
    try{
        $identities=@(& $core {param($a) Get-PASResourceIdentity -Address $a} ([string]$c.vault.address)|Sort-Object -Unique)
        foreach($identity in $identities){[void]$gates.Add((& $core {param($n,$d,$r) Enter-PASGate -Name $n -DataRoot $d -RunId $r -TimeoutSeconds 60} ('vault-'+$identity) $dataRoot $healthRun))}
        if(@($gates|Where-Object {$_.PreexistingClaim}).Count){throw 'An unreconciled Vault session claim exists on this controller (a failed deployment or health check). Reconcile it before opening a new session.'}
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
        foreach($g in @($gates)){try{$g.Complete()}catch{};try{$g.Dispose()}catch{}}
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

function Export-PASRunData {
    <#
    .SYNOPSIS
    Writes a sanitized ZIP of one deployment (configuration, plan, status and event journals) for support or documentation.
    .DESCRIPTION
    Accepts the id returned by Invoke-PASInstall, Start-PASEnvironment or the desktop. That is either a single
    engine run or a composed deployment, whose unit runs are included. Credential envelopes, lock files and
    generated payload scripts are never included. Every file is scanned for private keys, credential
    ciphers and password fields; a file with a hit is left out and listed in the result.
    .PARAMETER RunId
    32-character deployment or run id.
    .PARAMETER Path
    ZIP file to create. Default: .\PASeasyInstall-run-<RunId>.zip
    .EXAMPLE
    Export-PASRunData -RunId 688d8e04f1874d41a75cda4441c00553
    .EXAMPLE
    Export-PASRunData -RunId $id -Path C:\Temp\lab-run.zip -Force
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,[string]$Path='',[switch]$Force,[string]$DataRoot='')
    if(-not $DataRoot){$DataRoot=Get-PASDataRoot}
    if(-not $Path){$Path=Join-Path (Get-Location).ProviderPath ("PASeasyInstall-run-$RunId.zip")}
    $Path=[IO.Path]::GetFullPath($Path)
    if((Test-Path -LiteralPath $Path) -and -not $Force){throw "File exists: $Path (use -Force)"}
    $sources=@()
    $fleetDir=Join-Path (Join-Path $DataRoot 'fleets') $RunId
    $runDir=Join-Path (Join-Path $DataRoot 'Runs') $RunId
    if(Test-Path -LiteralPath (Join-Path $fleetDir 'fleet.json')){
        $sources+=@{Root=$fleetDir;Prefix='deployment'}
        $fleet=[IO.File]::ReadAllText((Join-Path $fleetDir 'fleet.json'))|ConvertFrom-Json
        foreach($u in @($fleet.units)){
            $rid=[string]$u.runId
            if($rid -match '^[a-f0-9]{32}$'){$d=Join-Path (Join-Path $DataRoot 'Runs') $rid;if(Test-Path -LiteralPath $d){$sources+=@{Root=$d;Prefix=('runs/'+$rid)}}}
        }
    }elseif(Test-Path -LiteralPath (Join-Path $runDir 'run-v2.json')){
        $sources+=@{Root=$runDir;Prefix=('runs/'+$RunId)}
    }else{throw "No deployment or run $RunId under $DataRoot"}
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

function Close-PASDeployment {
    <#
    .SYNOPSIS
    Closes an unresolved deployment record so its environment can be deployed again. Does not change any server.
    .DESCRIPTION
    A deployment whose outcome is Unknown or Interrupted, or that failed while holding a coordination claim, blocks
    new deployments of the same environment and the servers it claimed. After you have decided what to do with
    those servers (typically: reset or rebuild them), Close-PASDeployment records that decision: it marks the
    unresolved run(s) Abandoned with your reason, writes a RunAbandoned journal event, and releases the controller
    claims owned by those runs. It refuses while a controller of the deployment is still running.
    It never contacts or changes a server. Servers may hold a partial installation; reset them before reinstalling.
    A Linux server also keeps its own lock (~/.paeasyinstall/locks) until it is reset or the lock is removed.
    PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER RunId
    The deployment id returned by Start-PASEnvironment / Invoke-PASInstall, or one engine run id.
    .PARAMETER Reason
    Why the record is closed (kept in the run journal).
    .PARAMETER Force
    Do not ask for confirmation.
    .EXAMPLE
    Close-PASDeployment -RunId 83cf015f78bd4743a54e6d0a9d0dd301 -Reason 'Vault server reset to its clean state'
    #>
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
          [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,[switch]$Force)
    $core=Get-PASOwnCoreModule
    $dataRoot=& $core {Get-PASDataRoot}
    $isFleet=Test-PASFleetId -RunId $RunId -DataRoot $dataRoot
    $runIds=@($RunId); $fleetPath=$null; $fleet=$null
    if($isFleet){
        $fleetPath=Join-Path (Get-PASFleetDirectory $RunId $dataRoot) 'fleet.json'
        $fleet=ConvertTo-PASOrderedHashtable (Read-PASFleetJson $fleetPath)
        if($fleet.controllerPid -and [string]$fleet.status -in @('Launching','Running') -and (Get-Process -Id ([int]$fleet.controllerPid) -ErrorAction SilentlyContinue)){
            throw "Deployment $RunId is still running (controller process $($fleet.controllerPid)). Wait for it or stop it first."
        }
        $runIds=@($fleet.units|Where-Object {$_.runId}|ForEach-Object {[string]$_.runId})
    }
    $runs=@()
    foreach($id in $runIds){
        $run=& $core {param($i,$d) Get-PASRunRecord -RunId $i -DataRoot $d} $id $dataRoot
        if(-not $run){continue}
        if([string]$run.status -in @('Launching','Running')){throw "Run $id is still running. Wait for it or stop its controller first."}
        $runs+=,$run
    }
    $root=& $core {Get-PASCoordinationRoot}
    $claims=@(Get-ChildItem -LiteralPath $root -Force -Filter '*.json' -ErrorAction SilentlyContinue|Where-Object {
        $c=$null; try{$c=Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json}catch{}; $c -and [string]$c.RunId -in $runIds })
    $toAbandon=@($runs|Where-Object {[string]$_.status -in @('Unknown','Interrupted','LaunchFailed','Failed')})
    $what="$(@($toAbandon).Count) run(s) marked Abandoned, $($claims.Count) controller claim(s) released; servers are not changed"
    if(-not ($Force -or $PSCmdlet.ShouldProcess($RunId,$what))){return}
    foreach($run in $toAbandon){
        $dir=& $core {param($i,$d) Get-PASRunDirectory $i $d} ([string]$run.id) $dataRoot
        $path=Join-Path $dir 'run-v2.json'
        $h=ConvertTo-PASOrderedHashtable (Get-Content -LiteralPath $path -Raw|ConvertFrom-Json)
        $previous=[string]$h.status
        $h.status='Abandoned';$h.message="Abandoned by operator (was $previous): $Reason";$h.finishedUtc=[DateTime]::UtcNow.ToString('o')
        & $core {param($p,$d) Write-PASJsonAtomic -Path $p -Data $d} $path $h
        $evt=[ordered]@{timestampUtc=[DateTime]::UtcNow.ToString('o');event='RunAbandoned';component='';message=$h.message}
        Add-Content -LiteralPath (Join-Path $dir 'events-v2.jsonl') -Value ($evt|ConvertTo-Json -Compress) -Encoding UTF8
    }
    foreach($c in $claims){Remove-Item -LiteralPath $c.FullName -Force}
    if($isFleet -and [string]$fleet.status -notin @('Succeeded')){
        $fleet.status='Abandoned';$fleet.message="Abandoned by operator: $Reason";$fleet.finishedUtc=[DateTime]::UtcNow.ToString('o')
        Write-PASFleetJson $fleetPath $fleet
        Write-PASFleetEvent (Split-Path -Parent $fleetPath) 'RunAbandoned' $fleet.message
    }
    [pscustomobject]@{RunId=$RunId;AbandonedRuns=@($toAbandon|ForEach-Object {[string]$_.id});ReleasedClaims=$claims.Count
        Note='No server was changed. Reset servers that may hold a partial installation before deploying again.'}
}
