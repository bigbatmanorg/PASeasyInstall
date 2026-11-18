# One controller per deployment; step execution is sequential.
function Assert-PASeasyWindowsController {
    if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop'){
        throw 'Qualified deployment controller requires Windows PowerShell 5.1 on Windows. Planning and diagnostics are available elsewhere.'
    }
}
function Get-PASeasyRunDirectory {
    param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot))
    if($RunId -notmatch '^[0-9a-f]{32}$'){throw 'Invalid RunId'}
    return (Join-Path (Join-Path $DataRoot 'Runs') $RunId)
}
function Save-PASeasyEnvelope {
    param([string]$Path,[hashtable]$Credentials,[hashtable]$Secrets)
    $null=Assert-PASWindowsIdentity
    $dir=Split-Path $Path -Parent
    Protect-PASDirectory $dir
    $data=@{schemaVersion=2;ownerSid=(Assert-PASWindowsIdentity);credentials=@{};secrets=@{}}
    foreach($key in $Credentials.Keys){
        $credential=$Credentials[$key]
        if($credential -isnot [Management.Automation.PSCredential]){throw "CredentialMap[$key] must be a PSCredential"}
        $data.credentials[$key]=@{user=$credential.UserName;cipher=($credential.Password|ConvertFrom-SecureString)}
    }
    foreach($key in $Secrets.Keys){
        $value=$Secrets[$key]
        if($value -isnot [Security.SecureString]){throw "SecretMap[$key] must be a SecureString"}
        $data.secrets[$key]=$value|ConvertFrom-SecureString
    }
    if(Test-Path -LiteralPath $Path){throw 'Refusing to replace credential envelope'}
    [IO.File]::WriteAllText($Path,($data|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    $sid=Assert-PASWindowsIdentity
    & icacls.exe $Path '/inheritance:r' '/grant:r' "*${sid}:F" '*S-1-5-18:F' | Out-Null
    if($LASTEXITCODE -ne 0){Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue;throw 'Credential envelope ACL failed'}
}
function Read-PASeasyEnvelope {
    param([string]$Path)
    $raw=Read-PASJson $Path
    if(-not $raw -or $raw.schemaVersion -ne 2 -or $raw.ownerSid -ne (Assert-PASWindowsIdentity)){throw 'Credential envelope absent or owned by another identity'}
    $credentials=@{};$secrets=@{}
    foreach($p in $raw.credentials.PSObject.Properties){
        $credentials[$p.Name]=[Management.Automation.PSCredential]::new([string]$p.Value.user,($p.Value.cipher|ConvertTo-SecureString))
    }
    foreach($p in $raw.secrets.PSObject.Properties){$secrets[$p.Name]=$p.Value|ConvertTo-SecureString}
    return @{Credentials=$credentials;Secrets=$secrets}
}
function Add-PASeasyPTACertificateSecrets {
    param([hashtable]$Configuration,[hashtable]$Secrets,[hashtable]$FrozenMedia)
    foreach($component in @($Configuration.components|Where-Object {$_.type -eq 'PTA'})){
        $path=[string](Get-PASeasyProperty $component.options 'certificatePfxFile' '')
        if(-not $path){continue}
        $path=[IO.Path]::GetFullPath($path)
        if(-not $FrozenMedia.ContainsKey($path)){throw 'PTA PFX was not frozen in the approved plan'}
        $asset=Get-Item -LiteralPath $path -ErrorAction Stop
        if($asset.PSIsContainer -or ($asset.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $asset.Length -le 0 -or $asset.Length -gt 32768){throw 'PTA PFX file is unsafe or exceeds 32768 bytes'}
        if(-not $Secrets.ContainsKey('PTACertificatePassword') -or $Secrets.PTACertificatePassword -isnot [Security.SecureString] -or $Secrets.PTACertificatePassword.Length -eq 0){throw 'PTACertificatePassword SecureString is required'}
        $bytes=$null;$hasher=$null;$encoded=$null
        try{
            $bytes=[IO.File]::ReadAllBytes($path)
            if($bytes.Length -le 0 -or $bytes.Length -gt 32768){throw 'PTA PFX changed size before secret resolution'}
            $hasher=[Security.Cryptography.SHA256]::Create()
            $hash=([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-','')
            if($hash -ine $FrozenMedia[$path] -or $hash -ine [string]$component.options.certificatePfxSHA256){throw 'PTA PFX changed after plan approval'}
            $encoded=[Convert]::ToBase64String($bytes)
            $secret=New-Object Security.SecureString
            foreach($character in $encoded.ToCharArray()){$secret.AppendChar($character)}
            $secret.MakeReadOnly()
            $Secrets['PTACertificatePfxData_'+[string]$component.id]=$secret
        }finally{
            if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
            if($hasher){$hasher.Dispose()};$encoded=$null
        }
    }
}
function Get-PASeasyRun {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot))
    $dir=Get-PASeasyRunDirectory $RunId $DataRoot
    $run=Read-PASJson (Join-Path $dir 'run-v2.json')
    if(-not $run){return $null}
    if($run.status -in @('Running','Launching') -and $run.controllerPid){
        try {
            $p=Get-CimInstance Win32_Process -Filter ('ProcessId = '+[int]$run.controllerPid) -ErrorAction Stop
            $started=[string](Get-PASProp $run 'controllerStartedUtc' '')
            $sameProcess=$false
            if($p){
                if($started){$sameProcess=([Math]::Abs(($p.CreationDate.ToUniversalTime()-[DateTime]::Parse($started).ToUniversalTime()).TotalMilliseconds) -lt 1)}
                else{$sameProcess=([string]$p.CommandLine).Contains($RunId)}
            }
            if(-not $sameProcess){
                $run.status='Interrupted';$run.message='Controller ended. Remote attempts require reconciliation on resume.'
            }
        }catch{} # When process inspection fails, do not claim it stopped.
    }
    return $run
}
function Get-PASeasyRuns {
    [CmdletBinding()]param([string]$DataRoot=(Get-PASDataRoot))
    $dir=Join-Path $DataRoot 'Runs'
    if(-not(Test-Path $dir)){return @()}
    return @(Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object {Get-PASeasyRun -RunId $_.Name -DataRoot $DataRoot} | Where-Object {$_} | Sort-Object startedUtc -Descending)
}
function Write-PASeasyRunEvent {
    param([string]$Dir,[string]$Event,[string]$Message,[string]$ComponentId='')
    $line=[ordered]@{timestampUtc=[DateTime]::UtcNow.ToString('o');event=$Event;component=$ComponentId;message=$Message}
    [IO.File]::AppendAllText((Join-Path $Dir 'events-v2.jsonl'),(($line|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
}
function Test-PASeasyActiveEnvironment {
    param([string]$Name,[string]$DataRoot,[string]$ExcludeRunId='')
    $active=@(Get-PASeasyRuns -DataRoot $DataRoot | Where-Object { $_.name -eq $Name -and $_.id -ne $ExcludeRunId -and $_.status -in @('Launching','Running','Unknown','Interrupted') })
    if($active.Count){throw "Environment '$Name' has unresolved deployment $($active[0].id). Resume or reconcile it before creating another."}
}
function Wait-PASeasyControllerCompletion {
    param([string]$RunId,[string]$DataRoot,[int]$ControllerPid=0,[datetime]$ControllerStartedAfterUtc=[datetime]::MinValue)
    $bootstrapDeadline=[DateTime]::UtcNow.AddSeconds(60)
    do{
        $observed=Get-PASeasyRun -RunId $RunId -DataRoot $DataRoot
        if(-not $observed){throw 'Controller run metadata disappeared'}
        if($ControllerPid){
            $stamp=[string](Get-PASProp $observed 'controllerStartedUtc' '')
            $newOwner=($observed.controllerPid -eq $ControllerPid -and $stamp -and [datetime]::Parse($stamp).ToUniversalTime() -ge $ControllerStartedAfterUtc)
            if(-not $newOwner){
                if([DateTime]::UtcNow -ge $bootstrapDeadline){throw 'New controller bootstrap was not observed; original run outcome is unchanged'}
                Start-Sleep -Milliseconds 100
                continue
            }
        }
        if($observed.status -eq 'Succeeded'){return}
        if($observed.status -notin @('Launching','Running')){throw ('Deployment '+$RunId+' stopped: '+[string]$observed.message)}
        if(-not $observed.controllerPid -and [DateTime]::UtcNow -ge $bootstrapDeadline){throw 'Controller bootstrap was not observed; inspect the run and execution policy before resuming'}
        Start-Sleep -Seconds 1
    }while($true)
}
function Assert-PASeasyVaultInstallationSecrets {
    param([hashtable]$Configuration,[hashtable]$Secrets,[switch]$ReferencesResolved)
    # Only native Vault installation uses the qualified PACLI v15 text grammar.
    # Existing-Vault REST credentials and the Master recovery password are separate contracts.
    $vaults=@($Configuration.components | Where-Object {$_.type -eq 'Vault'})
    if(-not $vaults.Count){return}
    if(-not $ReferencesResolved){$Secrets=Resolve-PASeasySecretMap -Config $Configuration -SecretMap $Secrets}
    $required=@('VaultAdmin','VaultMaster')
    if(@($Configuration.components | Where-Object {$_.type -eq 'DRVault'}).Count){$required+='DRPassword'}
    foreach($name in $required){
        if(-not $Secrets.ContainsKey($name) -or $Secrets[$name] -isnot [Security.SecureString] -or $Secrets[$name].Length -eq 0){throw ($name+' SecureString is required before Vault installation')}
        $plain=$null
        try {
            $plain=Get-PSSecretPlaintext $Secrets[$name]
            if($name -eq 'VaultMaster'){
                if($plain -match '[^\x20-\x21\x23-\x7e]'){throw 'VaultMaster requires printable ASCII without double quotes for the supplied unescaped installer response format; no target changes were dispatched'}
                continue
            }
            if($plain.Length -gt 4096 -or $plain -match '[^\x20-\x21\x23-\x7e]'){throw ($name+' requires printable ASCII without double quotes for supplied PACLI v15; no target changes were dispatched')}
        }finally{$plain=$null}
    }
}
function Start-PASeasyDeployment {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Config,$Configuration,[hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},
        [string]$DataRoot=(Get-PASDataRoot),[switch]$Foreground,[switch]$PlanOnly)
    $assessment=Test-PASeasyConfig -Config $Config -Configuration $Configuration -CheckMedia
    if(-not $assessment.Valid){throw ($assessment.Issues -join '; ')}
    $c=$assessment.Configuration
    $plan=Get-PASeasyPlan -Configuration $c -ResolveMedia
    if($PlanOnly){return $plan}
    Assert-PASeasyWindowsController
    if(-not $PSCmdlet.ShouldProcess([string]$c.name,'Start CyberArk deployment')){return $plan}
    Assert-PASeasyVaultInstallationSecrets -Configuration $c -Secrets $SecretMap
    Test-PASeasyActiveEnvironment -Name ([string]$c.name) -DataRoot $DataRoot
    $id=[guid]::NewGuid().ToString('N');$dir=Get-PASeasyRunDirectory $id $DataRoot
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Protect-PASDirectory $dir
    Write-PASJsonAtomic (Join-Path $dir 'config.json') $c
    Write-PASJsonAtomic (Join-Path $dir 'plan-v2.json') $plan
    $run=[ordered]@{schemaVersion=2;id=$id;name=$c.name;status='Launching';startedUtc=[DateTime]::UtcNow.ToString('o');
        finishedUtc=$null;controllerPid=$null;currentComponent='';message='Starting deployment controller';configDigest=$plan.ConfigDigest}
    Write-PASJsonAtomic (Join-Path $dir 'run-v2.json') $run
    $envelope=Join-Path $dir ('credentials-'+[guid]::NewGuid().ToString('N')+'.json')
    $consoleChild=($Foreground -and @($c.components|Where-Object {$c.hosts[[string]$_.host].os -eq 'Linux'}).Count -gt 0)
    try {
        if($Foreground -and -not $consoleChild){
            Invoke-PASeasyInternalController -RunId $id -DataRoot $DataRoot -InMemoryAuth @{Credentials=$CredentialMap;Secrets=$SecretMap}
        }else{
            Save-PASeasyEnvelope -Path $envelope -Credentials $CredentialMap -Secrets $SecretMap
            $scriptPath=Join-Path $script:PASRoot 'Controllers/Invoke-V2Controller.ps1'
            $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$scriptPath+'" -RunId "'+$id+'" -DataRoot "'+$DataRoot+'" -Envelope "'+$envelope+'"'
            # Win32 OpenSSH requires a real console even with redirected stdin.
            # A fresh hidden console also works when this API is called over SSH.
            $startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0;CreateFlags=[uint32]16}
            $launchAfter=[DateTime]::UtcNow.AddSeconds(-1)
            $spawn=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=('"'+$exe+'" '+$args);CurrentDirectory=$script:PASRoot;ProcessStartupInformation=$startup}
            if($spawn.ReturnValue -ne 0 -or -not $spawn.ProcessId){throw "Cannot start controller: Win32_Process.Create=$($spawn.ReturnValue)"}
            # The child owns run state after dispatch; a parent write can overwrite completion.
        }
    }catch{
        if(Test-Path $envelope){Remove-Item $envelope -Force -ErrorAction SilentlyContinue}
        $observed=Read-PASJson (Join-Path $dir 'run-v2.json')
        if(-not $observed -or $observed.status -eq 'Launching'){
            $run.status='LaunchFailed';$run.message='Controller could not start; no successful launch was observed'
            Write-PASJsonAtomic (Join-Path $dir 'run-v2.json') $run
        }
        throw
    }
    if($consoleChild){Wait-PASeasyControllerCompletion -RunId $id -DataRoot $DataRoot -ControllerPid ([int]$spawn.ProcessId) -ControllerStartedAfterUtc $launchAfter}
    return $id
}
function Resume-PASeasyDeployment {
    [CmdletBinding(SupportsShouldProcess=$true)]param([Parameter(Mandatory)][string]$RunId,
        [hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},[string]$DataRoot=(Get-PASDataRoot),
        [switch]$Foreground,[switch]$AllowUnknownRetry,[switch]$RetryFailedPreflight)
    $run=Get-PASeasyRun -RunId $RunId -DataRoot $DataRoot
    if(-not $run){throw 'Run not found'}
    if($run.status -notin @('Failed','Unknown','Interrupted','LaunchFailed')){throw "Cannot resume run status $($run.status)"}
    if($AllowUnknownRetry){throw 'Blind retry of unknown irreversible attempts is not permitted. Reconcile target first.'}
    Assert-PASeasyWindowsController
    if(-not $PSCmdlet.ShouldProcess($RunId,'Resume deployment')){return $run}
    $dir=Get-PASeasyRunDirectory $RunId $DataRoot
    $envelope=Join-Path $dir ('credentials-'+[guid]::NewGuid().ToString('N')+'.json')
    $savedConfig=Read-PASeasyConfig -Path (Join-Path $dir 'config.json')
    $consoleChild=($Foreground -and @($savedConfig.components|Where-Object {$savedConfig.hosts[[string]$_.host].os -eq 'Linux'}).Count -gt 0)
    if($Foreground -and -not $consoleChild){Invoke-PASeasyInternalController -RunId $RunId -DataRoot $DataRoot -InMemoryAuth @{Credentials=$CredentialMap;Secrets=$SecretMap} -Resume -RetryFailedPreflight:$RetryFailedPreflight}
    else{
        Save-PASeasyEnvelope -Path $envelope -Credentials $CredentialMap -Secrets $SecretMap
        $scriptPath=Join-Path $script:PASRoot 'Controllers/Invoke-V2Controller.ps1'
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$scriptPath+'" -RunId "'+$RunId+'" -DataRoot "'+$DataRoot+'" -Envelope "'+$envelope+'" -Resume'
        if($RetryFailedPreflight){$args+=' -RetryFailedPreflight'}
        $startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0;CreateFlags=[uint32]16}
        $launchAfter=[DateTime]::UtcNow.AddSeconds(-1)
        $spawn=Invoke-CimMethod Win32_Process Create -Arguments @{CommandLine=('"'+$exe+'" '+$args);CurrentDirectory=$script:PASRoot;ProcessStartupInformation=$startup}
        if($spawn.ReturnValue -ne 0 -or -not $spawn.ProcessId){throw 'Failed to launch resume controller'}
    }
    if($consoleChild){Wait-PASeasyControllerCompletion -RunId $RunId -DataRoot $DataRoot -ControllerPid ([int]$spawn.ProcessId) -ControllerStartedAfterUtc $launchAfter}
    return $RunId
}
function Invoke-PASeasyVaultSequence {
    param([hashtable]$Config,[string]$RunId,[string]$DataRoot,[hashtable]$Credentials,[hashtable]$Secrets,[switch]$Resume,$BorrowedVaultLease)
    $parts=@($Config.components | Where-Object { $_.type -in @('Vault','DRVault') })
    if(-not $parts.Count){return}
    $primary=@($parts|Where-Object{$_.type -eq 'Vault'})[0]
    if(-not $primary){throw 'Existing Vault mode does not run installation; missing primary'}
    $dr=@($parts|Where-Object{$_.type -eq 'DRVault'})
    $mode=if($dr.Count){'PrimaryAndDR'}else{'Primary'}
    $winHost=$Config.hosts[[string]$primary.host]
    $drHost=$null;if($dr.Count){$drHost=$Config.hosts[[string]$dr[0].host]}
    $profile=New-PASProfile -Mode $mode -PrimaryIP ([string]$winHost.address) -DRIP $(if($drHost){[string]$drHost.address}else{''}) `
        -ControllerIP ([string]$Config.controllerAddress) -PrimaryUser ([string]$winHost.user) `
        -DRUser $(if($drHost){[string]$drHost.user}else{'Administrator'}) -MediaPath ([string]$Config.mediaRoot) -MediaOverrides $Config.media
    $profile=Resolve-PASMediaProfile -Profile $profile
    $inventoryPath=Join-Path (Get-PASeasyRunDirectory $RunId $DataRoot) 'vault-inventory.psd1'
    if(-not(Test-Path $inventoryPath)){
        Export-PASInventory -Profile $profile -Path $inventoryPath | Out-Null
        $inv=Import-PowerShellDataFile -Path $inventoryPath
        $secure=$true
        if($Config.security.profile -eq 'Lab' -and $Config.security.overrides.Contains('WinRM.RequireHTTPS')){$secure=[bool]$Config.security.overrides['WinRM.RequireHTTPS']}
        $inv.Values.Settings.Management.WinRMPort=if($secure){5986}else{5985}
        $inv.Values.Settings.Hardening.AllowRDP=$false
        if($Config.security.profile -eq 'Lab' -and $Config.security.overrides.Contains('Vault.AllowRDP')){$inv.Values.Settings.Hardening.AllowRDP=[bool]$Config.security.overrides['Vault.AllowRDP']}
        foreach($target in @($inv.Targets.Keys)){
            $inv.Targets[$target]['UseSSL']=$secure
            if($Config.security.profile -eq 'Lab'){
                foreach($flag in @('WinRM.SkipCACheck','WinRM.SkipCNCheck')){
                    if($Config.security.overrides.Contains($flag)){
                        $inv.Targets[$target][$flag.Replace('WinRM.','')]=[bool]$Config.security.overrides[$flag]
                    }
                }
            }
        }
        [IO.File]::WriteAllText($inventoryPath,(ConvertTo-PASLiteral $inv),[Text.UTF8Encoding]::new($false))
    }
    if(-not $Credentials.ContainsKey('PrimaryAdmin')){$Credentials.PrimaryAdmin=$Credentials[[string]$primary.host]}
    if(-not $Credentials.PrimaryAdmin){throw 'Primary Windows administrator PSCredential is required'}
    if($dr.Count -and -not $Credentials.ContainsKey('DRAdmin')){$Credentials.DRAdmin=$Credentials[[string]$dr[0].host]}
    if($dr.Count -and -not $Credentials.DRAdmin){throw 'DR Windows administrator PSCredential is required'}
    $needed=@('VaultAdmin','VaultMaster');if($dr.Count){$needed+= 'DRPassword'}
    foreach($key in $needed){if(-not $Secrets.ContainsKey($key) -or $null -eq $Secrets[$key]){throw "Missing secure secret reference: $key"}}
    # Extend the original frozen inventory with aliases for the sequential final phases.
    if($dr.Count -and -not ((Import-PowerShellDataFile -Path $inventoryPath).Targets.Contains('primary_final'))){
        $inv=Import-PowerShellDataFile -Path $inventoryPath
        $inv.Targets['primary_final']=$inv.Targets.primary.Clone()
        $inv.Targets['dr_final']=$inv.Targets.dr.Clone()
        [IO.File]::WriteAllText($inventoryPath,(ConvertTo-PASLiteral $inv),[Text.UTF8Encoding]::new($false))
    }
    $workflowDir=Join-Path (Get-PASModuleRoot Vault) 'Recipes/Vault/Workflows'
    $names=if($dr.Count){@('VaultPrimary-Phase1.psd1','VaultDR-Phase1.psd1','VaultPrimary-Phase2.psd1','VaultDR-Phase2.psd1')}else{@('VaultPrimaryOnly.psd1')}
    foreach($name in $names){
        $wf=Join-Path $workflowDir $name
        $plan=Get-PAExecPlan -WorkflowPath $wf -InventoryPath $inventoryPath
        $statePath=Join-Path (Join-Path (Join-Path $DataRoot 'Runs') $RunId) (Join-Path $plan.TargetName 'state.json')
        $isResume=Test-Path -LiteralPath $statePath -PathType Leaf
        Invoke-PAExecRun -WorkflowPath $wf -InventoryPath $inventoryPath -StateRoot (Join-Path $DataRoot 'Runs') `
            -RunId $RunId -Credentials $Credentials -Secrets $Secrets -Resume:$isResume -BorrowedVaultLease $BorrowedVaultLease | Out-Null
    }
}
function Invoke-PASeasyDomainJoins {
    param([hashtable]$Config,[string]$RunId,[string]$DataRoot,[hashtable]$Credentials,[hashtable]$Secrets)
    if($Config.activeDirectory.mode -eq 'None'){return}
    $dir=Get-PASeasyRunDirectory $RunId $DataRoot
    foreach($hostId in @($Config.activeDirectory.join)){
        $id='join-'+[string]$hostId
        $wfpath=Join-Path (Join-Path (Join-Path (Join-Path $dir 'Payloads') $id) 'Workflows') ($id+'.psd1')
        $invpath=Join-Path $dir ($id+'-inventory.psd1')
        if(-not(Test-Path $wfpath) -or -not(Test-Path $invpath)){
            $j=New-PASeasyDomainJoinWorkflow -Config $Config -HostId ([string]$hostId) -RunDirectory $dir
            $wfpath=$j.Workflow;$invpath=$j.Inventory
        }
        if(-not $Credentials.ContainsKey([string]$hostId)){throw "Missing host PSCredential for domain join host $hostId"}
        if(-not $Secrets.ContainsKey('DomainJoinPassword')){throw 'DomainJoinPassword SecureString is required for domain joins'}
        $state=Join-Path (Join-Path $dir $id) 'state.json'
        Write-PASeasyRunEvent $dir 'DomainJoin' "Joining $hostId to $($Config.activeDirectory.domain)" $id
        Invoke-PAExecRun -WorkflowPath $wfpath -InventoryPath $invpath -StateRoot (Join-Path $DataRoot 'Runs') -RunId $RunId -Credentials $Credentials -Secrets $Secrets -Resume:(Test-Path $state) | Out-Null
    }
}
function Get-PASeasyFailedPreflightRetry {
    param([string]$WorkflowPath,[string]$InventoryPath,[string]$StatePath,[hashtable]$Credentials=@{})
    $state=Read-PSJson $StatePath
    if(-not $state){throw 'Preflight retry requires an existing component journal'}
    $step=Get-PSObjectValue (Get-PSObjectValue $state 'steps' @{}) 'preflight' $null
    if(-not $step -or (Get-PSObjectValue $step 'status' '') -notin @('Failed','Unknown','Dispatched','Running')){return @()}
    $plan=Get-PAExecPlan -WorkflowPath $WorkflowPath -InventoryPath $InventoryPath
    if($state.digest -ne $plan.Digest){throw 'Preflight retry refuses changed workflow, scripts or inventory'}
    $definition=@($plan.Steps|Where-Object {$_.Id -eq 'preflight'})
    if($plan.Target.Protocol -ne 'SSH' -or $plan.Runtime -ne 'Bash' -or $definition.Count -ne 1 -or
       (Get-PSObjectValue $definition[0].Inputs 'Stage' '') -cne 'Preflight'){
        throw 'Explicit preflight retry currently supports only the fixed Linux preflight stage'
    }
    $attempt=[string](Get-PSObjectValue $step 'attemptId' '')
    if($attempt -notmatch '^[a-f0-9]{32}$'){throw 'Preflight retry requires the original durable attempt'}
    $remote=Get-PSDetachedStatus $plan.Target $Credentials $attempt
    $active=Get-PSObjectValue $remote 'workerActive' $null
    if((Get-PSObjectValue $remote 'state' '') -cne 'Failed' -or (Get-PSObjectValue $remote 'attemptId' '') -cne $attempt -or
       $active -isnot [bool] -or $active){throw 'Preflight retry requires the same known-failed attempt with proven worker exit'}
    return @('preflight')
}
function Invoke-PASeasyInternalController {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot),[string]$Envelope,[switch]$Resume,[hashtable]$InMemoryAuth,[switch]$RetryFailedPreflight)
    Assert-PASeasyWindowsController
    $dir=Get-PASeasyRunDirectory $RunId $DataRoot
    # Acquire before reading/changing controller metadata. A second Resume may
    # race the first caller, but it must never overwrite that owner's status.
    # Keep the empty lockfile: deleting it can create two independent lock inodes.
    $lease=Get-PSFileLock (Join-Path $dir 'controller.lock')
    try{
        $path=Join-Path $dir 'run-v2.json'
        $run=Read-PASJson $path
        if(-not $run){throw 'Controller run metadata is missing'}
        $run.controllerPid=$PID
        $run|Add-Member NoteProperty controllerStartedUtc ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')) -Force
        $run.status='Launching';$run.message='Validating deployment controller';$run.finishedUtc=$null
        Write-PASJsonAtomic $path $run
        try{
            Invoke-PASeasyInternalControllerCore -RunId $RunId -DataRoot $DataRoot -Envelope $Envelope -Resume:$Resume -InMemoryAuth $InMemoryAuth -RetryFailedPreflight:$RetryFailedPreflight
        }catch{
            $failure=$_
            $observed=Read-PASJson $path
            if($observed -and $observed.controllerPid -eq $PID -and $observed.status -eq 'Launching'){
                $observed.status='LaunchFailed';$observed.message='Controller initialization failed before target dispatch'
                $observed.finishedUtc=[DateTime]::UtcNow.ToString('o')
                Write-PASJsonAtomic $path $observed
            }
            throw $failure
        }
    }finally{$lease.Dispose()}
}
function Invoke-PASeasyInternalControllerCore {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot),[string]$Envelope,[switch]$Resume,[hashtable]$InMemoryAuth,[switch]$RetryFailedPreflight)
    Assert-PASeasyWindowsController
    $dir=Get-PASeasyRunDirectory $RunId $DataRoot
    $config=Read-PASeasyConfig -Path (Join-Path $dir 'config.json')
    $plan=Get-PASeasyPlan -Configuration $config -ResolveMedia
    $saved=Read-PASJson (Join-Path $dir 'plan-v2.json')
    if(-not $saved -or $saved.ConfigDigest -ne $plan.ConfigDigest -or -not $saved.PSObject.Properties['SourceDigest'] -or $saved.SourceDigest -ne $plan.SourceDigest -or -not $saved.PSObject.Properties['MediaDigest'] -or $saved.MediaDigest -ne $plan.MediaDigest){throw 'Plan/configuration drift. Refusing execution.'}
    $script:PASeasyFrozenMedia=@{}
    foreach($asset in @($plan.Media)){$script:PASeasyFrozenMedia[[string]$asset.Path]=[string]$asset.SHA256}
    if($InMemoryAuth){$auth=$InMemoryAuth}else{
        $auth=Read-PASeasyEnvelope $Envelope
        Remove-Item -LiteralPath $Envelope -Force -ErrorAction Stop
    }
    $auth.Credentials=Resolve-PASeasyCredentialMap -Config $config -CredentialMap $auth.Credentials
    $auth.Secrets=Resolve-PASeasySecretMap -Config $config -SecretMap $auth.Secrets
    $run=Read-PASJson (Join-Path $dir 'run-v2.json')
    $run | Add-Member NoteProperty controllerStartedUtc ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')) -Force
    $run.controllerPid=$PID;$run.status='Running';$run.message='Executing deployment';$run.finishedUtc=$null
    Write-PASJsonAtomic (Join-Path $dir 'run-v2.json') $run
    $lock=$null; $vaultSequenceGates=@(); $hostGates=New-Object System.Collections.ArrayList
    try {
        # One writer per environment/host. Vault admission is limited to authenticated operations.
        $lock=Enter-PASeasyGate -Name ('environment-'+[string]$config.name) -DataRoot $DataRoot -RunId $RunId -TimeoutSeconds 1
        Assert-PASeasyVaultInstallationSecrets -Configuration $config -Secrets $auth.Secrets -ReferencesResolved
        $ptaManagement=Get-PASeasyPTASyslogHost $config
        if($ptaManagement -and (-not $auth.Credentials.ContainsKey($ptaManagement) -or $auth.Credentials[$ptaManagement] -isnot [pscredential])){throw "PTA syslog requires primary Windows credentials for '$ptaManagement' before installation"}
        Add-PASeasyPTACertificateSecrets -Configuration $config -Secrets $auth.Secrets -FrozenMedia $script:PASeasyFrozenMedia
        # Include the existing primary changed by PTA syslog. Its outer claim is
        # retained on failure and completed on successful Resume with all hosts.
        $allHosts=@(Get-PASeasyDeploymentHostIds $config)
        $endpointOwners=@{}
        $addresses=@(foreach($hostId in $allHosts){
            foreach($endpoint in @(Get-PASeasyResourceIdentity ([string]$config.hosts[$hostId].address))){
                if($endpointOwners.ContainsKey($endpoint) -and $endpointOwners[$endpoint] -ne $hostId){throw 'Host DNS aliases resolve to the same endpoint; configure co-location with one host record'}
                $endpointOwners[$endpoint]=$hostId
                $endpoint
            }
        })
        $addresses=@($addresses | Sort-Object -Unique)
        foreach($address in $addresses){
            [void]$hostGates.Add((Enter-PASeasyGate -Name ('host-'+$address) -DataRoot $DataRoot -RunId $RunId -TimeoutSeconds 30))
        }
        $records=@($plan.Items)
        # Domain promotion runs before joins and all PAM component installations.
        $ad=@($records|Where-Object{$_.Type -eq 'AD'})
        if($ad.Count){
            $adComponent=@($config.components|Where-Object{$_.type -eq 'AD'})[0]
            $adId=[string]$adComponent.id
            $adHost=[string]$adComponent.host
            if(-not $auth.Credentials.ContainsKey($adId) -and $auth.Credentials.ContainsKey($adHost)){$auth.Credentials[$adId]=$auth.Credentials[$adHost]}
            if(-not $auth.Credentials.ContainsKey($adId)){throw 'AD host credential required'}
            $domainRef=$adId+'-domain'
            if(-not $auth.Credentials.ContainsKey($domainRef)){
                $netbios=([string]$config.activeDirectory.domain).Split('.')[0].ToUpperInvariant()
                $adOptions=Get-PASeasyProperty $adComponent 'options' $null
                $adNetbios=[string](Get-PASeasyProperty $adOptions 'domainNetbios' '')
                if($adNetbios){$netbios=$adNetbios}
                $user=([string]$auth.Credentials[$adId].UserName).Split([char]92)[-1].Split('@')[0]
                $auth.Credentials[$domainRef]=[pscredential]::new(($netbios+'\'+$user),$auth.Credentials[$adId].Password)
            }
            $adInventory=Join-Path $dir 'component-inventory.psd1'
            if(-not(Test-Path $adInventory)){
                $inv=New-PASeasyRuntimeInventory -Config $config -RunDirectory $dir -CredentialMap $auth.Credentials
                [IO.File]::WriteAllText($adInventory,(ConvertTo-PASLiteral $inv),[Text.UTF8Encoding]::new($false))
            }
            $adWorkflow=Join-Path (Join-Path (Join-Path (Join-Path $dir 'Payloads') $adId) 'Workflows') ($adId+'.psd1')
            if(-not(Test-Path $adWorkflow)){$adWorkflow=New-PASeasyComponentWorkflow -Component $adComponent -Configuration $config -RunDirectory $dir}
            $state=Join-Path (Join-Path $dir $adId) 'state.json'
            Write-PASeasyRunEvent $dir 'ADForest' 'Creating/verifying Active Directory forest' $adId
            Invoke-PAExecRun -WorkflowPath $adWorkflow -InventoryPath $adInventory -StateRoot (Join-Path $DataRoot 'Runs') -RunId $RunId -Credentials $auth.Credentials -Secrets $auth.Secrets -Resume:(Test-Path $state) | Out-Null
        }
        Invoke-PASeasyDomainJoins -Config $config -RunId $RunId -DataRoot $DataRoot -Credentials $auth.Credentials -Secrets $auth.Secrets
        if(@($config.components|Where-Object{$_.type -eq 'Vault'}).Count){
            Write-PASeasyRunEvent $dir 'VaultSequence' 'Starting primary/DR installation'
            # This coordinated sequence includes PACLI, DR registration and replication.
            $vaultSequenceGates=@(Enter-PASeasyVaultOperation -Address ([string]$config.vault.address) -DataRoot $DataRoot -RunId $RunId)
            $borrowed=New-PASeasyBorrowedVaultLease -Address ([string]$config.vault.address) -RunId $RunId -DataRoot $DataRoot -Gates $vaultSequenceGates
            Invoke-PASeasyVaultSequence -Config $config -RunId $RunId -DataRoot $DataRoot -Credentials $auth.Credentials -Secrets $auth.Secrets -Resume:$Resume -BorrowedVaultLease $borrowed
            Exit-PASeasyVaultOperation -Gates $vaultSequenceGates -Succeeded $true
            $vaultSequenceGates=@()
        }
        foreach($item in @($records|Where-Object{$_.Type -notin @('Vault','DRVault','AD')})){
            $component=@($config.components|Where-Object{$_.id -eq $item.Id})[0]
            $run.currentComponent=[string]$item.Id;Write-PASJsonAtomic (Join-Path $dir 'run-v2.json') $run
            Write-PASeasyRunEvent $dir 'ComponentStarted' "Starting $($item.Type)" $item.Id
            $inventoryPath=Join-Path $dir 'component-inventory.psd1'
            if(-not(Test-Path $inventoryPath)){
                $inv=New-PASeasyRuntimeInventory -Config $config -RunDirectory $dir -CredentialMap $auth.Credentials
                [IO.File]::WriteAllText($inventoryPath,(ConvertTo-PASLiteral $inv),[Text.UTF8Encoding]::new($false))
            }
            $wf=Join-Path (Join-Path (Join-Path (Join-Path $dir 'Payloads') $item.Id) 'Workflows') ($item.Id+'.psd1')
            if(-not(Test-Path $wf)){$wf=New-PASeasyComponentWorkflow -Component $component -Configuration $config -RunDirectory $dir}
            $credRef=[string]$component.id;$hostId=[string]$component.host
            if(-not $auth.Credentials.ContainsKey($credRef) -and $auth.Credentials.ContainsKey($hostId)){$auth.Credentials[$credRef]=$auth.Credentials[$hostId]}
            $st=Join-Path (Join-Path $dir $item.Id) 'state.json'
            $existing=Test-Path $st
            $retry=@()
            if($RetryFailedPreflight -and $existing){$retry=@(Get-PASeasyFailedPreflightRetry -WorkflowPath $wf -InventoryPath $inventoryPath -StatePath $st -Credentials $auth.Credentials)}
            Invoke-PAExecRun -WorkflowPath $wf -InventoryPath $inventoryPath -StateRoot (Join-Path $DataRoot 'Runs') `
                -RunId $RunId -Credentials $auth.Credentials -Secrets $auth.Secrets -Resume:$existing `
                -VaultSessionAddress ([string]$config.vault.address) -CoordinationDataRoot $DataRoot -Retry $retry | Out-Null
            if($item.Type -eq 'PTA'){Invoke-PASeasyPTAVaultSyslog -Config $config -Component $component -ComponentInventory (Import-PowerShellDataFile -Path $inventoryPath) -RunId $RunId -DataRoot $DataRoot -Credentials $auth.Credentials -Secrets $auth.Secrets}
            Write-PASeasyRunEvent $dir 'ComponentCompleted' "Verified $($item.Type)" $item.Id
        }
        $run.status='Succeeded';$run.message='All selected component workflows completed';$run.currentComponent=''
        Write-PASeasyRunEvent $dir 'RunCompleted' $run.message
    }catch{
        $reason=[string]$_.Exception.Message
        $hide=@()
        foreach($sec in @($auth.Secrets.Values)){try{$hide+=,(Get-PSSecretPlaintext $sec)}catch{}}
        foreach($cred in @($auth.Credentials.Values)){try{$hide+=,(Get-PSSecretPlaintext $cred.Password)}catch{}}
        $reason=Protect-PSText $reason $hide
        # Unknown means the remote side may still be running; never auto-retry a second installer.
        $run.status=if($reason -match 'Unknown|uncertain|cannot resume'){ 'Unknown' }else{'Failed'}
        $run.message=$reason
        Write-PASeasyRunEvent $dir 'RunStopped' $reason
        throw $reason
    }finally{
        if(@($vaultSequenceGates).Count){Exit-PASeasyVaultOperation -Gates $vaultSequenceGates -Succeeded $false}
        foreach($hg in @($hostGates)){try{if($run.status -eq 'Succeeded'){$hg.Complete()};$hg.Dispose()}catch{}}
        $run.finishedUtc=[DateTime]::UtcNow.ToString('o')
        Write-PASJsonAtomic (Join-Path $dir 'run-v2.json') $run
        if($lock){if($run.status -eq 'Succeeded'){$lock.Complete()};$lock.Dispose()}
        $auth=$null
        $script:PASeasyFrozenMedia=$null
    }
}
