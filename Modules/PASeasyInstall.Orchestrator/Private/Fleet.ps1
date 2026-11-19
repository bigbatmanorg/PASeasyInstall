# Fleet runner: executes a composed configuration (New-PASDeploymentConfiguration) as a set of
# ordinary engine runs ("units"), so every server is installed by the same durable, resumable,
# Vault-session-serialised engine path that the per-component CLI uses.
#
#   unit 'vault'      : Primary Vault (+ DR) — always first
#   unit <component>  : one engine run per component instance (existing-Vault configuration)
#
# Sequential: one unit at a time in plan order. Parallel: after the Vault unit, every unit whose
# dependencies are met starts at once, one unit per server at a time. Registration and any other
# authenticated Vault work is still serialised by the engine's Vault gate across processes.
# CPM units that pin a PVWA certificate start after that PVWA unit; the certificate is read from the
# PVWA server over the authenticated management channel. Linux servers get the controller's key on
# first use (password bootstrap) before their unit starts.

function Get-PASFleetRoot {param([string]$DataRoot=(Get-PASOrchestratorDataRoot)) return (Join-Path $DataRoot 'fleets')}
function Get-PASFleetDirectory {
    param([Parameter(Mandatory)][string]$FleetId,[string]$DataRoot=(Get-PASOrchestratorDataRoot))
    if($FleetId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid deployment id'}
    return (Join-Path (Get-PASFleetRoot $DataRoot) $FleetId)
}
function Test-PASFleetId {param([string]$RunId,[string]$DataRoot=(Get-PASOrchestratorDataRoot))
    if($RunId -notmatch '^[a-f0-9]{32}$'){return $false}
    return (Test-Path -LiteralPath (Join-Path (Get-PASFleetDirectory $RunId $DataRoot) 'fleet.json') -PathType Leaf)
}
function Read-PASFleetJson {param([string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    for($i=0;$i -lt 5;$i++){try{return ([IO.File]::ReadAllText($Path)|ConvertFrom-Json)}catch{Start-Sleep -Milliseconds 100}}
    throw "Unreadable fleet journal: $Path"
}
function Write-PASFleetJson {param([string]$Path,$Data)
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($tmp,($Data|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,[NullString]::Value)}else{[IO.File]::Move($tmp,$Path)}
}
function Write-PASFleetEvent {
    param([string]$Dir,[string]$Event,[string]$Message,[string]$Component='',[string]$Stage='',[ValidateSet('Information','Warning','Error')][string]$Level='Information')
    $line=[ordered]@{timestampUtc=[DateTime]::UtcNow.ToString('o');event=$Event;component=$Component;taskId=$Stage;level=$Level;message=$Message}
    [IO.File]::AppendAllText((Join-Path $Dir 'events.jsonl'),(($line|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function Copy-PASConfiguration {param($Configuration) return (ConvertTo-PASOrchestratorHashtable (($Configuration|ConvertTo-Json -Depth 60)|ConvertFrom-Json))}
function ConvertTo-PASOrchestratorHashtable {
    param($Value)
    if($null -eq $Value){return $null}
    if($Value -is [string] -or $Value -is [ValueType]){return $Value}
    if($Value -is [System.Collections.IDictionary]){$h=[ordered]@{};foreach($k in $Value.Keys){$h[[string]$k]=ConvertTo-PASOrchestratorHashtable $Value[$k]};return $h}
    if($Value -is [pscustomobject]){$h=[ordered]@{};foreach($p in $Value.PSObject.Properties){$h[$p.Name]=ConvertTo-PASOrchestratorHashtable $p.Value};return $h}
    if($Value -is [System.Collections.IEnumerable]){return ,@(foreach($i in $Value){ConvertTo-PASOrchestratorHashtable $i})}
    return $Value
}

function Get-PASFleetUnits {
    <# Ordered units with dependencies. Plan order: Vault/DR, PVWA, CPM, PSM, PSMP. Non-PVWA components wait for the first PVWA. #>
    param($Configuration)
    $priority=@{PVWA=30;CPM=40;PSM=50;PSMP=60;PTA=70}
    $comps=@($Configuration.components|Where-Object {$_})
    $units=New-Object System.Collections.ArrayList
    $vault=@($comps|Where-Object {$_.type -in @('Vault','DRVault')})
    if($vault.Count){
        [void]$units.Add([ordered]@{id='vault';components=@($vault|ForEach-Object {[string]$_.id});hosts=@($vault|ForEach-Object {[string]$_.host});dependsOn=@();status='Pending';runId='';message=''})
    }
    $others=@($comps|Where-Object {$_.type -notin @('Vault','DRVault','AD')}|Sort-Object @{Expression={[int]$priority[[string]$_.type]}},@{Expression={[string]$_.id}})
    foreach($e in $others){
        $deps=@(); if($vault.Count){$deps+='vault'}
        $opts=if($e.Contains('options')){$e.options}else{@{}}
        if($opts -and $opts.Contains('pvwaTrustFrom')){$deps+=[string]$opts.pvwaTrustFrom}
        # PVWA registration creates the PVWA environment in the Vault (PVWAConfig safe, PVWAGWAccounts group) that
        # CPM, PSM and PSMP registration need. Every other component waits for the first PVWA of the deployment.
        $firstPvwa=@($others|Where-Object {$_.type -eq 'PVWA'}|Select-Object -First 1)
        if($e.type -ne 'PVWA' -and $firstPvwa.Count){$deps+=[string]$firstPvwa[0].id}
        [void]$units.Add([ordered]@{id=[string]$e.id;components=@([string]$e.id);hosts=@([string]$e.host);dependsOn=@($deps|Select-Object -Unique);status='Pending';runId='';message=''})
    }
    return @($units.ToArray())
}
function New-PASFleetChildConfiguration {
    <# The engine configuration for one unit. Component units target the (new or existing) Vault as an
       existing Vault; their environment name is unique so units can run concurrently. #>
    param($Configuration,$Unit,[hashtable]$Trust=@{})
    $c=Copy-PASConfiguration $Configuration
    $c.Remove('execution')
    $ids=@($Unit.components)
    $comps=@($c.components|Where-Object {[string]$_.id -in $ids})
    if($Unit.id -eq 'vault'){
        $c.components=$comps
        $keep=@($comps|ForEach-Object {[string]$_.host}|Select-Object -Unique)
        foreach($k in @($c.hosts.Keys)){if($k -notin $keep){$c.hosts.Remove($k)}}
        foreach($k in @($c.security.overrides.Keys)){if($k -notmatch '^(WinRM|Vault)\.'){$c.security.overrides.Remove($k)}}
        return $c
    }
    $e=$comps[0]
    $c.name=(([string]$Configuration.name)+'-'+[string]$e.id); if($c.name.Length -gt 64){$c.name=$c.name.Substring(0,64)}
    $c.vault.existing=$true; $c.mediaRoot=''; $c.media=[ordered]@{}
    $keepHosts=@([string]$e.host)
    if($e.type -eq 'PTA' -and $c.vault.Contains('managementHost') -and $c.vault.managementHost){$keepHosts+=[string]$c.vault.managementHost}
    elseif($c.vault.Contains('managementHost')){$c.vault.Remove('managementHost')}
    foreach($k in @($c.hosts.Keys)){if($k -notin $keepHosts){$c.hosts.Remove($k)}}
    if($e.Contains('options') -and $e.options.Contains('pvwaTrustFrom')){
        $src=[string]$e.options.pvwaTrustFrom
        if(-not $Trust.ContainsKey($src)){throw "PVWA certificate from '$src' has not been captured"}
        $e.options.Remove('pvwaTrustFrom')
        $e.options.pvwaTrustCertificateFile=[string]$Trust[$src].File
        $e.options.pvwaTrustCertificateSHA256=[string]$Trust[$src].SHA256
    }
    $prefix=[string]$e.type+'.'
    $windows=@($c.hosts.Values|Where-Object {$_.os -eq 'Windows'}).Count -gt 0
    foreach($k in @($c.security.overrides.Keys)){if(-not (($windows -and $k.StartsWith('WinRM.')) -or $k.StartsWith($prefix))){$c.security.overrides.Remove($k)}}
    if(-not $c.security.overrides.Count){$c.security.profile=[string]$Configuration.security.profile}
    $c.components=@($e)
    return $c
}

function ConvertTo-PASControllerCredentialMap {
    <# WinRM from a workgroup controller needs an explicit local account: 'Administrator' becomes
       '.\Administrator' (the target's own account), as the management endpoint expects. #>
    param($Configuration,[hashtable]$CredentialMap)
    $out=@{}
    foreach($key in @($CredentialMap.Keys)){
        $cred=$CredentialMap[$key]
        if($cred -isnot [pscredential]){throw "CredentialMap[$key] must be a PSCredential"}
        $hostRecord=$null
        if($Configuration.hosts.Contains([string]$key)){$hostRecord=$Configuration.hosts[[string]$key]}
        else{$e=@($Configuration.components|Where-Object {$_.id -eq $key});if($e.Count){$hostRecord=$Configuration.hosts[[string]$e[0].host]}}
        $user=[string]$cred.UserName
        if($hostRecord -and $hostRecord.os -eq 'Windows' -and $user -and $user -notmatch '[\\@]'){$cred=[pscredential]::new('.\'+$user,$cred.Password)}
        $out[$key]=$cred
    }
    return $out
}

function Save-PASFleetEnvelope {
    param([string]$Path,[hashtable]$Credentials,[hashtable]$Secrets)
    $data=[ordered]@{credentials=[ordered]@{};secrets=[ordered]@{}}
    foreach($k in $Credentials.Keys){$data.credentials[$k]=[ordered]@{user=$Credentials[$k].UserName;cipher=($Credentials[$k].Password|ConvertFrom-SecureString)}}
    foreach($k in $Secrets.Keys){$data.secrets[$k]=($Secrets[$k]|ConvertFrom-SecureString)}
    [IO.File]::WriteAllText($Path,($data|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
}
function Read-PASFleetEnvelope {
    param([string]$Path)
    $d=[IO.File]::ReadAllText($Path)|ConvertFrom-Json
    $creds=@{};$secrets=@{}
    foreach($p in $d.credentials.PSObject.Properties){$creds[$p.Name]=[pscredential]::new([string]$p.Value.user,($p.Value.cipher|ConvertTo-SecureString))}
    foreach($p in $d.secrets.PSObject.Properties){$secrets[$p.Name]=($p.Value|ConvertTo-SecureString)}
    return @{Credentials=$creds;Secrets=$secrets}
}

function Start-PASFleet {
    param([Parameter(Mandatory)]$Configuration,[hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},[string]$DataRoot=(Get-PASOrchestratorDataRoot),[switch]$Foreground)
    if(-not $Foreground -and $env:OS -ne 'Windows_NT'){throw 'Deployments run from a Windows PowerShell 5.1 controller; this computer can review plans only'}
    $c=Copy-PASConfiguration $Configuration
    $root=Get-PASFleetRoot $DataRoot
    if(-not(Test-Path -LiteralPath $root)){New-Item -ItemType Directory -Path $root -Force|Out-Null}
    foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)){
        $f=Read-PASFleetJson (Join-Path $dir.FullName 'fleet.json')
        if($f -and [string]$f.name -eq [string]$c.name -and [string]$f.status -in @('Launching','Running')){
            # A record whose controller never started, or whose controller process is gone, is not running.
            # The engine's own host/environment claims still protect the servers of any interrupted unit.
            $pidAlive=$false
            if($f.controllerPid){$pidAlive=[bool](Get-Process -Id ([int]$f.controllerPid) -ErrorAction SilentlyContinue)}
            $started=[DateTime]::MinValue; [void][DateTime]::TryParse([string]$f.startedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal,[ref]$started)
            $stale=(([string]$f.status -eq 'Launching' -and -not $f.controllerPid -and ([DateTime]::UtcNow-$started).TotalMinutes -gt 2) -or ($f.controllerPid -and -not $pidAlive))
            if(-not $stale){throw "Environment '$($c.name)' already has deployment $($f.id) running"}
            $h=ConvertTo-PASOrchestratorHashtable $f
            $h.status=if($f.controllerPid){'Interrupted'}else{'LaunchFailed'}
            $h.message='No deployment controller is running for this record; resume its units with Resume-PASeasyDeployment if needed'
            Write-PASFleetJson (Join-Path $dir.FullName 'fleet.json') $h
        }
    }
    $creds=ConvertTo-PASControllerCredentialMap $c $CredentialMap
    $id=[guid]::NewGuid().ToString('N')
    $dir=Get-PASFleetDirectory $id $DataRoot
    New-Item -ItemType Directory -Path $dir -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'config.json'),($c|ConvertTo-Json -Depth 60),(New-Object Text.UTF8Encoding($false)))
    $fleet=[ordered]@{schemaVersion=1;id=$id;name=[string]$c.name;mode=[string]$c.execution.mode;status='Launching';startedUtc=[DateTime]::UtcNow.ToString('o');finishedUtc=$null;controllerPid=$null;message='Starting deployment controller';units=@(Get-PASFleetUnits $c)}
    Write-PASFleetJson (Join-Path $dir 'fleet.json') $fleet
    Write-PASFleetEvent $dir 'DeploymentStarted' ("$($fleet.mode) deployment of $(@($fleet.units).Count) unit(s): "+((@($fleet.units)|ForEach-Object {$_.id}) -join ', '))
    if($Foreground){Invoke-PASFleetController -FleetId $id -DataRoot $DataRoot -InMemoryAuth @{Credentials=$creds;Secrets=$SecretMap};return $id}
    $envelope=Join-Path $dir ('auth-'+[guid]::NewGuid().ToString('N')+'.json')
    try{
        Save-PASFleetEnvelope $envelope $creds $SecretMap
        $script=Join-Path (Split-Path -Parent $PSScriptRoot) 'Controllers\Invoke-PASFleetController.ps1'
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$script+'" -FleetId "'+$id+'" -DataRoot "'+$DataRoot+'" -Envelope "'+$envelope+'"'
        # Same launch style as the engine controller: survives the UI window and SSH sessions.
        $startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0;CreateFlags=[uint32]16}
        $spawn=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=('"'+$exe+'" '+$args);CurrentDirectory=$dir;ProcessStartupInformation=$startup}
    }catch{
        if(Test-Path -LiteralPath $envelope){Remove-Item -LiteralPath $envelope -Force -ErrorAction SilentlyContinue}
        $why=$_.Exception.Message
        if($_.Exception -is [Security.Cryptography.CryptographicException] -or $why -match 'Access is denied'){
            $why='Credentials could not be protected with Windows DPAPI in this session. Start the deployment from a local session on the controller (console or RDP), not from a remote PowerShell session.'
        }
        $fleet.status='LaunchFailed';$fleet.message="Deployment controller not started: $why"
        Write-PASFleetJson (Join-Path $dir 'fleet.json') $fleet
        throw $fleet.message
    }
    if($spawn.ReturnValue -ne 0 -or -not $spawn.ProcessId){
        if(Test-Path -LiteralPath $envelope){Remove-Item -LiteralPath $envelope -Force}
        $fleet.status='LaunchFailed';$fleet.message="Cannot start deployment controller: Win32_Process.Create=$($spawn.ReturnValue)"
        Write-PASFleetJson (Join-Path $dir 'fleet.json') $fleet
        throw $fleet.message
    }
    return $id
}

function Invoke-PASFleetController {
    param([Parameter(Mandatory)][string]$FleetId,[string]$DataRoot=(Get-PASOrchestratorDataRoot),[string]$Envelope='',[hashtable]$InMemoryAuth)
    $dir=Get-PASFleetDirectory $FleetId $DataRoot
    $fleetPath=Join-Path $dir 'fleet.json'
    $auth=if($InMemoryAuth){$InMemoryAuth}else{$a=Read-PASFleetEnvelope $Envelope;Remove-Item -LiteralPath $Envelope -Force;$a}
    $c=ConvertTo-PASOrchestratorHashtable ([IO.File]::ReadAllText((Join-Path $dir 'config.json'))|ConvertFrom-Json)
    $f=ConvertTo-PASOrchestratorHashtable (Read-PASFleetJson $fleetPath)
    $f.status='Running';$f.controllerPid=$PID;$f.message='Deploying';Write-PASFleetJson $fleetPath $f
    $parallel=([string]$f.mode -eq 'Parallel')
    $trust=@{}
    $lab=([string]$c.security.profile -eq 'Lab')
    try{
        while($true){
            $units=@($f.units)
            # 1. observe running units
            foreach($u in @($units|Where-Object {$_.status -eq 'Running'})){
                $run=Get-PASeasyRun -RunId ([string]$u.runId) -DataRoot $DataRoot
                $s=if($run){[string]$run.status}else{'Unknown'}
                if($s -eq 'Succeeded'){$u.status='Succeeded';$u.message='Installed and verified';Write-PASFleetEvent $dir 'UnitCompleted' "Unit $($u.id) succeeded (run $($u.runId))" ([string]$u.id)}
                elseif($s -in @('Failed','LaunchFailed','Unknown','Interrupted')){$u.status='Failed';$u.message=[string]$run.message;Write-PASFleetEvent $dir 'UnitFailed' "Unit $($u.id) ended $s (run $($u.runId)): $($run.message)" ([string]$u.id) '' 'Error'}
            }
            $failed=@($units|Where-Object {$_.status -eq 'Failed'}).Count
            $running=@($units|Where-Object {$_.status -eq 'Running'})
            # 2. start what may start (nothing new after a failure)
            if(-not $failed){
                foreach($u in @($units|Where-Object {$_.status -eq 'Pending'})){
                    $running=@($units|Where-Object {$_.status -eq 'Running'})
                    if(-not $parallel -and $running.Count){break}
                    $depsOk=$true;foreach($d in @($u.dependsOn|Where-Object {$_})){if(@($units|Where-Object {$_.id -eq $d -and $_.status -eq 'Succeeded'}).Count -eq 0){$depsOk=$false}}
                    if(-not $depsOk){if(-not $parallel){break};continue}
                    $busy=@($running|Where-Object {@($_.hosts|Where-Object {$_ -in @($u.hosts)}).Count})
                    if($busy.Count){continue}
                    Start-PASFleetUnit -Fleet $f -Unit $u -Configuration $c -Directory $dir -DataRoot $DataRoot -Auth $auth -Trust $trust -Lab $lab
                    Write-PASFleetJson $fleetPath $f
                    if(-not $parallel){break}
                }
            }
            $units=@($f.units)
            $running=@($units|Where-Object {$_.status -eq 'Running'})
            $failed=@($units|Where-Object {$_.status -eq 'Failed'}).Count
            if(-not $running.Count){
                if($failed){
                    foreach($u in @($units|Where-Object {$_.status -eq 'Pending'})){$u.status='Skipped';$u.message='Not started because another unit failed'}
                    $f.status='Failed';$f.message=('Failed: '+((@($units|Where-Object {$_.status -eq 'Failed'})|ForEach-Object {$_.id+': '+$_.message}) -join '; '))
                    break
                }
                if(@($units|Where-Object {$_.status -eq 'Pending'}).Count -eq 0){$f.status='Succeeded';$f.message='All selected component workflows completed';break}
            }
            $f.currentComponent=((@($running)|ForEach-Object {$_.id}) -join ',')
            Write-PASFleetJson $fleetPath $f
            Start-Sleep -Seconds 3
        }
    }catch{
        $f.status='Failed';$f.message='Deployment controller error: '+$_.Exception.Message
        Write-PASFleetEvent $dir 'ControllerFailed' $f.message '' '' 'Error'
    }finally{
        $f.finishedUtc=[DateTime]::UtcNow.ToString('o');$f.currentComponent=''
        Write-PASFleetJson $fleetPath $f
        Write-PASFleetEvent $dir $(if($f.status -eq 'Succeeded'){'RunCompleted'}else{'RunFailed'}) $f.message '' '' $(if($f.status -eq 'Succeeded'){'Information'}else{'Error'})
    }
}

function Start-PASFleetUnit {
    param($Fleet,$Unit,$Configuration,[string]$Directory,[string]$DataRoot,[hashtable]$Auth,[hashtable]$Trust,[bool]$Lab)
    try{
        $comp=@($Configuration.components|Where-Object {$_.id -eq @($Unit.components)[0]})[0]
        if($comp.Contains('options') -and $comp.options.Contains('pvwaTrustFrom')){
            $src=[string]$comp.options.pvwaTrustFrom
            if(-not $Trust.ContainsKey($src)){$Trust[$src]=Get-PASFleetPVWACertificate -Configuration $Configuration -PvwaId $src -Credentials $Auth.Credentials -Directory $Directory}
        }
        foreach($hostId in @($Unit.hosts)){
            $h=$Configuration.hosts[$hostId]
            if($h.os -eq 'Linux'){Invoke-PASSshBootstrap -HostId $hostId -HostRecord $h -Credential $Auth.Credentials[$hostId] -Lab $Lab -Directory $Directory}
        }
        $child=New-PASFleetChildConfiguration -Configuration $Configuration -Unit $Unit -Trust $Trust
        $valid=Test-PASeasyConfig -Configuration $child -CheckMedia
        if(-not $valid.Valid){throw ('Configuration check failed: '+($valid.Issues -join '; '))}
        foreach($cid in @($Unit.components)){Write-PASFleetEvent $Directory 'TaskCompleted' 'Local configuration and media checks passed' $cid 'LocalPreflight'}
        $winCreds=@{}
        foreach($k in $Auth.Credentials.Keys){
            $hostRecord=$null
            if($child.hosts.Contains([string]$k)){$hostRecord=$child.hosts[[string]$k]}
            if($hostRecord -and $hostRecord.os -eq 'Windows'){$winCreds[$k]=$Auth.Credentials[$k]}
        }
        $runId=Start-PASeasyDeployment -Configuration $child -CredentialMap $winCreds -SecretMap $Auth.Secrets -Confirm:$false
        $Unit.runId=[string]$runId;$Unit.status='Running';$Unit.message='Running'
        Write-PASFleetEvent $Directory 'UnitStarted' "Unit $($Unit.id) started as engine run $runId" ([string]$Unit.id)
    }catch{
        $Unit.status='Failed';$Unit.message=$_.Exception.Message
        Write-PASFleetEvent $Directory 'UnitFailed' "Unit $($Unit.id) could not start: $($_.Exception.Message)" ([string]@($Unit.components)[0]) 'LocalPreflight' 'Error'
    }
}

function New-PASFleetWinRMSession {
    param($Configuration,[string]$HostId,[pscredential]$Credential)
    $h=$Configuration.hosts[$HostId]
    $useSsl=$true
    $ov=$Configuration.security.overrides
    $lab=([string]$Configuration.security.profile -eq 'Lab')
    if($lab -and $ov.Contains('WinRM.RequireHTTPS')){$useSsl=[bool]$ov['WinRM.RequireHTTPS']}
    if($h.Contains('useSsl')){$useSsl=[bool]$h.useSsl}
    $opt=@{}
    if($lab -and $ov.Contains('WinRM.SkipCACheck') -and [bool]$ov['WinRM.SkipCACheck']){$opt.SkipCACheck=$true}
    if($lab -and $ov.Contains('WinRM.SkipCNCheck') -and [bool]$ov['WinRM.SkipCNCheck']){$opt.SkipCNCheck=$true}
    $last=$null
    foreach($endpoint in @('PASeasyInstall.Management','Microsoft.PowerShell')){
        try{
            $p=@{ComputerName=[string]$h.address;Credential=$Credential;Authentication='Negotiate';ConfigurationName=$endpoint;SessionOption=(New-PSSessionOption @opt);ErrorAction='Stop'}
            if($useSsl){$p.UseSSL=$true}
            return (New-PSSession @p)
        }catch{$last=$_}
    }
    throw "Cannot open a management session to $HostId ($($h.address)): $($last.Exception.Message)"
}
function Get-PASFleetPVWACertificate {
    <# Reads the certificate bound to PVWA's HTTPS port from the PVWA server itself (authenticated),
       stores the public DER next to the deployment journal and returns @{File;SHA256}. #>
    param($Configuration,[string]$PvwaId,[hashtable]$Credentials,[string]$Directory)
    $e=@($Configuration.components|Where-Object {$_.id -eq $PvwaId})[0]
    $hostId=[string]$e.host
    $cred=$Credentials[$hostId]; if(-not $cred){$cred=$Credentials[$PvwaId]}
    if(-not $cred){throw "No credential for PVWA server $hostId"}
    $s=New-PASFleetWinRMSession -Configuration $Configuration -HostId $hostId -Credential $cred
    try{
        $b64=Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {
            $thumb=$null;$store='My'
            try{
                Import-Module WebAdministration -ErrorAction Stop
                $b=@(Get-ChildItem IIS:\SslBindings -ErrorAction Stop|Where-Object {$_.Port -eq 443})|Select-Object -First 1
                if($b){$thumb=[string]$b.Thumbprint;if($b.Store){$store=[string]$b.Store}}
            }catch{}
            if(-not $thumb){
                $out=(& netsh.exe http show sslcert ipport=0.0.0.0:443) -join "`n"
                if($out -match 'Certificate Hash\s*:\s*([0-9a-fA-F]{40})'){$thumb=$Matches[1]}
                if($out -match 'Certificate Store Name\s*:\s*(\S+)' -and $Matches[1] -ne '(null)'){$store=$Matches[1]}
            }
            if(-not $thumb){throw 'PVWA has no certificate bound to HTTPS port 443'}
            $cert=Get-Item -LiteralPath ('Cert:\LocalMachine\'+$store+'\'+$thumb) -ErrorAction Stop
            [Convert]::ToBase64String($cert.RawData)
        }
    }finally{Remove-PSSession $s -ErrorAction SilentlyContinue}
    $bytes=[Convert]::FromBase64String([string]$b64)
    $file=Join-Path $Directory ('pvwa-trust-'+$PvwaId+'.cer')
    [IO.File]::WriteAllBytes($file,$bytes)
    $sha=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    $subject=([Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)).Subject
    Write-PASFleetEvent $Directory 'PVWATrustCaptured' "Captured $PvwaId HTTPS certificate $subject (SHA256 $sha) for CPM pinning" $PvwaId
    return @{File=$file;SHA256=$sha}
}

function Invoke-PASNativeQuiet {
    <# Runs an OpenSSH tool and returns @{ExitCode;Output}. On Windows the tool runs under cmd.exe with
       native file redirection in a hidden console (Win32 OpenSSH can hang when PowerShell captures its
       streams), bounded by a timeout, the same way the engine observes SSH. #>
    param([string]$Exe,[string[]]$Arguments,[int]$TimeoutSeconds=90)
    if($env:OS -ne 'Windows_NT'){
        $saved=$ErrorActionPreference; $ErrorActionPreference='Continue'
        try{$out=@() | & $Exe @Arguments 2>&1; $code=$LASTEXITCODE}finally{$ErrorActionPreference=$saved}
        return @{ExitCode=$code;Output=(@($out|ForEach-Object {[string]$_}) -join "`n")}
    }
    foreach($arg in @($Exe)+@($Arguments)){if([string]$arg -match '["%!\r\n]'){throw 'Unsupported character in an SSH tool argument'}}
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('paseasy-tool-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force|Out-Null
    $process=$null
    try{
        $stdout=Join-Path $tmp 'out.txt';$stderr=Join-Path $tmp 'err.txt';$batch=Join-Path $tmp 'run.cmd'
        $quoted=@(@($Exe)+@($Arguments)|ForEach-Object {'"'+[string]$_+'"'}) -join ' '
        [IO.File]::WriteAllText($batch,("@echo off`r`n"+$quoted+' <nul >"'+$stdout+'" 2>"'+$stderr+'"'+"`r`nexit /b %errorlevel%`r`n"),[Text.Encoding]::Default)
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$env:ComSpec;$info.Arguments='/d /s /c ""'+$batch+'""';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info
        if(-not $process.Start()){throw "Cannot start $Exe"}
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){& taskkill.exe /PID $process.Id /T /F 2>&1|Out-Null;return @{ExitCode=124;Output="$Exe timed out after $TimeoutSeconds s"}}
        $text=''
        for($i=0;$i -lt 20;$i++){try{$text=$(if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''})+$(if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''});break}catch [IO.IOException]{Start-Sleep -Milliseconds 100}}
        return @{ExitCode=$process.ExitCode;Output=$text.TrimEnd()}
    }finally{if($process){$process.Dispose()};Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
}
function Assert-PASSshRoot {
    <# Linux stages install packages, write /opt/paeasyinstall and systemd units: they run as root. Checked
       right after key sign-in works, so a non-root account fails here with a clear message instead of
       halfway through the media upload. #>
    param([string]$Key,[object[]]$Base,[string]$User,[string]$Address)
    $r=Invoke-PASNativeQuiet 'ssh.exe' (@('-i',$Key,'-o','BatchMode=yes','-o','IdentitiesOnly=yes')+$Base+@(($User+'@'+$Address),'id -u'))
    $uid=([string]$r.Output).Trim()
    if($r.ExitCode -ne 0 -or $uid -ne '0'){
        throw "PASeasyInstall signs in to Linux servers as root, but $User@$Address is not root (uid '$uid'). Use the root account: allow root to sign in with its password once (for example 'PermitRootLogin yes' while you install), or authorise the controller key for root."
    }
}
function Invoke-PASSshBootstrap {
    <# Makes key-based SSH work for one Linux server:
         1. the controller key exists (generated once per environment, private to this user);
         2. the server's host key is known (Lab: accepted on first use and logged as a deviation;
            Secure: must already be in the known_hosts file);
         3. if the key is not yet authorised, the server password (from the UI/CredentialMap) is used
            once, through SSH_ASKPASS, to append the public key to the account's authorized_keys.
       The password never appears on a command line or in a file. #>
    param([string]$HostId,$HostRecord,[pscredential]$Credential,[bool]$Lab,[string]$Directory)
    $addr=[string]$HostRecord.address; $user=[string]$HostRecord.user
    $port=''; if($HostRecord.Contains('port') -and $HostRecord.port){$port=[string][int]$HostRecord.port}
    $knownName=if($port -and $port -ne '22'){'['+$addr+']:'+$port}else{$addr}
    $key=[string]$HostRecord.identityFile; $known=[string]$HostRecord.knownHostsFile
    if(-not $key -or -not $known){throw "Linux server $HostId needs identityFile and knownHostsFile"}
    foreach($d in @([IO.Path]::GetDirectoryName($key),[IO.Path]::GetDirectoryName($known))){if(-not(Test-Path -LiteralPath $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}}
    if(-not(Test-Path -LiteralPath $key -PathType Leaf)){
        $r=Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-q','-t','ed25519','-N','','-C',('paseasyinstall@'+$env:COMPUTERNAME),'-f',$key)
        if($r.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $key)){throw "Cannot create the controller SSH key: $($r.Output)"}
        Write-PASFleetEvent $Directory 'SshKeyCreated' "Created controller SSH key $key" $HostId
    }
    if(-not(Test-Path -LiteralPath $known -PathType Leaf)){[IO.File]::WriteAllText($known,'')}
    $r=Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-F',$knownName,'-f',$known)
    if($r.ExitCode -ne 0){
        if(-not $Lab){throw "SSH host key of $addr is not in $known. Add the verified host key (Secure profile never trusts on first use)."}
        # Trust on first use: one key-exchange-only probe records the ed25519 host key (authentication
        # is not attempted). ssh-keyscan is avoided: it can hang on Windows OpenSSH.
        $tofu=@('-o','StrictHostKeyChecking=accept-new','-o',('UserKnownHostsFile='+$known),'-o','HostKeyAlgorithms=ssh-ed25519','-o','BatchMode=yes',
            '-o','PreferredAuthentications=none','-o','ConnectTimeout=15','-n'); if($port){$tofu+=@('-p',$port)}
        $null=Invoke-PASNativeQuiet 'ssh.exe' ($tofu+@(($user+'@'+$addr),'true'))
        $r=Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-F',$knownName,'-f',$known)
        if($r.ExitCode -ne 0){throw "Cannot read the SSH host key of $addr"}
        $fp=(Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-l','-F',$knownName,'-f',$known)).Output
        Write-PASFleetEvent $Directory 'Warning' ("SECURITY DEVIATION (Lab): trusted SSH host key of $addr on first use. "+(($fp -split "`n"|Where-Object {$_ -match 'SHA256'})-join ' ')) $HostId 'ssh-bootstrap' 'Warning'
    }
    $base=@('-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),'-o','ConnectTimeout=15','-n')
    if($port){$base+=@('-p',$port)}
    $probe=Invoke-PASNativeQuiet 'ssh.exe' (@('-i',$key,'-o','BatchMode=yes','-o','IdentitiesOnly=yes')+$base+@(($user+'@'+$addr),'true'))
    if($probe.ExitCode -eq 0){Assert-PASSshRoot $key $base $user $addr;Write-PASFleetEvent $Directory 'TaskCompleted' "Key-based SSH to $user@$addr works" $HostId 'ssh-bootstrap';return}
    $pub=([IO.File]::ReadAllText($key+'.pub')).Trim()
    if(-not $Credential -or $Credential.Password.Length -eq 0){throw "Key-based SSH to $user@$addr is not authorised and no password was given. Authorise this key for $user on the server: $pub"}
    if($pub -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+ [A-Za-z0-9@._-]+$'){throw 'Unexpected controller public key format'}
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('paseasy-askpass-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force|Out-Null
    $askpass=Join-Path $tmp 'askpass.cmd'
    [IO.File]::WriteAllText($askpass,"@echo off`r`npowershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"[Console]::Out.Write(`$env:PASEASY_ASKPASS)`"`r`n")
    $saved=@{}
    foreach($n in @('SSH_ASKPASS','SSH_ASKPASS_REQUIRE','DISPLAY','PASEASY_ASKPASS')){$saved[$n]=[Environment]::GetEnvironmentVariable($n,'Process')}
    try{
        [Environment]::SetEnvironmentVariable('SSH_ASKPASS',$askpass,'Process')
        [Environment]::SetEnvironmentVariable('SSH_ASKPASS_REQUIRE','force','Process')
        [Environment]::SetEnvironmentVariable('DISPLAY','paseasyinstall:0','Process')
        [Environment]::SetEnvironmentVariable('PASEASY_ASKPASS',$Credential.GetNetworkCredential().Password,'Process')
        $cmd="umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys)"
        $r=Invoke-PASNativeQuiet 'ssh.exe' (@('-o','BatchMode=no','-o','PubkeyAuthentication=no','-o','PreferredAuthentications=password,keyboard-interactive','-o','NumberOfPasswordPrompts=1')+$base+@(($user+'@'+$addr),$cmd))
    }finally{
        foreach($n in $saved.Keys){[Environment]::SetEnvironmentVariable($n,$saved[$n],'Process')}
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if($r.ExitCode -ne 0){throw "Password sign-in to $user@$addr failed (the server may refuse password logins for $user). Authorise this key for $user on the server instead: $pub"}
    $probe=Invoke-PASNativeQuiet 'ssh.exe' (@('-i',$key,'-o','BatchMode=yes','-o','IdentitiesOnly=yes')+$base+@(($user+'@'+$addr),'true'))
    if($probe.ExitCode -ne 0){throw "The controller key was added for $user@$addr but key sign-in still fails: $($probe.Output)"}
    Assert-PASSshRoot $key $base $user $addr
    Write-PASFleetEvent $Directory 'TaskCompleted' "Authorised the controller key for $user@$addr (password used once, not stored)" $HostId 'ssh-bootstrap'
}

# ---- normalized progress for the UI
function ConvertTo-PASUIComponentId {
    <# The Vault engine journals its two roles as primary/primary_final and dr/dr_final. #>
    param([string]$Component)
    switch -Regex ($Component){'^primary(_final)?$'{return 'vault'} '^dr(_final)?$'{return 'dr'} default{return $Component}}
}
function Get-PASFleetEvents {
    param([string]$FleetId,[string]$DataRoot=(Get-PASOrchestratorDataRoot),[int]$Tail=150)
    $dir=Get-PASFleetDirectory $FleetId $DataRoot
    $events=New-Object System.Collections.ArrayList
    $file=Join-Path $dir 'events.jsonl'
    if(Test-Path -LiteralPath $file -PathType Leaf){
        $n=0
        foreach($line in @(Get-Content -LiteralPath $file -Encoding UTF8)){
            $n++;if(-not $line){continue}
            try{$d=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
            $type=[string]$d.event;$level=[string]$d.level
            $state='Info'
            if($level -eq 'Error' -or $type -match '(?i)Failed'){$state='Failed'}
            elseif($level -eq 'Warning'){$state='Warning'}
            elseif($type -match '(?i)(Completed|Captured|Created)'){$state='Complete'}
            elseif($type -match '(?i)(Started|Launched)'){$state='Running'}
            [void]$events.Add([pscustomobject]@{TimestampUtc=[string]$d.timestampUtc;RunId=$FleetId;Component=[string]$d.component;Stage=[string]$d.taskId;Event=$type;Level=$(if($level){$level}else{'Information'});Status=$state;Source='Controller';Message=[string]$d.message;Sequence=$n})
        }
    }
    $f=Read-PASFleetJson (Join-Path $dir 'fleet.json')
    foreach($u in @($f.units)){
        if(-not [string]$u.runId){continue}
        foreach($e in @(Get-PASDeploymentEvents -RunId ([string]$u.runId) -DataRoot $DataRoot -Tail 1000)){
            $e.Component=ConvertTo-PASUIComponentId $e.Component
            [void]$events.Add($e)
        }
    }
    return @($events.ToArray()|Sort-Object -Property TimestampUtc,Sequence|Select-Object -Last $Tail)
}
function Get-PASFleetSnapshot {
    param([string]$FleetId,[string]$DataRoot=(Get-PASOrchestratorDataRoot),[int]$Tail=150)
    $fleetPath=Join-Path (Get-PASFleetDirectory $FleetId $DataRoot) 'fleet.json'
    $f=Read-PASFleetJson $fleetPath
    if(-not $f){throw "Deployment run not found: $FleetId"}
    # A unit whose engine run was resumed to success after the deployment controller gave up is succeeded now.
    if([string]$f.status -in @('Failed','Interrupted') -and -not ($f.controllerPid -and (Get-Process -Id ([int]$f.controllerPid) -ErrorAction SilentlyContinue))){
        $h=ConvertTo-PASOrchestratorHashtable $f; $changed=$false
        foreach($u in @($h.units|Where-Object {$_.status -eq 'Failed' -and $_.runId})){
            $run=Get-PASeasyRun -RunId ([string]$u.runId) -DataRoot $DataRoot
            if($run -and [string]$run.status -eq 'Succeeded'){
                $u.status='Succeeded';$u.message='Installed and verified (after resume)';$changed=$true
                Write-PASFleetEvent (Split-Path -Parent $fleetPath) 'UnitReconciled' "Unit $($u.id) succeeded after its run was resumed (run $($u.runId))" ([string]$u.id)
            }
        }
        if($changed){
            if(@($h.units|Where-Object {$_.status -ne 'Succeeded'}).Count -eq 0){$h.status='Succeeded';$h.message='All selected component workflows completed (after resume)'}
            else{$h.message='Failed: '+((@($h.units|Where-Object {$_.status -ne 'Succeeded'})|ForEach-Object {$_.id+' '+$_.status}) -join '; ')}
            Write-PASFleetJson $fleetPath $h
            $f=Read-PASFleetJson $fleetPath
        }
    }
    $events=@(Get-PASFleetEvents -FleetId $FleetId -DataRoot $DataRoot -Tail $Tail)
    $latest=@($events|Where-Object {$_.Stage}|Select-Object -Last 1)
    $status=[string]$f.status; if($status -eq 'Launching'){$status='Running'}
    return [pscustomobject]@{
        RunId=$FleetId;Name=[string]$f.name;Status=$status
        CurrentComponent=$(if($latest.Count){[string]$latest[-1].Component}else{''})
        Message=[string]$f.message;LastStep=$(if($latest.Count){[string]$latest[-1].Stage}else{''})
        CompletedEvents=@($events|Where-Object {$_.Event -eq 'TaskCompleted'}).Count
        ErrorEvents=@($events|Where-Object {$_.Status -eq 'Failed'}).Count
        Events=$events
        Units=@($f.units|ForEach-Object {[pscustomobject]@{Id=[string]$_.id;Status=[string]$_.status;RunId=[string]$_.runId;Message=[string]$_.message}})
        OperationallyVerified=$false
    }
}
