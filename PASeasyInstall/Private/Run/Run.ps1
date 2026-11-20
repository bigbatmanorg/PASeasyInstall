# One run = one deployment = one controller process. Components are installed one after the other.
function Assert-PASWindowsController {
    if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop'){
        throw 'Qualified deployment controller requires Windows PowerShell 5.1 on Windows. Planning and diagnostics are available elsewhere.'
    }
}
function Get-PASRunDirectory {
    param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot))
    if($RunId -notmatch '^[0-9a-f]{32}$'){throw 'Invalid RunId'}
    return (Join-Path (Join-Path $DataRoot 'Runs') $RunId)
}
function Save-PASEnvelope {
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
function Read-PASEnvelope {
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
function Test-PASControllerAlive {
    # Is the controller process recorded in a run record still running? $true, $false, or $null when the
    # process list cannot be read (then nobody may conclude that it stopped).
    # A PID alone is not enough (Windows reuses PIDs): the process start time must match the recorded one.
    param($Record)
    if (-not (Get-PASValue $Record 'controllerPid' $null)) { return $false }
    try {
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + [int]$Record.controllerPid) -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not $process) { return $false }
    $started = [string](Get-PASValue $Record 'controllerStartedUtc' '')
    if ($started) {
        $difference = $process.CreationDate.ToUniversalTime() - [DateTime]::Parse($started).ToUniversalTime()
        return ([Math]::Abs($difference.TotalMilliseconds) -lt 1)
    }
    return ([string]$process.CommandLine).Contains([string]$Record.id)
}
function Get-PASRunRecord {
    # The run record (run-v2.json) as stored, except that a run whose controller process is gone is reported
    # as Interrupted (or LaunchFailed when no controller ever started): a dead controller never looks alive.
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot))
    $dir=Get-PASRunDirectory $RunId $DataRoot
    $run=Read-PASJson (Join-Path $dir 'run-v2.json')
    if(-not $run){return $null}
    if ($run.status -notin @('Running','Launching')) { return $run }
    if ($run.controllerPid) {
        if ((Test-PASControllerAlive $run) -eq $false) {
            $run.status = 'Interrupted'
            $run.message = 'The controller process ended without recording an outcome. Resume the run: it reconciles what happened on the servers.'
        }
        return $run
    }
    # Launching without a controller PID: the controller is starting right now, or it never started.
    $started = [DateTime]::MinValue
    $parsed = [DateTime]::TryParse([string]$run.startedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$started)
    if (-not $parsed -or ([DateTime]::UtcNow - $started).TotalMinutes -gt 2) {
        $run.status = 'LaunchFailed'
        $run.message = 'The controller process never started for this run. Resume it or start a new run.'
    }
    return $run
}
function Get-PASRunRecords {
    [CmdletBinding()]param([string]$DataRoot=(Get-PASDataRoot))
    $dir=Join-Path $DataRoot 'Runs'
    if(-not(Test-Path $dir)){return @()}
    return @(Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object {Get-PASRunRecord -RunId $_.Name -DataRoot $DataRoot} | Where-Object {$_} | Sort-Object startedUtc -Descending)
}
function Write-PASRunEvent {
    # One line in the run's own event journal (run root). Engine steps write theirs to <run>\<target>\events.jsonl.
    # $Stage is the step the event belongs to (shown as the event's Stage), $Level its severity.
    param([string]$Dir,[string]$Event,[string]$Message,[string]$ComponentId='',[string]$Stage='',
        [ValidateSet('Information','Warning','Error')][string]$Level='Information')
    $line=[ordered]@{timestampUtc=[DateTime]::UtcNow.ToString('o');event=$Event;component=$ComponentId;taskId=$Stage;level=$Level;message=$Message}
    [IO.File]::AppendAllText((Join-Path $Dir 'events-v2.jsonl'),(($line|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
}
function Assert-PASEnvironmentNotRunning {
    # A new run for an environment name is refused only while another run of that name has a live controller.
    # Failed, Unknown, Interrupted, Blocked and Abandoned runs do not block: the target locks on the servers
    # (Invoke-PASRemoteLock) are what protects a half-installed server from a different run.
    param([string]$Name,[string]$DataRoot,[string]$ExcludeRunId='')
    $live = @(Get-PASRunRecords -DataRoot $DataRoot | Where-Object { $_.name -eq $Name -and $_.id -ne $ExcludeRunId -and $_.status -in @('Launching','Running') })
    if ($live.Count) {
        throw "Environment '$Name' is being deployed right now by run $($live[0].id) (controller process $($live[0].controllerPid)). Wait for it, or stop it with Stop-PASRun -RunId $($live[0].id) -Force."
    }
}
function Wait-PASControllerCompletion {
    param([string]$RunId,[string]$DataRoot,[int]$ControllerPid=0,[datetime]$ControllerStartedAfterUtc=[datetime]::MinValue)
    $bootstrapDeadline=[DateTime]::UtcNow.AddSeconds(60)
    do{
        $observed=Get-PASRunRecord -RunId $RunId -DataRoot $DataRoot
        if(-not $observed){throw 'Controller run metadata disappeared'}
        if($ControllerPid){
            $stamp=[string](Get-PASValue $observed 'controllerStartedUtc' '')
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
function Assert-PASVaultInstallationSecrets {
    param([hashtable]$Configuration,[hashtable]$Secrets,[switch]$ReferencesResolved)
    # Only native Vault installation uses the qualified PACLI v15 text grammar.
    # Existing-Vault REST credentials and the Master recovery password are separate contracts.
    $vaults=@($Configuration.components | Where-Object {$_.type -eq 'Vault'})
    if(-not $vaults.Count){return}
    if(-not $ReferencesResolved){$Secrets=Resolve-PASSecretMap -Config $Configuration -SecretMap $Secrets}
    $required=@('VaultAdmin','VaultMaster')
    if(@($Configuration.components | Where-Object {$_.type -eq 'DRVault'}).Count){$required+='DRPassword'}
    foreach($name in $required){
        if(-not $Secrets.ContainsKey($name) -or $Secrets[$name] -isnot [Security.SecureString] -or $Secrets[$name].Length -eq 0){throw ($name+' SecureString is required before Vault installation')}
        $plain=$null
        try {
            $plain=Get-PASSecretPlaintext $Secrets[$name]
            if($name -eq 'VaultMaster'){
                if($plain -match '[^\x20-\x21\x23-\x7e]'){throw 'VaultMaster requires printable ASCII without double quotes for the supplied unescaped installer response format; no target changes were dispatched'}
                continue
            }
            if($plain.Length -gt 4096 -or $plain -match '[^\x20-\x21\x23-\x7e]'){throw ($name+' requires printable ASCII without double quotes for supplied PACLI v15; no target changes were dispatched')}
        }finally{$plain=$null}
    }
}
function Start-PASDeployment {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Config,$Configuration,[hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},
        [string]$DataRoot=(Get-PASDataRoot),[switch]$Foreground,[switch]$PlanOnly)
    $assessment=Test-PASConfiguration -Config $Config -Configuration $Configuration -CheckMedia
    if(-not $assessment.Valid){throw ($assessment.Issues -join '; ')}
    $c=$assessment.Configuration
    $plan=Get-PASDeploymentPlan -Configuration $c -ResolveMedia
    if($PlanOnly){return $plan}
    Assert-PASWindowsController
    if(-not $PSCmdlet.ShouldProcess([string]$c.name,'Start CyberArk deployment')){return $plan}
    Assert-PASVaultInstallationSecrets -Configuration $c -Secrets $SecretMap
    Assert-PASEnvironmentNotRunning -Name ([string]$c.name) -DataRoot $DataRoot
    # WinRM needs an explicit local account for workgroup servers ('Administrator' -> '.\Administrator').
    $CredentialMap=ConvertTo-PASControllerCredentialMap $c $CredentialMap
    $id=[guid]::NewGuid().ToString('N');$dir=Get-PASRunDirectory $id $DataRoot
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
            Invoke-PASRunController -RunId $id -DataRoot $DataRoot -InMemoryAuth @{Credentials=$CredentialMap;Secrets=$SecretMap}
        }else{
            Save-PASEnvelope -Path $envelope -Credentials $CredentialMap -Secrets $SecretMap
            $scriptPath=Join-Path $script:PASRoot 'Controllers/Invoke-PASRunController.ps1'
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
            $why=[string]$_.Exception.Message
            if($_.Exception -is [Security.Cryptography.CryptographicException] -or $why -match 'Access is denied'){
                $why+=' (The credentials are handed to the controller with Windows DPAPI. Start the deployment from a local session on the controller - console or RDP - not from a remote PowerShell session.)'
            }
            $run.status='LaunchFailed';$run.message='The controller could not be started: '+$why
            $run.finishedUtc=[DateTime]::UtcNow.ToString('o')
            Write-PASJsonAtomic (Join-Path $dir 'run-v2.json') $run
        }
        throw
    }
    if($consoleChild){Wait-PASControllerCompletion -RunId $id -DataRoot $DataRoot -ControllerPid ([int]$spawn.ProcessId) -ControllerStartedAfterUtc $launchAfter}
    return $id
}
function Resolve-PASRetrySteps {
    <# -RetryStep names steps the operator wants executed again after inspecting the server:
       '<step>' or '<component>:<step>', for example 'install' or 'cpm01:install'.
       Returns @{ <engine target> = @(<step id>, ...) } for the named steps whose journal says Failed or
       Unknown. A name that matches no such step is an error, so nothing is ever retried by accident. #>
    param([string]$RunDirectory,[string[]]$RetryStep = @())
    $result = @{}
    $journals = @(Get-ChildItem -LiteralPath $RunDirectory -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'state.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    foreach ($entry in @($RetryStep | Where-Object { $_ })) {
        if ($entry -notmatch '^(?:(?<component>[A-Za-z0-9_.-]+):)?(?<step>[A-Za-z0-9_.-]+)$') {
            throw "Invalid -RetryStep '$entry'. Use <step> or <component>:<step>."
        }
        $wantedComponent = [string]$Matches['component']
        $step = [string]$Matches['step']
        $found = $false
        foreach ($journal in $journals) {
            $target = Split-Path -Leaf (Split-Path -Parent $journal)
            if ($wantedComponent -and $wantedComponent -ne $target -and $wantedComponent -ne (ConvertTo-PASComponentId $target)) { continue }
            $state = Read-PASJournal $journal
            $stepState = Get-PASValue (Get-PASValue $state 'steps' $null) $step $null
            if ($stepState -and [string](Get-PASValue $stepState 'status' '') -in @('Failed','Unknown')) {
                if (-not $result.ContainsKey($target)) { $result[$target] = @() }
                if ($result[$target] -notcontains $step) { $result[$target] += $step }
                $found = $true
            }
        }
        if (-not $found) { throw "-RetryStep '$entry': this run has no step of that name that is Failed or Unknown." }
    }
    return $result
}
function Resume-PASDeployment {
    <#
    .SYNOPSIS
    Resumes a run that stopped: finished components are revalidated, the remaining ones are installed.
    .DESCRIPTION
    Uses the run's saved configuration and plan. Remote attempts that were still running are reconciled,
    never started a second time. A step that ended Failed or Unknown is not repeated on its own: inspect
    the server, then name the step with -RetryStep to run it again.
    -RetryFailedPreflight runs a failed read-only Linux preflight again, for example after you installed a
    missing OS package on the server.
    .PARAMETER RetryStep
    Step ids to execute again, as '<step>' or '<component>:<step>' (for example 'install', 'cpm01:register').
    Only steps whose journal says Failed or Unknown are accepted.
    .EXAMPLE
    Resume-PASDeployment -RunId 688d8e04f1874d41a75cda4441c00553 -CredentialMap $creds -SecretMap $secrets -Confirm:$false
    .EXAMPLE
    Resume-PASDeployment -RunId $id -CredentialMap $creds -SecretMap $secrets -RetryStep 'pvwa01:install' -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]param([Parameter(Mandatory)][string]$RunId,
        [hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},[string]$DataRoot=(Get-PASDataRoot),
        [string[]]$RetryStep=@(),[switch]$Foreground,[switch]$RetryFailedPreflight)
    $run=Get-PASRunRecord -RunId $RunId -DataRoot $DataRoot
    if(-not $run){throw 'Run not found'}
    if($run.status -notin @('Failed','Unknown','Interrupted','LaunchFailed','Blocked')){throw "Cannot resume a run whose status is $($run.status)"}
    Assert-PASWindowsController
    $dir=Get-PASRunDirectory $RunId $DataRoot
    # Fail here, in the caller's console, when a name is wrong; the controller resolves the names again.
    $RetryStep=@($RetryStep | Where-Object { $_ })
    [void](Resolve-PASRetrySteps -RunDirectory $dir -RetryStep $RetryStep)
    if(-not $PSCmdlet.ShouldProcess($RunId,'Resume deployment')){return $run}
    $envelope=Join-Path $dir ('credentials-'+[guid]::NewGuid().ToString('N')+'.json')
    $savedConfig=Read-PASConfiguration -Path (Join-Path $dir 'config.json')
    $CredentialMap=ConvertTo-PASControllerCredentialMap $savedConfig $CredentialMap
    $consoleChild=($Foreground -and @($savedConfig.components|Where-Object {$savedConfig.hosts[[string]$_.host].os -eq 'Linux'}).Count -gt 0)
    if($Foreground -and -not $consoleChild){Invoke-PASRunController -RunId $RunId -DataRoot $DataRoot -InMemoryAuth @{Credentials=$CredentialMap;Secrets=$SecretMap} -Resume -RetryFailedPreflight:$RetryFailedPreflight -RetryStep $RetryStep}
    else{
        Save-PASEnvelope -Path $envelope -Credentials $CredentialMap -Secrets $SecretMap
        $scriptPath=Join-Path $script:PASRoot 'Controllers/Invoke-PASRunController.ps1'
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$scriptPath+'" -RunId "'+$RunId+'" -DataRoot "'+$DataRoot+'" -Envelope "'+$envelope+'" -Resume'
        if($RetryFailedPreflight){$args+=' -RetryFailedPreflight'}
        # Step names were checked above ([A-Za-z0-9_.:-] only); they travel as one comma-separated argument.
        if($RetryStep.Count){$args+=' -RetryStep "'+($RetryStep -join ',')+'"'}
        $startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0;CreateFlags=[uint32]16}
        $launchAfter=[DateTime]::UtcNow.AddSeconds(-1)
        $spawn=Invoke-CimMethod Win32_Process Create -Arguments @{CommandLine=('"'+$exe+'" '+$args);CurrentDirectory=$script:PASRoot;ProcessStartupInformation=$startup}
        if($spawn.ReturnValue -ne 0 -or -not $spawn.ProcessId){
            if(Test-Path -LiteralPath $envelope){Remove-Item -LiteralPath $envelope -Force -ErrorAction SilentlyContinue}
            throw "Cannot start the resume controller: Win32_Process.Create=$($spawn.ReturnValue)"
        }
    }
    if($consoleChild){Wait-PASControllerCompletion -RunId $RunId -DataRoot $DataRoot -ControllerPid ([int]$spawn.ProcessId) -ControllerStartedAfterUtc $launchAfter}
    return $RunId
}
# ---- One run = one controller process that installs the components one after the other:
#      AD forest -> domain joins -> Vault (+DR) -> PVWA, CPM, PSM, PSMP (plan order).
#      Every function below takes the run context ($Run) created by Invoke-PASRunControllerCore:
#        RunId, DataRoot, Directory, Config (in memory), Credentials, Secrets,
#        Record (content of run-v2.json) and RecordPath, Target (engine target that is running),
#        SshReady (Linux hosts already bootstrapped by this process), RetryFailedPreflight,
#        Retry (@{ engine target = step ids the operator wants executed again }).

function Set-PASRunCurrentComponent {
    param([hashtable]$Run,[string]$ComponentId)
    $Run.Record.currentComponent = $ComponentId
    # No engine target is running until Invoke-PASRunTarget starts one (see Get-PASRunFailureStatus).
    $Run.Target = ''
    Write-PASJsonAtomic $Run.RecordPath $Run.Record
}
function Get-PASComponentRunFiles {
    # Where one component keeps its generated workflow, its inventory and its journal inside the run directory.
    param([string]$RunDirectory,[string]$ComponentId)
    $payload = Join-Path (Join-Path $RunDirectory 'Payloads') $ComponentId
    return @{
        Workflow  = Join-Path (Join-Path $payload 'Workflows') ($ComponentId + '.psd1')
        Inventory = Join-Path $payload 'inventory.psd1'
        State     = Join-Path (Join-Path $RunDirectory $ComponentId) 'state.json'
    }
}
function Add-PASFrozenMedia {
    # Approves a file that was resolved at run time (captured PVWA certificate, re-selected PSMP package).
    # The Transfer step uploads only files listed in $script:PASFrozenMedia with a matching SHA-256.
    param([string]$Path,[string]$SHA256)
    if ($null -eq $script:PASFrozenMedia -or -not $Path -or -not $SHA256) { return }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $script:PASFrozenMedia.ContainsKey($full)) { $script:PASFrozenMedia[$full] = $SHA256.ToUpperInvariant() }
}
function Initialize-PASComponentRun {
    <# Prepares one component right before it runs and returns the paths of its workflow, inventory and journal.
       Pre-steps on the controller: key-based SSH for a Linux server, the PSMP package matching the server's
       distribution, the certificate of the PVWA a CPM pins. Then the component's own workflow and inventory
       are written. The inventory is written last and marks the component as prepared: on resume it is reused
       unchanged, because the engine pins a digest of workflow + inventory in the component's journal. #>
    param([hashtable]$Run,[hashtable]$Component)
    $config = $Run.Config
    $id = [string]$Component.id
    $type = [string]$Component.type
    $hostId = [string]$Component.host
    $hostRecord = $config.hosts[$hostId]
    $files = Get-PASComponentRunFiles $Run.Directory $id
    $prepared = Test-Path -LiteralPath $files.Inventory -PathType Leaf

    # Linux servers of a composed configuration carry the controller key paths; make key sign-in work first.
    $hasSshKey = ($hostRecord.os -eq 'Linux' -and [string](Get-PASValue $hostRecord 'identityFile' '') -and [string](Get-PASValue $hostRecord 'knownHostsFile' ''))
    if ($hasSshKey) {
        if (-not $Run.SshReady.ContainsKey($hostId)) {
            $lab = ([string]$config.security.profile -eq 'Lab')
            $password = Get-PASHostCredential $config $Run.Credentials $hostId $id
            Invoke-PASSshBootstrap -HostId $hostId -HostRecord $hostRecord -Credential $password -Lab $lab -Directory $Run.Directory
            $Run.SshReady[$hostId] = $true
        }
        if (-not $prepared -and $type -eq 'PSMP') {
            Select-PASPsmpMediaForHost -Component $Component -HostRecord $hostRecord -Directory $Run.Directory -DataRoot $Run.DataRoot
        }
    }
    if (-not $prepared -and $type -eq 'CPM') {
        $options = Get-PASValue $Component 'options' $null
        $trustFrom = [string](Get-PASValue $options 'pvwaTrustFrom' '')
        if ($trustFrom) {
            $trust = Get-PASPvwaCertificate -Configuration $config -PvwaId $trustFrom -Credentials $Run.Credentials -Directory $Run.Directory
            $options.Remove('pvwaTrustFrom')
            $options.pvwaTrustCertificateFile = [string]$trust.File
            $options.pvwaTrustCertificateSHA256 = [string]$trust.SHA256
        }
    }
    if (-not $prepared) {
        [void](New-PASComponentWorkflow -Component $Component -Configuration $config -RunDirectory $Run.Directory)
        $inventory = New-PASRuntimeInventory -Config $config -RunDirectory $Run.Directory -CredentialMap $Run.Credentials -ComponentId $id
        [IO.File]::WriteAllText($files.Inventory, (ConvertTo-PASLiteral $inventory), [Text.UTF8Encoding]::new($false))
    }
    # Files named by the (new or reused) inventory are what this component may upload.
    $values = (Import-PowerShellDataFile -Path $files.Inventory).Values.Components[$id]
    Add-PASFrozenMedia ([string](Get-PASValue $values 'MediaZip' '')) ([string](Get-PASValue $values 'MediaSHA256' ''))
    Add-PASFrozenMedia ([string](Get-PASValue $values 'PVWATrustCertificateFile' '')) ([string](Get-PASValue $values 'PVWATrustCertificateSHA256' ''))
    return $files
}
function Invoke-PASRunTarget {
    # Runs one engine workflow of the run, or resumes it when its journal already exists. A target whose
    # journal says Succeeded is only revalidated (read-only) by the engine, so a resumed run continues
    # with the first component that is not finished.
    param([hashtable]$Run,[string]$Target,[string]$WorkflowPath,[string]$InventoryPath,[string[]]$Retry=@())
    $Run.Target = $Target
    $statePath = Join-Path (Join-Path $Run.Directory $Target) 'state.json'
    $resume = Test-Path -LiteralPath $statePath -PathType Leaf
    $arguments = @{
        WorkflowPath = $WorkflowPath; InventoryPath = $InventoryPath; StateRoot = (Join-Path $Run.DataRoot 'Runs')
        RunId = $Run.RunId; Credentials = $Run.Credentials; Secrets = $Run.Secrets; Resume = $resume
    }
    # Steps to execute again: named by the operator (-RetryStep) or a failed read-only preflight.
    $retrySteps = @($Retry)
    if ($Run.Retry.ContainsKey($Target)) { $retrySteps += @($Run.Retry[$Target]) }
    $retrySteps = @($retrySteps | Where-Object { $_ } | Select-Object -Unique)
    if ($resume -and $retrySteps.Count) { $arguments.Retry = $retrySteps }
    # Steps that open a Vault session take the Vault lock of this address (Locks.ps1).
    $vaultAddress = [string](Get-PASValue (Get-PASValue $Run.Config 'vault' $null) 'address' '')
    if ($vaultAddress) { $arguments.VaultAddress = $vaultAddress }
    Invoke-PASWorkflow @arguments | Out-Null
}
function Add-PASDomainCredentialAlias {
    # After promotion the local Administrator of the new domain controller is the domain Administrator:
    # same password, domain name. The AD target signs in with '<component id>-domain' once the local
    # account is gone. An alias supplied by the caller is kept.
    param([hashtable]$Config,[hashtable]$Credentials)
    foreach ($component in @($Config.components | Where-Object { $_.type -eq 'AD' })) {
        $id = [string]$component.id
        $domainRef = $id + '-domain'
        if ($Credentials.ContainsKey($domainRef) -or -not $Credentials.ContainsKey($id)) { continue }
        $netbios = ([string]$Config.activeDirectory.domain).Split('.')[0].ToUpperInvariant()
        $configuredNetbios = [string](Get-PASValue (Get-PASValue $component 'options' $null) 'domainNetbios' '')
        if ($configuredNetbios) { $netbios = $configuredNetbios }
        $user = ([string]$Credentials[$id].UserName).Split([char]92)[-1].Split('@')[0]
        $Credentials[$domainRef] = [pscredential]::new(($netbios + '\' + $user), $Credentials[$id].Password)
    }
}
function Invoke-PASActiveDirectoryForest {
    # Domain promotion runs before the joins and before every PAM component.
    param([hashtable]$Run)
    $components = @($Run.Config.components | Where-Object { $_.type -eq 'AD' })
    if (-not $components.Count) { return }
    $component = $components[0]
    $id = [string]$component.id
    if (-not $Run.Credentials.ContainsKey($id)) { throw 'AD host credential required' }
    Add-PASDomainCredentialAlias -Config $Run.Config -Credentials $Run.Credentials
    Set-PASRunCurrentComponent $Run $id
    Write-PASRunEvent $Run.Directory 'ADForest' 'Creating/verifying Active Directory forest' $id
    $files = Initialize-PASComponentRun -Run $Run -Component $component
    Invoke-PASRunTarget -Run $Run -Target $id -WorkflowPath $files.Workflow -InventoryPath $files.Inventory
    Write-PASRunEvent $Run.Directory 'ComponentCompleted' 'Verified AD' $id
}
function Invoke-PASDomainJoins {
    param([hashtable]$Run)
    $config = $Run.Config
    if ($config.activeDirectory.mode -eq 'None') { return }
    foreach ($hostId in @($config.activeDirectory.join)) {
        $id = 'join-' + [string]$hostId
        $workflow = Join-Path (Join-Path (Join-Path (Join-Path $Run.Directory 'Payloads') $id) 'Workflows') ($id + '.psd1')
        $inventory = Join-Path $Run.Directory ($id + '-inventory.psd1')
        if (-not (Test-Path -LiteralPath $workflow) -or -not (Test-Path -LiteralPath $inventory)) {
            $join = New-PASDomainJoinWorkflow -Config $config -HostId ([string]$hostId) -RunDirectory $Run.Directory
            $workflow = $join.Workflow
            $inventory = $join.Inventory
        }
        if (-not $Run.Credentials.ContainsKey([string]$hostId)) { throw "Missing host PSCredential for domain join host $hostId" }
        if (-not $Run.Secrets.ContainsKey('DomainJoinPassword')) { throw 'DomainJoinPassword SecureString is required for domain joins' }
        Set-PASRunCurrentComponent $Run $id
        Write-PASRunEvent $Run.Directory 'DomainJoin' "Joining $hostId to $($config.activeDirectory.domain)" $id
        Invoke-PASRunTarget -Run $Run -Target $id -WorkflowPath $workflow -InventoryPath $inventory
    }
}
function Invoke-PASVaultSequence {
    # Primary Vault, or Primary + DR as four phases: primary phase 1, DR phase 1, primary phase 2, DR phase 2.
    param([hashtable]$Run)
    $Config = $Run.Config
    $Credentials = $Run.Credentials
    $Secrets = $Run.Secrets
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
    $inventoryPath=Join-Path $Run.Directory 'vault-inventory.psd1'
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
    $workflowDir=Join-Path (Get-PASModuleRoot) 'Recipes/Vault/Workflows'
    $names=if($dr.Count){@('VaultPrimary-Phase1.psd1','VaultDR-Phase1.psd1','VaultPrimary-Phase2.psd1','VaultDR-Phase2.psd1')}else{@('VaultPrimaryOnly.psd1')}
    foreach($name in $names){
        $wf=Join-Path $workflowDir $name
        $plan=Get-PASWorkflowPlan -WorkflowPath $wf -InventoryPath $inventoryPath
        # The Vault journals its two roles as primary/primary_final and dr/dr_final.
        $componentId=if($plan.TargetName -like 'dr*'){[string]$dr[0].id}else{[string]$primary.id}
        Set-PASRunCurrentComponent $Run $componentId
        Invoke-PASRunTarget -Run $Run -Target $plan.TargetName -WorkflowPath $wf -InventoryPath $inventoryPath
    }
}
function Invoke-PASComponent {
    # One PVWA, CPM, PSM or PSMP: pre-steps, then its workflow.
    param([hashtable]$Run,[hashtable]$Component)
    $id = [string]$Component.id
    $type = [string]$Component.type
    Set-PASRunCurrentComponent $Run $id
    Write-PASRunEvent $Run.Directory 'ComponentStarted' "Starting $type" $id
    $files = Initialize-PASComponentRun -Run $Run -Component $Component
    $retry = @()
    if ($Run.RetryFailedPreflight -and (Test-Path -LiteralPath $files.State)) {
        $retry = @(Get-PASFailedPreflightRetry -WorkflowPath $files.Workflow -InventoryPath $files.Inventory -StatePath $files.State -Credentials $Run.Credentials)
    }
    Invoke-PASRunTarget -Run $Run -Target $id -WorkflowPath $files.Workflow -InventoryPath $files.Inventory -Retry $retry
    Write-PASRunEvent $Run.Directory 'ComponentCompleted' "Verified $type" $id
}
function Get-PASFailedPreflightRetry {
    param([string]$WorkflowPath,[string]$InventoryPath,[string]$StatePath,[hashtable]$Credentials=@{})
    $state=Read-PASJournal $StatePath
    if(-not $state){throw 'Preflight retry requires an existing component journal'}
    $step=Get-PASValue (Get-PASValue $state 'steps' @{}) 'preflight' $null
    if(-not $step -or (Get-PASValue $step 'status' '') -notin @('Failed','Unknown','Dispatched','Running')){return @()}
    $plan=Get-PASWorkflowPlan -WorkflowPath $WorkflowPath -InventoryPath $InventoryPath
    if($state.digest -ne $plan.Digest){throw 'Preflight retry refuses changed workflow, scripts or inventory'}
    $definition=@($plan.Steps|Where-Object {$_.Id -eq 'preflight'})
    if($plan.Target.Protocol -ne 'SSH' -or $plan.Runtime -ne 'Bash' -or $definition.Count -ne 1 -or
       (Get-PASValue $definition[0].Inputs 'Stage' '') -cne 'Preflight'){
        throw 'Explicit preflight retry currently supports only the fixed Linux preflight stage'
    }
    $attempt=[string](Get-PASValue $step 'attemptId' '')
    if($attempt -notmatch '^[a-f0-9]{32}$'){throw 'Preflight retry requires the original durable attempt'}
    $remote=Get-PASDetachedStatus $plan.Target $Credentials $attempt
    $active=Get-PASValue $remote 'workerActive' $null
    if((Get-PASValue $remote 'state' '') -cne 'Failed' -or (Get-PASValue $remote 'attemptId' '') -cne $attempt -or
       $active -isnot [bool] -or $active){throw 'Preflight retry requires the same known-failed attempt with proven worker exit'}
    return @('preflight')
}
function Get-PASRunFailureStatus {
    <# The status of a run that stopped with an error. It comes from what the engine itself recorded, not
       from words in the message:
         Blocked  the server is locked by another run (message starts with PAExecLocked:)
         Unknown  the outcome on the server cannot be established (message starts with Unknown: or
                  PAExecUnknown:, or the target's journal says so); never repeated automatically
         Failed   everything else. #>
    param([string]$Message,[string]$StatePath = '')
    if ($Message -match '^PAExecLocked:') { return 'Blocked' }
    if ($Message -match '^(Unknown:|PAExecUnknown:)') { return 'Unknown' }
    if ($StatePath) {
        $state = $null
        try { $state = Read-PASJournal $StatePath } catch { $state = $null }
        $status = [string](Get-PASValue $state 'status' '')
        if ($status -in @('Unknown','Blocked')) { return $status }
    }
    return 'Failed'
}
function Invoke-PASRunController {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot),[string]$Envelope,[switch]$Resume,[hashtable]$InMemoryAuth,[switch]$RetryFailedPreflight,[string[]]$RetryStep=@())
    Assert-PASWindowsController
    $dir=Get-PASRunDirectory $RunId $DataRoot
    # Run lock: one controller process per run. Acquire it before reading/changing the run record. A second
    # Resume may race the first caller, but it must never overwrite that owner's status.
    # Keep the empty lockfile: deleting it can create two independent lock files.
    $lease=Get-PASFileLock (Join-Path $dir 'controller.lock')
    try{
        $path=Join-Path $dir 'run-v2.json'
        $run=Read-PASJson $path
        if(-not $run){throw 'Controller run metadata is missing'}
        $run.controllerPid=$PID
        $run|Add-Member NoteProperty controllerStartedUtc ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')) -Force
        $run.status='Launching';$run.message='Validating deployment controller';$run.finishedUtc=$null
        Write-PASJsonAtomic $path $run
        try{
            Invoke-PASRunControllerCore -RunId $RunId -DataRoot $DataRoot -Envelope $Envelope -Resume:$Resume -InMemoryAuth $InMemoryAuth -RetryFailedPreflight:$RetryFailedPreflight -RetryStep $RetryStep
        }catch{
            $failure=$_
            $observed=Read-PASJson $path
            if($observed -and $observed.controllerPid -eq $PID -and $observed.status -eq 'Launching'){
                # Still Launching: nothing was sent to any server. Say why the controller stopped.
                $observed.status='LaunchFailed';$observed.message='The controller stopped before any server was contacted: '+[string]$failure.Exception.Message
                $observed.finishedUtc=[DateTime]::UtcNow.ToString('o')
                Write-PASJsonAtomic $path $observed
            }
            throw $failure
        }
    }finally{$lease.Dispose()}
}
function Invoke-PASRunControllerCore {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot),[string]$Envelope,[switch]$Resume,[hashtable]$InMemoryAuth,[switch]$RetryFailedPreflight,[string[]]$RetryStep=@())
    Assert-PASWindowsController
    $dir=Get-PASRunDirectory $RunId $DataRoot
    $config=Read-PASConfiguration -Path (Join-Path $dir 'config.json')
    $plan=Get-PASDeploymentPlan -Configuration $config -ResolveMedia
    $saved=Read-PASJson (Join-Path $dir 'plan-v2.json')
    # The run executes exactly what was planned. Module files may change between start and resume;
    # the configuration and the installer media may not.
    if (-not $saved) { throw 'The saved plan of this run is missing or unreadable. Refusing execution.' }
    if ([string](Get-PASValue $saved 'ConfigDigest' '') -ne $plan.ConfigDigest) {
        throw 'The configuration of this run changed since it was planned (ConfigDigest differs). Refusing execution; start a new run.'
    }
    if ([string](Get-PASValue $saved 'MediaDigest' '') -ne $plan.MediaDigest) {
        throw 'The installer media changed since this run was planned (MediaDigest differs: a media file was replaced, moved or modified). Restore the original files or start a new run.'
    }
    $script:PASFrozenMedia=@{}
    foreach($asset in @($plan.Media)){$script:PASFrozenMedia[[string]$asset.Path]=[string]$asset.SHA256}
    if($InMemoryAuth){$auth=$InMemoryAuth}else{
        $auth=Read-PASEnvelope $Envelope
        Remove-Item -LiteralPath $Envelope -Force -ErrorAction Stop
    }
    # The complete credential map stays in the controller: Windows credentials for WinRM, the password
    # of a Linux server for its one-time SSH key bootstrap, task identities such as PSMDomainInstaller.
    $auth.Credentials=Resolve-PASCredentialMap -Config $config -CredentialMap $auth.Credentials
    $auth.Secrets=Resolve-PASSecretMap -Config $config -SecretMap $auth.Secrets
    $retry=Resolve-PASRetrySteps -RunDirectory $dir -RetryStep $RetryStep
    $recordPath=Join-Path $dir 'run-v2.json'
    $record=Read-PASJson $recordPath
    $record | Add-Member NoteProperty controllerStartedUtc ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')) -Force
    $record.controllerPid=$PID;$record.status='Running';$record.message='Executing deployment';$record.finishedUtc=$null
    Write-PASJsonAtomic $recordPath $record
    $run=@{RunId=$RunId;DataRoot=$DataRoot;Directory=$dir;Config=$config;Credentials=$auth.Credentials;Secrets=$auth.Secrets
        Record=$record;RecordPath=$recordPath;Target='';SshReady=@{};RetryFailedPreflight=[bool]$RetryFailedPreflight;Retry=$retry}
    try {
        Assert-PASVaultInstallationSecrets -Configuration $config -Secrets $auth.Secrets -ReferencesResolved
        if ($Resume) { Write-PASRunEvent $dir 'RunResumed' 'Resuming the run: finished components are revalidated, then the remaining ones are installed' }
        foreach ($warning in @($plan.Warnings | Where-Object { $_ -like 'execution.mode*' })) { Write-PASRunEvent $dir 'Warning' ([string]$warning) '' '' 'Warning' }
        if (-not $Resume) {
            foreach ($item in @($plan.Items)) {
                Write-PASRunEvent $dir 'TaskCompleted' 'Local configuration and media checks passed' ([string]$item.Id) 'LocalPreflight'
            }
        }

        Invoke-PASActiveDirectoryForest -Run $run
        Invoke-PASDomainJoins -Run $run
        if(@($config.components|Where-Object{$_.type -eq 'Vault'}).Count){
            Write-PASRunEvent $dir 'VaultSequence' 'Starting primary/DR installation'
            # The whole sequence (PACLI, DR registration, replication) holds the Vault lock, so no other
            # controller on this machine opens a Vault session in between. Its steps take the same lock
            # again (re-entrant) and release only their own hold.
            $vaultLock=Enter-PASVaultLock -Address ([string]$config.vault.address)
            try{Invoke-PASVaultSequence -Run $run}finally{Exit-PASVaultLock $vaultLock}
        }
        # Plan order: every PVWA, then CPM, PSM, PSMP. A failure stops the run here; Resume-PASDeployment
        # re-enters this loop, where finished components are revalidated and the rest is installed.
        foreach($item in @($plan.Items|Where-Object{$_.Type -notin @('Vault','DRVault','AD')})){
            $component=@($config.components|Where-Object{$_.id -eq $item.Id})[0]
            Invoke-PASComponent -Run $run -Component $component
        }
        $record.status='Succeeded';$record.message='All selected component workflows completed';$record.currentComponent=''
        Write-PASRunEvent $dir 'RunCompleted' $record.message
    }catch{
        $reason=[string]$_.Exception.Message
        $hide=@()
        foreach($sec in @($auth.Secrets.Values)){try{$hide+=,(Get-PASSecretPlaintext $sec)}catch{}}
        foreach($cred in @($auth.Credentials.Values)){try{$hide+=,(Get-PASSecretPlaintext $cred.Password)}catch{}}
        $reason=Protect-PASText $reason $hide
        # Unknown means the remote side may still be running; never auto-retry a second installer.
        $statePath=''
        if($run.Target){$statePath=Join-Path (Join-Path $dir $run.Target) 'state.json'}
        $record.status=Get-PASRunFailureStatus -Message $reason -StatePath $statePath
        $record.message=$reason
        Write-PASRunEvent $dir 'RunStopped' $reason ([string]$record.currentComponent) '' 'Error'
        throw $reason
    }finally{
        $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
        Write-PASJsonAtomic $recordPath $record
        $auth=$null
        $script:PASFrozenMedia=$null
    }
}

