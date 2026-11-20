$script:PSCheckAttempts=3
$script:PSCheckRetryDelaySeconds=15
function Select-PASDeclaredInputs {
    # Checks receive the step's inputs, restricted to the parameters the check script declares, so a
    # verifier does not have to accept (or ever see) secrets it does not use.
    param([string]$Path,[hashtable]$Inputs)
    if($null -eq $Inputs){return @{}}
    if($Path -notmatch '\.ps1$'){return $Inputs}
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(-not $ast.ParamBlock){return @{}}
    $names=@($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $selected=@{}
    foreach($k in @($Inputs.Keys)){ if($names -contains $k){ $selected[$k]=$Inputs[$k] } }
    return $selected
}
function Get-PASCheck {
    # Read-only check. A check that cannot be evaluated raises PAExecUnknown; a negative result returns Passed=$false.
    param($Plan,[hashtable]$Credentials,[string]$Script,[hashtable]$Inputs,[string]$Property,[string]$Scope='Target',[int]$TimeoutSeconds=900)
    $checkTarget=$Plan.Target
    if($Scope -eq 'Controller'){$checkTarget=@{Protocol='Local';Runtime='PowerShell'}}
    $path=Assert-PASProjectPath $Plan.Root $Script
    $Inputs=Select-PASDeclaredInputs $path $Inputs
    # Checks are read-only, so a transient observation failure (e.g. sshd reloading its configuration right after a
    # hardening stage) is retried a bounded number of times before the result becomes Unknown.
    $check=$null
    for($try=1;;$try++){
        try { $check=Invoke-PASAdapterScript -Target $checkTarget -Credentials $Credentials -ScriptPath $path -Parameters $Inputs -Contract 'Object' -TimeoutSeconds $TimeoutSeconds; break }
        catch {
            $message=$_.Exception.Message
            if($try -lt $script:PSCheckAttempts -and $message -match 'observation timed out|Connection (reset|closed|refused|timed out)|kex_exchange_identification'){ Start-Sleep -Seconds $script:PSCheckRetryDelaySeconds; continue }
            throw "PAExecUnknown: check '$Script' could not be evaluated: $message"
        }
    }
    if(-not $check.Ok){throw "PAExecUnknown: check '$Script' did not complete: $($check.Error)"}
    $terminal=$check.Terminal
    $passed=Get-PASValue $terminal $Property $null
    if($passed -isnot [bool]){throw "PAExecUnknown: check '$Script' must return boolean $Property"}
    return [pscustomobject]@{ Passed=[bool]$passed; Message=[string](Get-PASValue $terminal 'Message' ''); Evidence=@(Get-PASValue $terminal 'Evidence' @()) }
}
function Wait-PASMilestone {
    param([string]$StateRoot,[string]$RunId,[string]$Milestone,[int]$TimeoutSeconds=1200,[string]$Waiter='',[hashtable]$Context=$null,[string]$TaskId='')
    if($Milestone -notmatch '^[a-zA-Z0-9_.-]+$'){throw 'Invalid milestone name'}
    $runRoot=Join-Path $StateRoot $RunId
    $path=Join-Path (Join-Path $runRoot 'milestones') ($Milestone+'.json')
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $announced=$false
    while([DateTime]::UtcNow -lt $deadline){
        $marker=Read-PASJournal $path
        if($marker -and $marker.verified -eq $true -and $marker.runId -eq $RunId){return $marker}
        if(-not $announced -and $Context){ Add-PASEvent $Context 'WaitingForMilestone' $TaskId "waiting for milestone '$Milestone'"; $announced=$true }
        # Stop waiting early when every other target of this run has terminated without publishing.
        $others=@(Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'milestones' -and $_.Name -ne $Waiter })
        if($others.Count -gt 0){
            $active=$false
            foreach($o in $others){
                $st=$null; try{$st=Read-PASJournal (Join-Path $o.FullName 'state.json')}catch{$st=$null}
                if(-not $st -or $st.status -eq 'Running'){$active=$true}
            }
            if(-not $active){
                Start-Sleep -Seconds 2
                $marker=Read-PASJournal $path
                if($marker -and $marker.verified -eq $true -and $marker.runId -eq $RunId){return $marker}
                throw "Milestone '$Milestone' can no longer be published: all other targets of run $RunId have stopped"
            }
        }
        Start-Sleep -Seconds 3
    }
    throw "PAExecUnknown: Milestone '$Milestone' was not verified before timeout"
}
function Write-PASMilestone {
    param([string]$StateRoot,[string]$RunId,[string]$Name,[string]$Target,[string]$TaskId)
    if($Name -notmatch '^[a-zA-Z0-9_.-]+$'){throw 'Invalid milestone name'}
    $path=Join-Path (Join-Path (Join-Path $StateRoot $RunId) 'milestones') ($Name+'.json')
    Write-PASJournal $path ([ordered]@{schemaVersion=1;runId=$RunId;target=$Target;taskId=$TaskId;verified=$true;utc=(Get-PASNow)})
}
function Save-PASState {
    param([hashtable]$Context)
    $Context.State.updatedUtc=Get-PASNow
    Write-PASJournal (Join-Path $Context.RunDirectory 'state.json') $Context.State
}
function Get-PASRemoteLockFolder {
    # The folder on the server that holds the target lock (its owner file names the RunId).
    param([hashtable]$Target,[string]$LockKey)
    if ([string](Get-PASValue $Target 'Runtime' '') -eq 'Bash') { return ('~/.paeasyinstall/locks/' + $LockKey) }
    $root = [string](Get-PASValue $Target 'StageRoot' 'C:\ProgramData\PAExec')
    return ($root.TrimEnd('\') + '\locks\' + $LockKey)
}
function Get-PASRemoteLockedMessage {
    # What the operator can do when a server is locked by another run.
    param([hashtable]$Target,[string]$LockKey,[string]$Answer)
    $owner = ([string]$Answer).Trim() -replace '^locked:', ''
    $folder = Get-PASRemoteLockFolder $Target $LockKey
    $server = [string](Get-PASValue $Target 'ComputerName' $LockKey)
    if ($owner -notmatch '^[A-Za-z0-9_-]{6,80}$') {
        return "PAExecLocked: server $server ('$LockKey') is locked, but the lock does not name its run. Check that no installation is running there, then delete the lock folder $folder on $server."
    }
    return "PAExecLocked: server $server ('$LockKey') is locked by run $owner. Either resume that run (Resume-PASRun -RunId $owner), or release it (Stop-PASRun -RunId $owner), or, if that run no longer exists on this controller, delete the lock folder $folder on $server."
}
function Invoke-PASRemoteLock {
    # Target lock: one run per server. Acquired when a workflow starts, released when it succeeds.
    # It stays on the server after a failure and is taken again by the same RunId on resume.
    param($Plan,[hashtable]$Credentials,[string]$RunId,[switch]$Release)
    $protocol=[string]$Plan.Target.Protocol
    if($protocol -eq 'Local'){return $false}
    $targetName=[string](Get-PASValue $Plan.Target 'LockKey' $Plan.TargetName)
    if($targetName -notmatch '^[A-Za-z0-9_.-]{1,64}$'){throw 'Invalid canonical host lock key'}
    if($Plan.Target.Runtime -eq 'Bash'){
        if($Release){$cmd='d=~/.paeasyinstall/locks/{0}; if [ "$(cat "$d/owner" 2>/dev/null)" = "{1}" ]; then rm -rf "$d"; fi; echo released' -f $targetName,$RunId}
        else{$cmd='mkdir -p ~/.paeasyinstall/locks && d=~/.paeasyinstall/locks/{0}; if mkdir "$d" 2>/dev/null; then echo {1} > "$d/owner"; echo acquired; elif [ "$(cat "$d/owner" 2>/dev/null)" = "{1}" ]; then echo acquired; else echo "locked:$(cat "$d/owner" 2>/dev/null)"; fi' -f $targetName,$RunId}
        $r=Invoke-PASRawSSH $Plan.Target $cmd
        if($r.ExitCode -ne 0){throw "Remote lock operation failed ($($r.ExitCode)): $($r.Output)"}
        if(-not $Release -and $r.Output -notmatch 'acquired'){throw (Get-PASRemoteLockedMessage $Plan.Target $targetName ([string]$r.Output))}
        return $true
    }
    $root=[string](Get-PASValue $Plan.Target 'StageRoot' 'C:\ProgramData\PAExec')
    $session=Get-PASConnection $Plan.Target $Credentials
    $reference=[string](Get-PASValue $Plan.Target 'CredentialRef' '')
    $user=if($reference -and $Credentials.ContainsKey($reference)){[string]$Credentials[$reference].UserName}else{''}
    $res=Invoke-Command -Session $session -ScriptBlock (Get-PASWindowsStagePreparation) -ArgumentList $root,$targetName,$RunId,([bool]$Release),$user -ErrorAction Stop
    $message=[string]$res.Message
    if(-not $Release -and $message -ne 'acquired'){throw (Get-PASRemoteLockedMessage $Plan.Target $targetName $message)}
    return $true
}
function Test-PASStepCompleted {
    # Read-only revalidation of a checkpointed step before it is trusted on resume.
    param($Plan,$Step,[hashtable]$Credentials,[hashtable]$Inputs,[string]$Scope,[string]$Kind,[string]$StateRoot,[string]$RunId,[hashtable]$Secrets,[hashtable]$Outputs,[hashtable]$Runtime,$Current,[hashtable]$Context)
    $verify=[string](Get-PASValue $Step 'Verify' '')
    $probe=[string](Get-PASValue $Step 'Probe' '')
    if($verify -or $probe){
        $checkName=$verify;$property='Passed'
        if(-not $verify){$checkName=$probe;$property='Satisfied'}
        $check=Get-PASStepCheck -Plan $Plan -Step $Step -Credentials $Credentials -Inputs $Inputs -Current $Current -Context $Context -Script $checkName -Property $property -Scope $Scope -Purpose Revalidation -TimeoutSeconds ([int](Get-PASValue $Step 'TimeoutSeconds' 1800))
        Complete-PASCheckGeneration $Current
        if(-not $check.Passed){throw "PAExecUnknown: previously completed step failed read-only revalidation: $($check.Message)"}
        return 'verified by '+$checkName
    }
    if($Kind -eq 'Wait'){[void](Wait-PASMilestone $StateRoot $RunId ([string]$Step.Milestone) 5 $Plan.TargetName);return 'milestone present'}
    if($Kind -eq 'Reboot'){
        if([bool](Get-PASValue $Current 'rebootSkipped' $false)){
            if(Test-PASRebootRequired $Step $Outputs){throw 'PAExecUnknown: skipped reboot contradicts recorded vendor result'}
            return 'vendor result did not require reboot'
        }
        $before=[string](Get-PASValue $Current 'bootBefore' '')
        $after=[string](Get-PASValue $Current 'bootAfter' '')
        if(-not $before -or -not $after -or $before -eq $after){throw 'PAExecUnknown: completed reboot has no changed boot identifier'}
        return 'reboot evidence recorded (boot identifier changed)'
    }
    if($Kind -eq 'Transfer'){
        $guard=[string](Get-PASValue $Step 'BeforeTransfer' '')
        if($guard){
            $guardInputs=$Inputs.Clone();$guardInputs.ValidateOnly=$true
            $prepared=Get-PASCheck $Plan $Credentials $guard $guardInputs 'Passed' 'Target'
            if(-not $prepared.Passed){throw 'Upload destination safety check failed'}
        }
        $source=[string](Resolve-PASValue $Step.Source $Plan.Inventory $Secrets $Outputs $Runtime)
        $dest=[string](Resolve-PASValue $Step.Destination $Plan.Inventory $Secrets $Outputs $Runtime)
        if((Get-PASValue $Step 'Direction' 'Upload') -eq 'Upload'){
            if(-not [IO.Path]::IsPathRooted($source)){$source=Get-PASPath $Plan.Root $source}
            if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "PAExecUnknown: source missing for completed transfer"}
            if($Plan.Target.Protocol -eq 'WinRM' -and (Test-PASWindows)){
                $session=Get-PASConnection $Plan.Target $Credentials
                $ref=[string](Get-PASValue $Plan.Target 'CredentialRef' '')
                $user=if($ref -and $Credentials.ContainsKey($ref)){[string]$Credentials[$ref].UserName}else{''}
                [void](Invoke-Command -Session $session -ScriptBlock (Get-PASWindowsFilePreparation) -ArgumentList $dest,$user,$true -ErrorAction Stop)
            }
            $remote=Get-PASRemoteFileHash $Plan.Target $Credentials $dest
            if($remote -ne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToUpperInvariant()){throw 'PAExecUnknown: transferred file no longer matches source (target drift)'}
            return 'remote SHA-256 matches source'
        }
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw 'PAExecUnknown: downloaded file missing on controller'}
        return 'downloaded file present'
    }
    throw "PAExecUnknown: cannot trust checkpoint without a read-only Verify or Probe"
}
function Wait-PASVaultSessionEnd {
    # Called before the Vault lock of a finished step is released: the remote worker that held the Vault
    # session (the step's detached attempt, and the attempt of its detached check if it has one) must have
    # exited, so the next holder of the lock never overlaps with a session that is still open.
    param([hashtable]$Target,[hashtable]$Credentials,$StepState,[string]$Mode)
    if ($StepState.status -eq 'Skipped') { return }
    if ($Mode -eq 'Detached' -and (Get-PASValue $StepState 'attemptId' '')) {
        Wait-PASDetachedSessionQuiescence $Target $Credentials ([string]$StepState.attemptId)
    }
    $check = Get-PASValue $StepState 'check' $null
    if ($check -and (Get-PASValue $check 'attemptId' '')) {
        Wait-PASDetachedSessionQuiescence $Target $Credentials ([string]$check.attemptId)
    }
}
function Invoke-PASWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkflowPath,
        [Parameter(Mandatory=$true)][string]$InventoryPath,
        [string]$StateRoot=(Join-Path (Get-Location) 'state'),
        [string]$RunId=([guid]::NewGuid().ToString('N')),
        [hashtable]$Credentials=@{},[hashtable]$Secrets=@{},
        [string[]]$Retry=@(),[string]$VaultAddress='',
        [switch]$Resume,[switch]$PlanOnly,[switch]$Quiet
    )
    # -VaultAddress: steps marked RequiresVaultSession / VerifyRequiresVaultSession hold the Vault lock of
    # this address (Locks.ps1) while they run.
    $plan=Get-PASWorkflowPlan -WorkflowPath $WorkflowPath -InventoryPath $InventoryPath
    if($PlanOnly){
        return [pscustomobject]@{Name=$plan.Name;Target=$plan.TargetName;Protocol=$plan.Target.Protocol;Runtime=$plan.Runtime;Digest=$plan.Digest;Steps=@($plan.Steps|ForEach-Object { [pscustomobject]@{Id=$_.Id;Kind=(Get-PASValue $_ 'Kind' 'Script');Mode=(Get-PASValue $_ 'Mode' 'Direct');Scope=(Get-PASValue $_ 'Scope' 'Target');Verify=(Get-PASValue $_ 'Verify' '');DependsOn=@(Get-PASValue $_ 'DependsOn' @());Publishes=@(Get-PASValue $_ 'Publishes' @())} });MutatesTargets=$false}
    }
    if($RunId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{5,79}$'){throw 'Invalid RunId'}
    foreach($r in $Retry){ if(-not (@($plan.Steps | ForEach-Object { [string]$_.Id }) -contains $r)){ throw "Retry names unknown step '$r'" } }
    if($Retry.Count -gt 0 -and -not $Resume){throw '-Retry is only meaningful with -Resume'}
    $StateRoot=[IO.Path]::GetFullPath($StateRoot)
    $runDir=Join-Path (Join-Path $StateRoot $RunId) $plan.TargetName
    New-Item -Path $runDir -ItemType Directory -Force | Out-Null
    $lock=Get-PASFileLock (Join-Path $runDir '.run.lock')
    $redactions=@();foreach($s in $Secrets.Values){try{$redactions+=,(Get-PASSecretPlaintext $s)}catch{Write-Verbose 'non-string secret'}}
    foreach($c in $Credentials.Values){if($c -is [pscredential]){try{$redactions+=,(Get-PASSecretPlaintext $c.Password)}catch{Write-Verbose 'credential redaction'}}}
    $context=@{ State=$null;RunId=$RunId;TargetName=$plan.TargetName;RunDirectory=$runDir;Seq=0;Redactions=$redactions;Echo=(-not $Quiet) }
    $runtimeValues=@{ RunId=$RunId; TargetName=$plan.TargetName }
    $remoteLock=$false
    $vaultLock=$null
    try {
        $statePath=Join-Path $runDir 'state.json'
        if($Resume){
            $state=Read-PASJournal $statePath
            if(-not $state){throw 'Cannot resume: run state not found'}
            if([int](Get-PASValue $state 'schemaVersion' 0) -ne 1){throw 'Cannot resume: unsupported or corrupt state schema'}
            if($state.runId -ne $RunId -or $state.target -ne $plan.TargetName){throw 'Cannot resume: state does not belong to this run/target'}
            if($state.digest -ne $plan.Digest){throw 'Cannot resume: workflow, scripts or inventory changed since run began'}
            if($state.steps -isnot [System.Collections.IDictionary]){throw 'Cannot resume: corrupt step journal'}
            $context.State=$state
            $eventFile=Join-Path $runDir 'events.jsonl'
            if(Test-Path -LiteralPath $eventFile){$context.Seq=[int]@(Get-Content -LiteralPath $eventFile).Count}
            $state.status='Running'; Save-PASState $context
            Add-PASEvent $context 'RunResumed' '' ("Resuming workflow $($plan.Name)" + $(if($Retry.Count){' with operator-authorised retry of: '+($Retry -join ',')}else{''}))
        }else{
            if(Test-Path -LiteralPath $statePath){throw 'Run already exists. Use -Resume with the same RunId.'}
            $state=@{ schemaVersion=1;runId=$RunId;workflow=$plan.Name;target=$plan.TargetName;digest=$plan.Digest;status='Running';createdUtc=(Get-PASNow);updatedUtc=(Get-PASNow);controller=@{host=[Environment]::MachineName;psVersion=[string]$PSVersionTable.PSVersion;edition=[string]$PSVersionTable.PSEdition;pid=$PID};steps=@{} }
            $context.State=$state
            Save-PASState $context
            Add-PASEvent $context 'RunStarted' '' "Workflow $($plan.Name) started on $($plan.Target.Protocol)/$($plan.Runtime) (PowerShell $($PSVersionTable.PSVersion))"
        }
        $remoteLock=Invoke-PASRemoteLock $plan $Credentials $RunId
        if($remoteLock){Add-PASEvent $context 'TargetLocked' '' 'target lock acquired'}
        $outputs=@{}
        foreach($k in @($state.steps.Keys)){ $d=Get-PASValue $state.steps[$k] 'data' $null; if($null -ne $d){$outputs[$k]=$d} }
        foreach($step in $plan.Steps){
            $id=[string]$step.Id
            $kind=[string](Get-PASValue $step 'Kind' 'Script')
            $mode=[string](Get-PASValue $step 'Mode' 'Direct')
            $scope=[string](Get-PASValue $step 'Scope' 'Target')
            $durableBash=($plan.Target.Protocol -eq 'SSH' -and $plan.Target.Runtime -eq 'Bash' -and $scope -ne 'Controller')
            $contract=[string](Get-PASValue $step 'OutputContract' 'Object')
            $timeout=[int](Get-PASValue $step 'TimeoutSeconds' 1800)
            $current=Get-PASValue $state.steps $id
            $inputs=@{}
            $resolved=Resolve-PASValue (Get-PASValue $step 'Inputs' @{}) $plan.Inventory $Secrets $outputs $runtimeValues
            if($resolved){$inputs=[hashtable]$resolved}
            if($scope -eq 'Controller'){
                $inputs['PAExecCredentials']=$Credentials
                $inputs['PAExecRunId']=$RunId
            }
            $requiresVault=([bool](Get-PASValue $step 'RequiresVaultSession' $false) -or [bool](Get-PASValue $step 'VerifyRequiresVaultSession' $false))
            $context.VaultLocked=$false
            if($requiresVault){
                # Nothing has been dispatched yet, so a missing address or a busy Vault is a plain failure.
                if(-not $VaultAddress){throw "Step '$id' opens a Vault session and needs -VaultAddress"}
                $vaultLock=Enter-PASVaultLock -Address $VaultAddress
                $context.VaultLocked=$true
                Add-PASEvent $context 'VaultLockAcquired' $id "Vault lock held for this step ($VaultAddress)"
            }
            $retrying=($Retry -contains $id)
            if($retrying -and $current -and (Get-PASValue $current 'check' $null)){
                $priorCheck=$current.check
                if($priorCheck -isnot [Collections.IDictionary] -or (Get-PASValue $priorCheck 'consumed' $null) -isnot [bool] -or -not $priorCheck.consumed -or $priorCheck.status -ne 'Completed'){
                    throw 'PAExecUnknown: an unconsumed durable verifier must be reconciled with ordinary Resume before retrying its action'
                }
            }
            $reconciled=$false
            # A step whose action completed but whose later revalidation failed (target drift) is only ever
            # revalidated again, read-only; it never needs re-execution unless the operator asks for -Retry.
            $revalidate=($current -and ($current.status -in @('Succeeded','Skipped') -or [bool](Get-PASValue $current 'revalidationFailed' $false)))
            if($revalidate -and -not $retrying){
                try {
                    $how=Test-PASStepCompleted $plan $step $Credentials $inputs $scope $kind $StateRoot $RunId $Secrets $outputs $runtimeValues $current $context
                    $needsRebootData=@($plan.Steps | Where-Object { [string](Get-PASValue $_ 'RebootRequiredFrom' '') -eq $id }).Count -gt 0
                    if($needsRebootData -and -not $outputs.ContainsKey($id)){
                        if($mode -ne 'Detached' -or -not (Get-PASValue $current 'attemptId' '')){throw 'PAExecUnknown: missing durable reboot evidence'}
                        $completed=Get-PASDetachedStatus $plan.Target $Credentials ([string]$current.attemptId)
                        $safeData=Get-PASCompletedAttemptData $completed ([string]$current.attemptId) $redactions -RequireRebootEvidence
                        $outputs[$id]=$safeData;$current.data=$safeData
                        Save-PASState $context
                        Add-PASEvent $context 'TaskDataReconciled' $id 'Recovered allowlisted data from the same completed remote attempt'
                    }
                } catch {
                    $current.status='Unknown';$current.revalidationFailed=$true;$current.message=Protect-PASText ([string]$_.Exception.Message) $redactions;Save-PASState $context
                    Add-PASEvent $context 'TaskRevalidationFailed' $id ([string]$_.Exception.Message) 'Error'
                    throw "Unknown: $id :: $($_.Exception.Message)"
                }
                if([bool](Get-PASValue $current 'revalidationFailed' $false)){ $current.status='Succeeded'; $current.revalidationFailed=$false; Save-PASState $context }
                Save-PASState $context
                Add-PASEvent $context 'TaskRevalidated' $id $how
                if($step.Contains('Publishes')){foreach($milestone in @($step.Publishes)){Write-PASMilestone $StateRoot $RunId $milestone $plan.TargetName $id}}
                if($vaultLock){
                    Wait-PASVaultSessionEnd $plan.Target $Credentials $current $mode
                    Exit-PASVaultLock $vaultLock
                    $vaultLock=$null
                }
                continue
            }
            if($current -and -not $retrying){
                $status=[string]$current.status
                if($status -eq 'Pending'){
                    Add-PASEvent $context 'TaskRestarted' $id 'previous attempt never dispatched (read-only probe phase only); starting a new attempt'
                } elseif([bool](Get-PASValue $current 'actionAcknowledged' $false) -and (Get-PASValue $step 'Verify' '')){
                    $reconciled=$true
                    Add-PASEvent $context 'TaskReconciling' $id 'Action acknowledged; reconciling or repeating only its independent verification'
                } elseif($kind -in @('Wait','Verify') -or ($kind -in @('Transfer','Relay') -and $status -ne 'Failed')){
                    Add-PASEvent $context 'TaskRestarted' $id "idempotent $kind step was $status; repeating with content verification"
                } elseif($kind -eq 'Reboot' -and $status -in @('Dispatched','Running','Unknown') -and (Get-PASValue $current 'bootBefore' '')){
                    try {
                        $boot=Invoke-PASReboot -Target $plan.Target -Credentials $Credentials -TimeoutSeconds $timeout -Context $context -TaskId $id -BootBefore ([string]$current.bootBefore) -AlreadyRequested
                        $current.bootAfter=$boot;$current.status='Verifying';Save-PASState $context
                        $reconciled=$true
                    } catch { throw "Unknown: $id :: reboot not reconciled: $($_.Exception.Message)" }
                } elseif(($mode -eq 'Detached' -or $durableBash) -and (Get-PASValue $current 'attemptId' '') -and $status -in @('Dispatched','Running','Unknown','Verifying')){
                    Add-PASEvent $context 'TaskReconciling' $id "reconciling remote attempt $($current.attemptId)"
                    try { $remote=Wait-PASDetached $plan.Target $Credentials ([string]$current.attemptId) $timeout $context $id -AllowStart }
                    catch { $current.status='Unknown';Save-PASState $context; throw "Unknown: $id :: $($_.Exception.Message)" }
                    if($remote.state -eq 'Succeeded'){
                        $current.status='Verifying';$current.remote=Select-PASRemoteEvidence $remote $redactions
                        $current.message=Protect-PASText ([string](Get-PASValue $remote 'message' '')) $redactions
                        $recoveredData=Get-PASValue $remote 'data' $null
                        if($null -ne $recoveredData){$safeData=Select-PASSafeData $recoveredData $redactions;$outputs[$id]=$safeData;$current.data=$safeData}
                        $recoveredChanged=Get-PASValue $remote 'changed' $null
                        if($recoveredChanged -is [bool]){$current.changed=$recoveredChanged}
                        Save-PASState $context
                        $reconciled=$true
                    } elseif($remote.state -eq 'Failed'){
                        $current.status='Failed';$current.message=Protect-PASText ([string](Get-PASValue $remote 'message' '')) $redactions;$current.endedUtc=Get-PASNow;Save-PASState $context
                        Add-PASEvent $context 'TaskFailed' $id "remote attempt failed: $(Get-PASValue $remote 'message' '')" 'Error'
                        throw "Failed: $id :: $(Get-PASValue $remote 'message' '')"
                    } else {
                        $current.status='Unknown';$current.message="remote attempt $($remote.state)";Save-PASState $context
                        Add-PASEvent $context 'TaskUnknown' $id "remote attempt $($current.attemptId) is $($remote.state); outcome cannot be established" 'Error'
                        throw "Unknown: $id :: remote attempt $($remote.state); preserve evidence and reconcile target state before any new action"
                    }
                } elseif($status -eq 'Verifying' -and (Get-PASValue $step 'Verify' '')){
                    Add-PASEvent $context 'TaskReconciling' $id 'action acknowledged before interruption; repeating read-only verification'
                    $reconciled=$true
                } else {
                    $prefix='Unknown'; if($status -eq 'Failed'){$prefix='Failed'}
                    throw "${prefix}: $id :: step was previously $status; inspect the target, then restore or rerun with -Resume -Retry $id"
                }
            }
            if($retrying -and $current){
                Add-PASEvent $context 'TaskRetryAuthorised' $id "operator authorised re-execution (previous status $($current.status))" 'Warning'
                $current.previousAttempts=@(@(Get-PASValue $current 'previousAttempts' @())+@([string]$current.attemptId))
            }
            $dispatched=$false
            $acknowledged=$false
            if(-not $reconciled){
                foreach($dependency in @(Get-PASValue $step 'DependsOn' @())){[void](Wait-PASMilestone $StateRoot $RunId ([string]$dependency) $timeout $plan.TargetName $context $id)}
                $attempt=[guid]::NewGuid().ToString('N')
                $previous=@(); if($current){$previous=@(Get-PASValue $current 'previousAttempts' @())}
                $current=@{status='Pending'; attemptId=$attempt; startedUtc=Get-PASNow; endedUtc=$null; verified=$false; previousAttempts=$previous}
                $state.steps[$id]=$current;Save-PASState $context
                Add-PASEvent $context 'TaskStarted' $id "$kind/$mode attempt $attempt"
            } else { $attempt=[string]$current.attemptId; $dispatched=$true; $acknowledged=$true }
            try {
                if(-not $reconciled){
                    $probe=[string](Get-PASValue $step 'Probe' '')
                    if($probe){
                        $pstatus=Get-PASCheck $plan $Credentials $probe $inputs 'Satisfied' $scope
                        if($pstatus.Passed){
                            $current.status='Skipped';$current.verified=$true
                            Add-PASEvent $context 'TaskSkipped' $id ('read-only probe confirmed desired state: '+$pstatus.Message)
                        }
                    }
                }
                if($current.status -ne 'Skipped'){
                    if(-not $reconciled){
                        $current.status='Dispatched';Save-PASState $context;$dispatched=($kind -ne 'Wait')
                        if($kind -eq 'Script'){
                            $scriptFile=Assert-PASProjectPath $plan.Root ([string]$step.Script)
                            if($mode -eq 'Detached'){
                                $recovery=[string](Get-PASValue $step 'RecoveryScript' '')
                                if($recovery){$recovery=Assert-PASProjectPath $plan.Root $recovery}
                                try { [void](Initialize-PASDetached $plan.Target $Credentials $scriptFile $inputs $attempt $recovery $timeout $contract -TaskPrincipalCredentialRef ([string](Get-PASValue $step 'TaskPrincipalCredentialRef' ''))) }
                                catch { throw "PAExecUnknown: detached staging/launch interrupted: $($_.Exception.Message)" }
                                $current.status='Running';Save-PASState $context
                                Add-PASEvent $context 'DetachedLaunched' $id $(if($plan.Target.Runtime -eq 'Bash'){"systemd attempt $attempt launched"}elseif(Get-PASValue $step 'TaskPrincipalCredentialRef' ''){"scheduled task PAExec-$attempt launched with the configured domain identity"}else{"scheduled task PAExec-$attempt launched as SYSTEM"})
                                $result=Wait-PASDetached $plan.Target $Credentials $attempt $timeout $context $id
                                $current.remote=Select-PASRemoteEvidence $result $redactions
                                if($result.state -in @('Missing','NotStarted')){throw "PAExecUnknown: launched attempt disappeared from target ($($result.state)); possible target drift or rollback"}
                                if($result.state -eq 'Interrupted'){throw "PAExecUnknown: detached attempt interrupted (process ended without final status)"}
                                $acknowledged=$true
                                if($result.state -ne 'Succeeded'){throw "Detached script failed: $(Get-PASValue $result 'message' '')"}
                                $current.message=Protect-PASText ([string](Get-PASValue $result 'message' '')) $redactions
                                if($null -ne (Get-PASValue $result 'changed' $null)){$current.changed=[bool](Get-PASValue $result 'changed' $false)}
                                $d=Get-PASValue $result 'data' $null; if($null -ne $d){$safeData=Select-PASSafeData $d $redactions;$outputs[$id]=$safeData;$current.data=$safeData}
                            }else{
                                $execTarget=$plan.Target
                                if($scope -eq 'Controller'){$execTarget=@{Protocol='Local';Runtime='PowerShell'}}
                                $result=Invoke-PASAdapterScript -Target $execTarget -Credentials $Credentials -ScriptPath $scriptFile -Parameters $inputs -Contract $contract -TimeoutSeconds $timeout -AttemptId $attempt
                                $acknowledged=$true
                                if($result.Output){Add-PASEvent $context 'TaskOutput' $id (Limit-PASText ([string]$result.Output) 2000)}
                                if(-not $result.Ok){throw "Task script failed: $($result.Error)"}
                                $terminal=$result.Terminal
                                $current.message=Protect-PASText ([string](Get-PASValue $terminal 'Message' '')) $redactions
                                if($null -ne (Get-PASValue $terminal 'Changed')){$current.changed=[bool](Get-PASValue $terminal 'Changed')}
                                $d=Get-PASValue $terminal 'Data' $null; if($null -ne $d){$safeData=Select-PASSafeData $d $redactions;$outputs[$id]=$safeData;$current.data=$safeData}
                            }
                        }elseif($kind -eq 'Relay'){
                            $from=[string]$step.SourceTarget
                            $src=[string](Resolve-PASValue $step.SourceDir $plan.Inventory $Secrets $outputs $runtimeValues)
                            $dst=[string](Resolve-PASValue $step.DestinationDir $plan.Inventory $Secrets $outputs $runtimeValues)
                            $sourceTarget=$plan.Inventory.Targets[$from]
                            if(-not $sourceTarget.Contains('Runtime')){$sourceTarget['Runtime']='WindowsPowerShell'}
                            $current.changed=Copy-PASRelayFiles $sourceTarget $plan.Target $Credentials $src $dst @($step.Files)
                            $acknowledged=$true
                        }elseif($kind -eq 'Transfer'){
                            $source=[string](Resolve-PASValue $step.Source $plan.Inventory $Secrets $outputs $runtimeValues)
                            $dest=[string](Resolve-PASValue $step.Destination $plan.Inventory $Secrets $outputs $runtimeValues)
                            $direction=[string](Get-PASValue $step 'Direction' 'Upload')
                            if($direction -eq 'Upload'){
                                if(-not [IO.Path]::IsPathRooted($source)){$source=Get-PASPath $plan.Root $source}
                                if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Source missing: $source"}
                                $want=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToUpperInvariant()
                                $frozen=Get-Variable -Name PASeasyFrozenMedia -Scope Script -ErrorAction SilentlyContinue
                                if($frozen -and $null -ne $frozen.Value){
                                    $fullSource=[IO.Path]::GetFullPath($source)
                                    if(-not $frozen.Value.ContainsKey($fullSource) -or $frozen.Value[$fullSource] -ne $want){throw 'Frozen media changed or source was not approved in the run plan'}
                                }
                                $guard=[string](Get-PASValue $step 'BeforeTransfer' '')
                                if($guard){
                                    $prepared=Get-PASCheck $plan $Credentials $guard $inputs 'Passed' 'Target'
                                    if(-not $prepared.Passed){throw 'Upload destination safety check failed'}
                                }
                                if($plan.Target.Protocol -eq 'WinRM' -and (Test-PASWindows)){
                                    $session=Get-PASConnection $plan.Target $Credentials
                                    $ref=[string](Get-PASValue $plan.Target 'CredentialRef' '')
                                    $user=if($ref -and $Credentials.ContainsKey($ref)){[string]$Credentials[$ref].UserName}else{''}
                                    [void](Invoke-Command -Session $session -ScriptBlock (Get-PASWindowsFilePreparation) -ArgumentList $dest,$user -ErrorAction Stop)
                                }
                                $have=Get-PASRemoteFileHash $plan.Target $Credentials $dest
                                if($have -eq $want){
                                    $current.changed=$false
                                    Add-PASEvent $context 'TransferSkipped' $id "destination already has SHA-256 $want"
                                } else {
                                    # Parent computed textually: the controller OS may not share the target's path separator.
                                    $parent=$dest -replace '[\\/][^\\/]*$',''
                                    if(-not $parent){throw "Transfer destination must be an absolute file path: $dest"}
                                    if($plan.Target.Protocol -eq 'Local'){
                                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                                    } elseif($plan.Target.Runtime -eq 'Bash'){
                                        $mk=Invoke-PASRawSSH $plan.Target ("mkdir -p -- '" + $parent.Replace("'","'\''") + "'")
                                        if($mk.ExitCode -ne 0){throw "Cannot create remote directory ($($mk.ExitCode)): $($mk.Output)"}
                                    } else {
                                        [void](Invoke-PASAdapterCommand $plan.Target $Credentials ("New-Item -ItemType Directory -Path "+(ConvertTo-PASSingleQuoted $parent)+" -Force | Out-Null"))
                                    }
                                    $size=(Get-Item -LiteralPath $source).Length
                                    Add-PASEvent $context 'TransferStarted' $id ("uploading {0:N1} MiB" -f ($size/1MB))
                                    $sw=[Diagnostics.Stopwatch]::StartNew()
                                    Copy-PASAdapterFile $plan.Target $Credentials $source $dest
                                    $have=Get-PASRemoteFileHash $plan.Target $Credentials $dest
                                    if($have -ne $want){throw "SHA256 mismatch after upload (expected $want, remote '$have')"}
                                    $current.changed=$true
                                    Add-PASEvent $context 'TransferVerified' $id ("SHA-256 $want verified on target after {0:N0}s" -f $sw.Elapsed.TotalSeconds)
                                }
                                $current.sha256=$want
                            }else{
                                Copy-PASAdapterFile $plan.Target $Credentials $source $dest -Download
                                $current.sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
                            }
                            $acknowledged=$true
                        }elseif($kind -eq 'Reboot'){
                            if(Test-PASRebootRequired $step $outputs){
                                $nowBoot=Get-PASBootIdentifier $plan.Target $Credentials
                                $priorBoot=Get-PASPriorAttemptBoot $step $state
                                if($priorBoot -and $nowBoot -ne $priorBoot){
                                    $current.bootBefore=$priorBoot;$current.bootAfter=$nowBoot
                                    Add-PASEvent $context 'RebootAlreadyObserved' $id 'Boot changed after the same completed durable attempt; no second reboot requested'
                                    Save-PASState $context
                                }else{
                                    $current.bootBefore=$nowBoot
                                    Save-PASState $context
                                    $current.bootAfter=Invoke-PASReboot -Target $plan.Target -Credentials $Credentials -TimeoutSeconds $timeout -Context $context -TaskId $id -BootBefore ([string]$current.bootBefore)
                                }
                            }else{
                                $current.rebootSkipped=$true
                                $current.message='Vendor checkpoint explicitly reports no reboot required'
                                Add-PASEvent $context 'RebootNotRequired' $id $current.message
                            }
                            $acknowledged=$true
                        }elseif($kind -eq 'Wait'){
                            [void](Wait-PASMilestone $StateRoot $RunId ([string]$step.Milestone) $timeout $plan.TargetName $context $id)
                            $acknowledged=$true
                        }elseif($kind -eq 'Verify'){
                            # No action body exists. A failed check can be repeated on
                            # public Resume without replaying an installation attempt.
                            $acknowledged=$true
                        }
                    }
                    $current.status='Verifying';Save-PASState $context
                    if($acknowledged){$current.actionAcknowledged=$true;Save-PASState $context}
                    $verify=[string](Get-PASValue $step 'Verify' '')
                    if($verify){
                        $check=Get-PASStepCheck -Plan $plan -Step $step -Credentials $Credentials -Inputs $inputs -Current $current -Context $context -Script $verify -Scope $scope -TimeoutSeconds $timeout
                        Complete-PASCheckGeneration $current
                        if(-not $check.Passed){throw "Verification failed for '$id': $($check.Message)"}
                        $current.verified=$true
                        $current.evidence=@($check.Evidence | ForEach-Object { Protect-PASText ([string]$_) $redactions })
                        Add-PASEvent $context 'TaskVerified' $id ((@($check.Evidence) -join '; ') + $(if($check.Message){' :: '+$check.Message}else{''}))
                    }
                    $current.status='Succeeded'
                }
                $current.endedUtc=Get-PASNow
                Save-PASState $context
                Add-PASEvent $context 'TaskCompleted' $id ([string]$current.status + $(if(Get-PASValue $current 'message' ''){': '+(Get-PASValue $current 'message' '')}else{''}))
                if($step.Contains('Publishes')){foreach($m in @($step.Publishes)){Write-PASMilestone $StateRoot $RunId ([string]$m) $plan.TargetName $id; Add-PASEvent $context 'MilestonePublished' $id ([string]$m)}}
                if(($mode -eq 'Detached' -or $durableBash) -and $current.status -eq 'Succeeded'){try{Finish-PASDetached $plan.Target $Credentials $attempt}catch{Add-PASEvent $context 'CleanupWarning' $id ('detached task cleanup failed: '+$_.Exception.Message) 'Warning'}}
                if($vaultLock){
                    Wait-PASVaultSessionEnd $plan.Target $Credentials $current $mode
                    Exit-PASVaultLock $vaultLock
                    $vaultLock=$null
                }
            }catch{
                $message=[string]$_.Exception.Message
                $uncertain=($message.StartsWith('PAExecUnknown:') -or ($dispatched -and -not $acknowledged -and $plan.Target.Protocol -ne 'Local' -and $scope -ne 'Controller'))
                if($uncertain){$current.status='Unknown'}else{$current.status='Failed'}
                $current.message=Protect-PASText $message $redactions
                $current.endedUtc=Get-PASNow
                Save-PASState $context
                Add-PASEvent $context $(if($uncertain){'TaskUnknown'}else{'TaskFailed'}) $id $message 'Error'
                throw "$($current.status): $id :: $message"
            }
        }
        # Boot-time recovery registrations are removed only once the entire workflow is verified.
        Clear-PASRecoveryTasks $plan $Credentials $state.steps
        $state.status='Succeeded';Save-PASState $context
        Add-PASEvent $context 'RunCompleted' '' 'Workflow finished and verified'
        return [pscustomobject]@{RunId=$RunId;Target=$plan.TargetName;Status='Succeeded';Steps=@($plan.Steps | ForEach-Object { [string]$_.Id })}
    }catch{
        $text=[string]$_.Exception.Message
        if($context.State -and $context.State.status -ne 'Succeeded'){
            if($text -match '^PAExecLocked:'){ $context.State.status='Blocked' }
            elseif($text -match '^(Unknown:|PAExecUnknown:)'){ $context.State.status='Unknown' }
            else { $context.State.status='Failed' }
            $context.State.lastError=Protect-PASText $text $redactions
            try { Save-PASState $context; Add-PASEvent $context 'RunStopped' '' "$($context.State.status): $text" 'Error' } catch { Write-Verbose 'state save failed' }
        }
        throw
    }finally{
        try{
            # A failed step ends here: the Vault lock is never kept after a failure.
            Exit-PASVaultLock $vaultLock
        }finally{
            if($remoteLock -and $context.State -and $context.State.status -eq 'Succeeded'){
                try{[void](Invoke-PASRemoteLock $plan $Credentials $RunId -Release)}catch{Write-Verbose 'lock release failed'}
            }
            try{Clear-PASConnections}finally{$lock.Dispose()}
        }
    }
}

function Test-PASRebootRequired {
    param($Step,[hashtable]$Outputs)
    $source=[string](Get-PASValue $Step 'RebootRequiredFrom' '')
    if(-not $source){return $true}
    if(-not $Outputs.ContainsKey($source)){throw 'PAExecUnknown: missing vendor reboot checkpoint'}
    $record=$Outputs[$source]
    $required=Get-PASValue $record 'RebootRequired' $null
    if($required -isnot [bool]){throw 'PAExecUnknown: vendor reboot checkpoint must be Boolean'}
    return $required
}

function Get-PASCompletedAttemptData {
    param($Remote,[string]$AttemptId,[string[]]$Redactions=@(),[switch]$RequireRebootEvidence)
    if((Get-PASValue $Remote 'state' '') -ne 'Succeeded' -or (Get-PASValue $Remote 'attemptId' '') -ne $AttemptId){throw 'PAExecUnknown: remote result does not prove the same completed attempt'}
    $data=Get-PASValue $Remote 'data' $null
    if($null -eq $data){throw 'PAExecUnknown: completed remote attempt has no data checkpoint'}
    $safe=Select-PASSafeData $data $Redactions
    if($RequireRebootEvidence -and (Get-PASValue $safe 'RebootRequired' $null) -isnot [bool]){throw 'PAExecUnknown: completed attempt has no Boolean reboot evidence'}
    return $safe
}

function Get-PASPriorAttemptBoot {
    param($Step,$State)
    $source=[string](Get-PASValue $Step 'RebootFromAttempt' '')
    if(-not $source){return ''}
    $prior=Get-PASValue $State.steps $source $null
    $remote=Get-PASValue $prior 'remote' $null
    $attempt=[string](Get-PASValue $prior 'attemptId' '')
    $boot=[string](Get-PASValue $remote 'bootUtc' '')
    if((Get-PASValue $prior 'status' '') -ne 'Succeeded' -or -not $attempt -or (Get-PASValue $remote 'attemptId' '') -ne $attempt -or (Get-PASValue $remote 'state' '') -ne 'Succeeded' -or -not $boot){throw 'PAExecUnknown: reboot predecessor lacks the same completed attempt boot evidence'}
    return $boot
}