# ---- Stop or abandon a run

function Get-PASRunLockedTargets {
    <# The servers on which a run may still hold its target lock, read from the inventories the run wrote:
       every engine target that was started and did not succeed (a successful workflow releases its lock).
       One entry per server lock: Name (engine target), Target (inventory entry), Computer, LockFolder. #>
    param([string]$RunDirectory)
    $files = @(Get-ChildItem -LiteralPath $RunDirectory -Filter '*inventory.psd1' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $payloads = Join-Path $RunDirectory 'Payloads'
    if (Test-Path -LiteralPath $payloads -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $payloads -Directory | ForEach-Object { Join-Path $_.FullName 'inventory.psd1' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }
    $seen = @{}
    foreach ($file in $files) {
        $inventory = Import-PowerShellDataFile -Path $file
        foreach ($name in @($inventory.Targets.Keys)) {
            $target = $inventory.Targets[$name]
            if ([string](Get-PASValue $target 'Protocol' '') -eq 'Local') { continue }
            $state = $null
            try { $state = Read-PASJournal (Join-Path (Join-Path $RunDirectory ([string]$name)) 'state.json') } catch { $state = @{ status = 'Unknown' } }
            if (-not $state -or [string](Get-PASValue $state 'status' '') -eq 'Succeeded') { continue }
            if (-not $target.Contains('Runtime')) { $target['Runtime'] = 'WindowsPowerShell' }
            $lockKey = [string](Get-PASValue $target 'LockKey' $name)
            $key = ([string]$target.ComputerName + '|' + $lockKey).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [pscustomobject]@{ Name = [string]$name; Target = $target; Computer = [string]$target.ComputerName; LockFolder = (Get-PASRemoteLockFolder $target $lockKey) }
        }
    }
}
function Stop-PASDeployment {
    <#
    .SYNOPSIS
    Stops or abandons a run: marks it Abandoned and releases the target locks it still holds.
    .DESCRIPTION
    A run that stopped (Failed, Unknown, Blocked, Interrupted, LaunchFailed) keeps a lock folder on every
    server it did not finish, so that no other run touches a half-installed server. Stop-PASDeployment is
    how you give those servers back: use it when you will not resume the run (typically after you reset
    or rebuilt the servers).
    - While the controller is still running it refuses, unless -Force is given: then it stops the
      controller process (only the process that is provably this run's controller).
    - The run is marked Abandoned and a RunStopped event is written. An Abandoned run cannot be resumed.
    - With -CredentialMap the lock of every unfinished server is released, if it still names this run.
      A server that cannot be reached becomes a warning, not an error.
    - Without -CredentialMap nothing is contacted; the lock folders to delete are listed instead.
    No installed software is changed or removed. Servers may hold a partial installation.
    .PARAMETER CredentialMap
    @{ <server id> = PSCredential }, as for Start-PASDeployment. Only needed to release the locks.
    .EXAMPLE
    Stop-PASDeployment -RunId 83cf015f78bd4743a54e6d0a9d0dd301 -CredentialMap $creds
    .EXAMPLE
    Stop-PASDeployment -RunId $id -Force     # stop a running controller; lists the lock folders
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
        [hashtable]$CredentialMap,[switch]$Force,[string]$DataRoot=(Get-PASDataRoot))
    $record = Get-PASRunRecord -RunId $RunId -DataRoot $DataRoot
    if (-not $record) { throw "Run $RunId was not found under $DataRoot" }
    $dir = Get-PASRunDirectory $RunId $DataRoot
    $recordPath = Join-Path $dir 'run-v2.json'
    $previous = [string]$record.status
    $running = ($previous -in @('Launching','Running'))
    if ($running -and -not $Force) {
        throw "Run $RunId is still running (controller process $($record.controllerPid)). Wait for it, or stop it with -Force."
    }
    if ($running -and -not $record.controllerPid) {
        throw "Run $RunId is starting and has no controller process yet. Try again in a moment."
    }
    # PID and start time must both match the run record (as in Get-PASRunRecord): a reused PID is never stopped.
    if ($running -and (Test-PASControllerAlive $record) -ne $true) {
        throw "Process $($record.controllerPid) cannot be confirmed as the controller of run $RunId; nothing was stopped."
    }
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Stop the run, mark it Abandoned and release its target locks')) { return }

    $controllerStopped = $false
    if ($running) {
        Stop-Process -Id ([int]$record.controllerPid) -Force -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ((Test-PASControllerAlive $record) -ne $false) {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Controller process $($record.controllerPid) of run $RunId did not end." }
            Start-Sleep -Milliseconds 300
        }
        $controllerStopped = $true
    }
    if ($previous -notin @('Succeeded','Abandoned')) {
        # Read the stored record again: Get-PASRunRecord may have adjusted the status it returned.
        $stored = Read-PASJson $recordPath
        $now = [DateTime]::UtcNow.ToString('o')
        $stored.status = 'Abandoned'
        $stored.message = "Stopped by the operator (was $previous). Servers of this run may hold a partial installation."
        $stored.finishedUtc = $now
        $stored | Add-Member NoteProperty abandonedUtc $now -Force
        Write-PASJsonAtomic $recordPath $stored
        Write-PASRunEvent $dir 'RunStopped' ([string]$stored.message) '' '' 'Warning'
    }

    $locks = @()
    $targets = @(Get-PASRunLockedTargets -RunDirectory $dir)
    if ($CredentialMap) {
        $config = Read-PASConfiguration -Path (Join-Path $dir 'config.json')
        $credentials = Resolve-PASCredentialMap -Config $config -CredentialMap (ConvertTo-PASControllerCredentialMap $config $CredentialMap)
        Add-PASDomainCredentialAlias -Config $config -Credentials $credentials
        try {
            foreach ($entry in $targets) {
                $released = $false
                $note = ''
                try {
                    # The server removes the lock only when its owner file names this RunId.
                    [void](Invoke-PASRemoteLock ([pscustomobject]@{ Target = $entry.Target; TargetName = $entry.Name }) $credentials $RunId -Release)
                    $released = $true
                } catch {
                    $note = [string]$_.Exception.Message
                    Write-Warning "The lock of $($entry.Name) on $($entry.Computer) was not released: $note. If it still names run $RunId, delete the folder $($entry.LockFolder) there."
                }
                $locks += [pscustomobject]@{ Target = $entry.Name; Computer = $entry.Computer; LockFolder = $entry.LockFolder; Released = $released; Message = $note }
            }
        } finally {
            Clear-PASConnections
        }
    } else {
        foreach ($entry in $targets) {
            Write-Host "Lock of $($entry.Name): delete the folder $($entry.LockFolder) on $($entry.Computer) if it still names run $RunId."
            $locks += [pscustomobject]@{ Target = $entry.Name; Computer = $entry.Computer; LockFolder = $entry.LockFolder; Released = $false; Message = 'Not contacted (no -CredentialMap)' }
        }
    }
    $status = $previous
    if ($previous -ne 'Succeeded') { $status = 'Abandoned' }
    return [pscustomobject]@{ RunId = $RunId; Status = $status; PreviousStatus = $previous; ControllerStopped = $controllerStopped; Locks = $locks }
}
