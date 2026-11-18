function Select-PSDeclaredInputs {
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
function Get-PSCheck {
    # Read-only check. A check that cannot be evaluated raises PAExecUnknown; a negative result returns Passed=$false.
    param($Plan,[hashtable]$Credentials,[string]$Script,[hashtable]$Inputs,[string]$Property,[string]$Scope='Target',[int]$TimeoutSeconds=900)
    $checkTarget=$Plan.Target
    if($Scope -eq 'Controller'){$checkTarget=@{Protocol='Local';Runtime='PowerShell'}}
    $path=Assert-PSProjectPath $Plan.Root $Script
    $Inputs=Select-PSDeclaredInputs $path $Inputs
    try { $check=Invoke-PSAdapterScript -Target $checkTarget -Credentials $Credentials -ScriptPath $path -Parameters $Inputs -Contract 'Object' -TimeoutSeconds $TimeoutSeconds }
    catch { throw "PAExecUnknown: check '$Script' could not be evaluated: $($_.Exception.Message)" }
    if(-not $check.Ok){throw "PAExecUnknown: check '$Script' did not complete: $($check.Error)"}
    $terminal=$check.Terminal
    $passed=Get-PSObjectValue $terminal $Property $null
    if($passed -isnot [bool]){throw "PAExecUnknown: check '$Script' must return boolean $Property"}
    return [pscustomobject]@{ Passed=[bool]$passed; Message=[string](Get-PSObjectValue $terminal 'Message' ''); Evidence=@(Get-PSObjectValue $terminal 'Evidence' @()) }
}
function Wait-PSMilestone {
    param([string]$StateRoot,[string]$RunId,[string]$Milestone,[int]$TimeoutSeconds=1200,[string]$Waiter='',[hashtable]$Context=$null,[string]$TaskId='')
    if($Milestone -notmatch '^[a-zA-Z0-9_.-]+$'){throw 'Invalid milestone name'}
    $runRoot=Join-Path $StateRoot $RunId
    $path=Join-Path (Join-Path $runRoot 'milestones') ($Milestone+'.json')
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $announced=$false
    while([DateTime]::UtcNow -lt $deadline){
        $marker=Read-PSJson $path
        if($marker -and $marker.verified -eq $true -and $marker.runId -eq $RunId){return $marker}
        if(-not $announced -and $Context){ Add-PSEvent $Context 'WaitingForMilestone' $TaskId "waiting for milestone '$Milestone'"; $announced=$true }
        # Stop waiting early when every other target of this run has terminated without publishing.
        $others=@(Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'milestones' -and $_.Name -ne $Waiter })
        if($others.Count -gt 0){
            $active=$false
            foreach($o in $others){
                $st=$null; try{$st=Read-PSJson (Join-Path $o.FullName 'state.json')}catch{$st=$null}
                if(-not $st -or $st.status -eq 'Running'){$active=$true}
            }
            if(-not $active){
                Start-Sleep -Seconds 2
                $marker=Read-PSJson $path
                if($marker -and $marker.verified -eq $true -and $marker.runId -eq $RunId){return $marker}
                throw "Milestone '$Milestone' can no longer be published: all other targets of run $RunId have stopped"
            }
        }
        Start-Sleep -Seconds 3
    }
    throw "PAExecUnknown: Milestone '$Milestone' was not verified before timeout"
}
function Write-PSMilestone {
    param([string]$StateRoot,[string]$RunId,[string]$Name,[string]$Target,[string]$TaskId)
    if($Name -notmatch '^[a-zA-Z0-9_.-]+$'){throw 'Invalid milestone name'}
    $path=Join-Path (Join-Path (Join-Path $StateRoot $RunId) 'milestones') ($Name+'.json')
    Write-PSJsonAtomic $path ([ordered]@{schemaVersion=1;runId=$RunId;target=$Target;taskId=$TaskId;verified=$true;utc=(Get-PSNow)})
}
function Save-PSState {
    param([hashtable]$Context)
    $Context.State.updatedUtc=Get-PSNow
    Write-PSJsonAtomic (Join-Path $Context.RunDirectory 'state.json') $Context.State
}
function Invoke-PSRemoteLock {
    param($Plan,[hashtable]$Credentials,[string]$RunId,[switch]$Release)
    $protocol=[string]$Plan.Target.Protocol
    if($protocol -eq 'Local'){return $false}
    $targetName=[string](Get-PSObjectValue $Plan.Target 'LockKey' $Plan.TargetName)
    if($targetName -notmatch '^[A-Za-z0-9_.-]{1,64}$'){throw 'Invalid canonical host lock key'}
    if($Plan.Target.Runtime -eq 'Bash'){
        if($Release){$cmd='d=~/.paeasyinstall/locks/{0}; if [ "$(cat "$d/owner" 2>/dev/null)" = "{1}" ]; then rm -rf "$d"; fi; echo released' -f $targetName,$RunId}
        else{$cmd='mkdir -p ~/.paeasyinstall/locks && d=~/.paeasyinstall/locks/{0}; if mkdir "$d" 2>/dev/null; then echo {1} > "$d/owner"; echo acquired; elif [ "$(cat "$d/owner" 2>/dev/null)" = "{1}" ]; then echo acquired; else echo "locked:$(cat "$d/owner" 2>/dev/null)"; fi' -f $targetName,$RunId}
        $r=Invoke-PSRawSSH $Plan.Target $cmd
        if($r.ExitCode -ne 0){throw "Remote lock operation failed ($($r.ExitCode)): $($r.Output)"}
        if(-not $Release -and $r.Output -notmatch 'acquired'){throw "PAExecLocked: target '$targetName' is locked by another run ($($r.Output.Trim())); inspect before any takeover"}
        return $true
    }
    $root=[string](Get-PSObjectValue $Plan.Target 'StageRoot' 'C:\ProgramData\PAExec')
    $session=Get-PSConnection $Plan.Target $Credentials
    $reference=[string](Get-PSObjectValue $Plan.Target 'CredentialRef' '')
    $user=if($reference -and $Credentials.ContainsKey($reference)){[string]$Credentials[$reference].UserName}else{''}
    $res=Invoke-Command -Session $session -ScriptBlock (Get-PSWindowsStagePreparation) -ArgumentList $root,$targetName,$RunId,([bool]$Release),$user -ErrorAction Stop
    $message=[string]$res.Message
    if(-not $Release -and $message -ne 'acquired'){throw "PAExecLocked: target '$targetName' is locked by another run ($message); inspect the remote lock before any takeover"}
    return $true
}
function Test-PAExecStepCompleted {
    # Read-only revalidation of a checkpointed step before it is trusted on resume.
    param($Plan,$Step,[hashtable]$Credentials,[hashtable]$Inputs,[string]$Scope,[string]$Kind,[string]$StateRoot,[string]$RunId,[hashtable]$Secrets,[hashtable]$Outputs,[hashtable]$Runtime,$Current,[hashtable]$Context)
    $verify=[string](Get-PSObjectValue $Step 'Verify' '')
    $probe=[string](Get-PSObjectValue $Step 'Probe' '')
    if($verify -or $probe){
        $checkName=$verify;$property='Passed'
        if(-not $verify){$checkName=$probe;$property='Satisfied'}
        $check=Get-PAExecStepCheck -Plan $Plan -Step $Step -Credentials $Credentials -Inputs $Inputs -Current $Current -Context $Context -Script $checkName -Property $property -Scope $Scope -Purpose Revalidation -TimeoutSeconds ([int](Get-PSObjectValue $Step 'TimeoutSeconds' 1800))
        Complete-PAExecCheckGeneration $Current
        if(-not $check.Passed){throw "PAExecUnknown: previously completed step failed read-only revalidation: $($check.Message)"}
        return 'verified by '+$checkName
    }
    if($Kind -eq 'Wait'){[void](Wait-PSMilestone $StateRoot $RunId ([string]$Step.Milestone) 5 $Plan.TargetName);return 'milestone present'}
    if($Kind -eq 'Reboot'){
        if([bool](Get-PSObjectValue $Current 'rebootSkipped' $false)){
            if(Test-PAExecRebootRequired $Step $Outputs){throw 'PAExecUnknown: skipped reboot contradicts recorded vendor result'}
            return 'vendor result did not require reboot'
        }
        $before=[string](Get-PSObjectValue $Current 'bootBefore' '')
        $after=[string](Get-PSObjectValue $Current 'bootAfter' '')
        if(-not $before -or -not $after -or $before -eq $after){throw 'PAExecUnknown: completed reboot has no changed boot identifier'}
        return 'reboot evidence recorded (boot identifier changed)'
    }
    if($Kind -eq 'Transfer'){
        $guard=[string](Get-PSObjectValue $Step 'BeforeTransfer' '')
        if($guard){
            $guardInputs=$Inputs.Clone();$guardInputs.ValidateOnly=$true
            $prepared=Get-PSCheck $Plan $Credentials $guard $guardInputs 'Passed' 'Target'
            if(-not $prepared.Passed){throw 'Upload destination safety check failed'}
        }
        $source=[string](Resolve-PSValue $Step.Source $Plan.Inventory $Secrets $Outputs $Runtime)
        $dest=[string](Resolve-PSValue $Step.Destination $Plan.Inventory $Secrets $Outputs $Runtime)
        if((Get-PSObjectValue $Step 'Direction' 'Upload') -eq 'Upload'){
            if(-not [IO.Path]::IsPathRooted($source)){$source=Get-PSPath $Plan.Root $source}
            if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "PAExecUnknown: source missing for completed transfer"}
            if($Plan.Target.Protocol -eq 'WinRM' -and (Test-PSWindows)){
                $session=Get-PSConnection $Plan.Target $Credentials
                $ref=[string](Get-PSObjectValue $Plan.Target 'CredentialRef' '')
                $user=if($ref -and $Credentials.ContainsKey($ref)){[string]$Credentials[$ref].UserName}else{''}
                [void](Invoke-Command -Session $session -ScriptBlock (Get-PSWindowsFilePreparation) -ArgumentList $dest,$user,$true -ErrorAction Stop)
            }
            $remote=Get-PSRemoteFileHash $Plan.Target $Credentials $dest
            if($remote -ne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToUpperInvariant()){throw 'PAExecUnknown: transferred file no longer matches source (target drift)'}
            return 'remote SHA-256 matches source'
        }
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw 'PAExecUnknown: downloaded file missing on controller'}
        return 'downloaded file present'
    }
    throw "PAExecUnknown: cannot trust checkpoint without a read-only Verify or Probe"
}
function Complete-PAExecVaultOperation {
    param([object[]]$Gates,[hashtable]$Target,[hashtable]$Credentials,$StepState,[string]$Mode)
    if(-not @($Gates).Count){return}
    if($StepState.status -eq 'Skipped'){
        if(@($Gates|Where-Object {$_.PreexistingClaim}).Count){throw 'PAExecUnknown: a preexisting Vault claim needs durable attempt reconciliation'}
    }elseif($Mode -eq 'Detached' -and $StepState.attemptId){
        Wait-PSDetachedSessionQuiescence $Target $Credentials ([string]$StepState.attemptId)
    }elseif(-not(Get-PSObjectValue $StepState 'check' $null)){throw 'PAExecUnknown: authenticated operation has no durable worker-exit evidence'}
    $check=Get-PSObjectValue $StepState 'check' $null
    if($check){
        if($check.status -ne 'Completed' -or -not $check.consumed){throw 'PAExecUnknown: durable verifier result has not been consumed'}
        Wait-PSDetachedSessionQuiescence $Target $Credentials ([string]$check.attemptId)
    }
    Exit-PASeasyVaultOperation -Gates $Gates -Succeeded $true
}
function Invoke-PAExecRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkflowPath,
        [Parameter(Mandatory=$true)][string]$InventoryPath,
        [string]$StateRoot=(Join-Path (Get-Location) 'state'),
        [string]$RunId=([guid]::NewGuid().ToString('N')),
        [hashtable]$Credentials=@{},[hashtable]$Secrets=@{},
        [string[]]$Retry=@(),[string]$VaultSessionAddress='',[string]$CoordinationDataRoot='',
        [switch]$Resume,[switch]$PlanOnly,[switch]$Quiet,$BorrowedVaultLease
    )
    $plan=Get-PAExecPlan -WorkflowPath $WorkflowPath -InventoryPath $InventoryPath
    if($PlanOnly){
        return [pscustomobject]@{Name=$plan.Name;Target=$plan.TargetName;Protocol=$plan.Target.Protocol;Runtime=$plan.Runtime;Digest=$plan.Digest;Steps=@($plan.Steps|ForEach-Object { [pscustomobject]@{Id=$_.Id;Kind=(Get-PSObjectValue $_ 'Kind' 'Script');Mode=(Get-PSObjectValue $_ 'Mode' 'Direct');Scope=(Get-PSObjectValue $_ 'Scope' 'Target');Verify=(Get-PSObjectValue $_ 'Verify' '');DependsOn=@(Get-PSObjectValue $_ 'DependsOn' @());Publishes=@(Get-PSObjectValue $_ 'Publishes' @())} });MutatesTargets=$false}
    }
    if($RunId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{5,79}$'){throw 'Invalid RunId'}
    foreach($r in $Retry){ if(-not (@($plan.Steps | ForEach-Object { [string]$_.Id }) -contains $r)){ throw "Retry names unknown step '$r'" } }
    if($Retry.Count -gt 0 -and -not $Resume){throw '-Retry is only meaningful with -Resume'}
    if($VaultSessionAddress -and -not $CoordinationDataRoot){throw 'Authenticated steps require an explicit coordination data root'}
    if($BorrowedVaultLease){
        if($VaultSessionAddress){throw 'A borrowed Vault lease cannot be nested inside per-step admission'}
        Assert-PASeasyBorrowedVaultLease $BorrowedVaultLease $RunId
    }
    $StateRoot=[IO.Path]::GetFullPath($StateRoot)
    $runDir=Join-Path (Join-Path $StateRoot $RunId) $plan.TargetName
    New-Item -Path $runDir -ItemType Directory -Force | Out-Null
    $lock=Get-PSFileLock (Join-Path $runDir '.run.lock')
    $redactions=@();foreach($s in $Secrets.Values){try{$redactions+=,(Get-PSSecretPlaintext $s)}catch{Write-Verbose 'non-string secret'}}
    foreach($c in $Credentials.Values){if($c -is [pscredential]){try{$redactions+=,(Get-PSSecretPlaintext $c.Password)}catch{Write-Verbose 'credential redaction'}}}
    $context=@{ State=$null;RunId=$RunId;TargetName=$plan.TargetName;RunDirectory=$runDir;Seq=0;Redactions=$redactions;Echo=(-not $Quiet) }
    $runtimeValues=@{ RunId=$RunId; TargetName=$plan.TargetName }
    $remoteLock=$false
    $stepOperationGates=@()
    try {
        $statePath=Join-Path $runDir 'state.json'
        if($Resume){
            $state=Read-PSJson $statePath
            if(-not $state){throw 'Cannot resume: run state not found'}
            if([int](Get-PSObjectValue $state 'schemaVersion' 0) -ne 1){throw 'Cannot resume: unsupported or corrupt state schema'}
            if($state.runId -ne $RunId -or $state.target -ne $plan.TargetName){throw 'Cannot resume: state does not belong to this run/target'}
            if($state.digest -ne $plan.Digest){throw 'Cannot resume: workflow, scripts or inventory changed since run began'}
            if($state.steps -isnot [System.Collections.IDictionary]){throw 'Cannot resume: corrupt step journal'}
            $context.State=$state
            $eventFile=Join-Path $runDir 'events.jsonl'
            if(Test-Path -LiteralPath $eventFile){$context.Seq=[int]@(Get-Content -LiteralPath $eventFile).Count}
            $state.status='Running'; Save-PSState $context
            Add-PSEvent $context 'RunResumed' '' ("Resuming workflow $($plan.Name)" + $(if($Retry.Count){' with operator-authorised retry of: '+($Retry -join ',')}else{''}))
        }else{
            if(Test-Path -LiteralPath $statePath){throw 'Run already exists. Use -Resume with the same RunId.'}
            $state=@{ schemaVersion=1;runId=$RunId;workflow=$plan.Name;target=$plan.TargetName;digest=$plan.Digest;status='Running';createdUtc=(Get-PSNow);updatedUtc=(Get-PSNow);controller=@{host=[Environment]::MachineName;psVersion=[string]$PSVersionTable.PSVersion;edition=[string]$PSVersionTable.PSEdition;pid=$PID};steps=@{} }
            $context.State=$state
            Save-PSState $context
            Add-PSEvent $context 'RunStarted' '' "Workflow $($plan.Name) started on $($plan.Target.Protocol)/$($plan.Runtime) (PowerShell $($PSVersionTable.PSVersion))"
        }
        $remoteLock=Invoke-PSRemoteLock $plan $Credentials $RunId
        if($remoteLock){Add-PSEvent $context 'TargetLocked' '' 'remote target lease acquired'}
        $outputs=@{}
        foreach($k in @($state.steps.Keys)){ $d=Get-PSObjectValue $state.steps[$k] 'data' $null; if($null -ne $d){$outputs[$k]=$d} }
        foreach($step in $plan.Steps){
            $id=[string]$step.Id
            $kind=[string](Get-PSObjectValue $step 'Kind' 'Script')
            $mode=[string](Get-PSObjectValue $step 'Mode' 'Direct')
            $scope=[string](Get-PSObjectValue $step 'Scope' 'Target')
            $durableBash=($plan.Target.Protocol -eq 'SSH' -and $plan.Target.Runtime -eq 'Bash' -and $scope -ne 'Controller')
            $contract=[string](Get-PSObjectValue $step 'OutputContract' 'Object')
            $timeout=[int](Get-PSObjectValue $step 'TimeoutSeconds' 1800)
            $current=Get-PSObjectValue $state.steps $id
            $inputs=@{}
            $resolved=Resolve-PSValue (Get-PSObjectValue $step 'Inputs' @{}) $plan.Inventory $Secrets $outputs $runtimeValues
            if($resolved){$inputs=[hashtable]$resolved}
            if($scope -eq 'Controller'){
                $inputs['PAExecCredentials']=$Credentials
                $inputs['PAExecRunId']=$RunId
            }
            if(@($stepOperationGates).Count){throw 'Previous Vault operation was not reconciled'}
            $requiresVault=([bool](Get-PSObjectValue $step 'RequiresVaultSession' $false) -or [bool](Get-PSObjectValue $step 'VerifyRequiresVaultSession' $false))
            $context.VaultAdmitted=$false
            if($requiresVault){
                if($BorrowedVaultLease){Assert-PASeasyBorrowedVaultLease $BorrowedVaultLease $RunId}
                elseif($VaultSessionAddress){$stepOperationGates=@(Enter-PASeasyVaultOperation -Address $VaultSessionAddress -DataRoot $CoordinationDataRoot -RunId $RunId)}
                else{throw 'PAExecUnknown: authenticated step requires an admitted Vault lease'}
                $context.VaultAdmitted=$true
                Add-PSEvent $context 'VaultOperationAdmitted' $id 'Exclusive authenticated operation admitted; independent OS installation holds no Vault session claim'
            }
            $retrying=($Retry -contains $id)
            if($retrying -and $current -and (Get-PSObjectValue $current 'check' $null)){
                $priorCheck=$current.check
                if($priorCheck -isnot [Collections.IDictionary] -or (Get-PSObjectValue $priorCheck 'consumed' $null) -isnot [bool] -or -not $priorCheck.consumed -or $priorCheck.status -ne 'Completed'){
                    throw 'PAExecUnknown: an unconsumed durable verifier must be reconciled with ordinary Resume before retrying its action'
                }
            }
            $reconciled=$false
            # A step whose action completed but whose later revalidation failed (target drift) is only ever
            # revalidated again, read-only; it never needs re-execution unless the operator asks for -Retry.
            $revalidate=($current -and ($current.status -in @('Succeeded','Skipped') -or [bool](Get-PSObjectValue $current 'revalidationFailed' $false)))
            if($revalidate -and -not $retrying){
                try {
                    $how=Test-PAExecStepCompleted $plan $step $Credentials $inputs $scope $kind $StateRoot $RunId $Secrets $outputs $runtimeValues $current $context
                    $needsRebootData=@($plan.Steps | Where-Object { [string](Get-PSObjectValue $_ 'RebootRequiredFrom' '') -eq $id }).Count -gt 0
                    if($needsRebootData -and -not $outputs.ContainsKey($id)){
                        if($mode -ne 'Detached' -or -not (Get-PSObjectValue $current 'attemptId' '')){throw 'PAExecUnknown: missing durable reboot evidence'}
                        $completed=Get-PSDetachedStatus $plan.Target $Credentials ([string]$current.attemptId)
                        $safeData=Get-PAExecCompletedAttemptData $completed ([string]$current.attemptId) $redactions -RequireRebootEvidence
                        $outputs[$id]=$safeData;$current.data=$safeData
                        Save-PSState $context
                        Add-PSEvent $context 'TaskDataReconciled' $id 'Recovered allowlisted data from the same completed remote attempt'
                    }
                } catch {
                    $current.status='Unknown';$current.revalidationFailed=$true;$current.message=Protect-PSText ([string]$_.Exception.Message) $redactions;Save-PSState $context
                    Add-PSEvent $context 'TaskRevalidationFailed' $id ([string]$_.Exception.Message) 'Error'
                    throw "Unknown: $id :: $($_.Exception.Message)"
                }
                if([bool](Get-PSObjectValue $current 'revalidationFailed' $false)){ $current.status='Succeeded'; $current.revalidationFailed=$false; Save-PSState $context }
                Save-PSState $context
                Add-PSEvent $context 'TaskRevalidated' $id $how
                if($step.Contains('Publishes')){foreach($milestone in @($step.Publishes)){Write-PSMilestone $StateRoot $RunId $milestone $plan.TargetName $id}}
                Complete-PAExecVaultOperation $stepOperationGates $plan.Target $Credentials $current $mode
                $stepOperationGates=@()
                continue
            }
            if($current -and -not $retrying){
                $status=[string]$current.status
                if($status -eq 'Pending'){
                    Add-PSEvent $context 'TaskRestarted' $id 'previous attempt never dispatched (read-only probe phase only); starting a new attempt'
                } elseif([bool](Get-PSObjectValue $current 'actionAcknowledged' $false) -and (Get-PSObjectValue $step 'Verify' '')){
                    $reconciled=$true
                    Add-PSEvent $context 'TaskReconciling' $id 'Action acknowledged; reconciling or repeating only its independent verification'
                } elseif($kind -in @('Wait','Verify') -or ($kind -in @('Transfer','Relay') -and $status -ne 'Failed')){
                    Add-PSEvent $context 'TaskRestarted' $id "idempotent $kind step was $status; repeating with content verification"
                } elseif($kind -eq 'Reboot' -and $status -in @('Dispatched','Running','Unknown') -and (Get-PSObjectValue $current 'bootBefore' '')){
                    try {
                        $boot=Invoke-PSReboot -Target $plan.Target -Credentials $Credentials -TimeoutSeconds $timeout -Context $context -TaskId $id -BootBefore ([string]$current.bootBefore) -AlreadyRequested
                        $current.bootAfter=$boot;$current.status='Verifying';Save-PSState $context
                        $reconciled=$true
                    } catch { throw "Unknown: $id :: reboot not reconciled: $($_.Exception.Message)" }
                } elseif(($mode -eq 'Detached' -or $durableBash) -and (Get-PSObjectValue $current 'attemptId' '') -and $status -in @('Dispatched','Running','Unknown','Verifying')){
                    Add-PSEvent $context 'TaskReconciling' $id "reconciling remote attempt $($current.attemptId)"
                    try { $remote=Wait-PSDetached $plan.Target $Credentials ([string]$current.attemptId) $timeout $context $id -AllowStart }
                    catch { $current.status='Unknown';Save-PSState $context; throw "Unknown: $id :: $($_.Exception.Message)" }
                    if($remote.state -eq 'Succeeded'){
                        $current.status='Verifying';$current.remote=Select-PAExecRemoteEvidence $remote $redactions
                        $current.message=Protect-PSText ([string](Get-PSObjectValue $remote 'message' '')) $redactions
                        $recoveredData=Get-PSObjectValue $remote 'data' $null
                        if($null -ne $recoveredData){$safeData=Select-PAExecSafeData $recoveredData $redactions;$outputs[$id]=$safeData;$current.data=$safeData}
                        $recoveredChanged=Get-PSObjectValue $remote 'changed' $null
                        if($recoveredChanged -is [bool]){$current.changed=$recoveredChanged}
                        Save-PSState $context
                        $reconciled=$true
                    } elseif($remote.state -eq 'Failed'){
                        $current.status='Failed';$current.message=Protect-PSText ([string](Get-PSObjectValue $remote 'message' '')) $redactions;$current.endedUtc=Get-PSNow;Save-PSState $context
                        Add-PSEvent $context 'TaskFailed' $id "remote attempt failed: $(Get-PSObjectValue $remote 'message' '')" 'Error'
                        throw "Failed: $id :: $(Get-PSObjectValue $remote 'message' '')"
                    } else {
                        $current.status='Unknown';$current.message="remote attempt $($remote.state)";Save-PSState $context
                        Add-PSEvent $context 'TaskUnknown' $id "remote attempt $($current.attemptId) is $($remote.state); outcome cannot be established" 'Error'
                        throw "Unknown: $id :: remote attempt $($remote.state); preserve evidence and reconcile target state before any new action"
                    }
                } elseif($status -eq 'Verifying' -and (Get-PSObjectValue $step 'Verify' '')){
                    Add-PSEvent $context 'TaskReconciling' $id 'action acknowledged before interruption; repeating read-only verification'
                    $reconciled=$true
                } else {
                    $prefix='Unknown'; if($status -eq 'Failed'){$prefix='Failed'}
                    throw "${prefix}: $id :: step was previously $status; inspect the target, then restore or rerun with -Resume -Retry $id"
                }
            }
            if($retrying -and $current){
                Add-PSEvent $context 'TaskRetryAuthorised' $id "operator authorised re-execution (previous status $($current.status))" 'Warning'
                $current.previousAttempts=@(@(Get-PSObjectValue $current 'previousAttempts' @())+@([string]$current.attemptId))
            }
            $dispatched=$false
            $acknowledged=$false
            if(-not $reconciled){
                foreach($dependency in @(Get-PSObjectValue $step 'DependsOn' @())){[void](Wait-PSMilestone $StateRoot $RunId ([string]$dependency) $timeout $plan.TargetName $context $id)}
                $attempt=[guid]::NewGuid().ToString('N')
                $previous=@(); if($current){$previous=@(Get-PSObjectValue $current 'previousAttempts' @())}
                $current=@{status='Pending'; attemptId=$attempt; startedUtc=Get-PSNow; endedUtc=$null; verified=$false; previousAttempts=$previous}
                $state.steps[$id]=$current;Save-PSState $context
                Add-PSEvent $context 'TaskStarted' $id "$kind/$mode attempt $attempt"
            } else { $attempt=[string]$current.attemptId; $dispatched=$true; $acknowledged=$true }
            try {
                if(-not $reconciled){
                    $probe=[string](Get-PSObjectValue $step 'Probe' '')
                    if($probe){
                        $pstatus=Get-PSCheck $plan $Credentials $probe $inputs 'Satisfied' $scope
                        if($pstatus.Passed){
                            $current.status='Skipped';$current.verified=$true
                            Add-PSEvent $context 'TaskSkipped' $id ('read-only probe confirmed desired state: '+$pstatus.Message)
                        }
                    }
                }
                if($current.status -ne 'Skipped'){
                    if(-not $reconciled){
                        $current.status='Dispatched';Save-PSState $context;$dispatched=($kind -ne 'Wait')
                        if($kind -eq 'Script'){
                            $scriptFile=Assert-PSProjectPath $plan.Root ([string]$step.Script)
                            if($mode -eq 'Detached'){
                                $recovery=[string](Get-PSObjectValue $step 'RecoveryScript' '')
                                if($recovery){$recovery=Assert-PSProjectPath $plan.Root $recovery}
                                try { [void](Initialize-PSDetached $plan.Target $Credentials $scriptFile $inputs $attempt $recovery $timeout $contract -TaskPrincipalCredentialRef ([string](Get-PSObjectValue $step 'TaskPrincipalCredentialRef' ''))) }
                                catch { throw "PAExecUnknown: detached staging/launch interrupted: $($_.Exception.Message)" }
                                $current.status='Running';Save-PSState $context
                                Add-PSEvent $context 'DetachedLaunched' $id $(if($plan.Target.Runtime -eq 'Bash'){"systemd attempt $attempt launched"}elseif(Get-PSObjectValue $step 'TaskPrincipalCredentialRef' ''){"scheduled task PAExec-$attempt launched with the configured domain identity"}else{"scheduled task PAExec-$attempt launched as SYSTEM"})
                                $result=Wait-PSDetached $plan.Target $Credentials $attempt $timeout $context $id
                                $current.remote=Select-PAExecRemoteEvidence $result $redactions
                                if($result.state -in @('Missing','NotStarted')){throw "PAExecUnknown: launched attempt disappeared from target ($($result.state)); possible target drift or rollback"}
                                if($result.state -eq 'Interrupted'){throw "PAExecUnknown: detached attempt interrupted (process ended without final status)"}
                                $acknowledged=$true
                                if($result.state -ne 'Succeeded'){throw "Detached script failed: $(Get-PSObjectValue $result 'message' '')"}
                                $current.message=Protect-PSText ([string](Get-PSObjectValue $result 'message' '')) $redactions
                                if($null -ne (Get-PSObjectValue $result 'changed' $null)){$current.changed=[bool](Get-PSObjectValue $result 'changed' $false)}
                                $d=Get-PSObjectValue $result 'data' $null; if($null -ne $d){$safeData=Select-PAExecSafeData $d $redactions;$outputs[$id]=$safeData;$current.data=$safeData}
                            }else{
                                $execTarget=$plan.Target
                                if($scope -eq 'Controller'){$execTarget=@{Protocol='Local';Runtime='PowerShell'}}
                                $result=Invoke-PSAdapterScript -Target $execTarget -Credentials $Credentials -ScriptPath $scriptFile -Parameters $inputs -Contract $contract -TimeoutSeconds $timeout -AttemptId $attempt
                                $acknowledged=$true
                                if($result.Output){Add-PSEvent $context 'TaskOutput' $id (Limit-PSText ([string]$result.Output) 2000)}
                                if(-not $result.Ok){throw "Task script failed: $($result.Error)"}
                                $terminal=$result.Terminal
                                $current.message=Protect-PSText ([string](Get-PSObjectValue $terminal 'Message' '')) $redactions
                                if($null -ne (Get-PSObjectValue $terminal 'Changed')){$current.changed=[bool](Get-PSObjectValue $terminal 'Changed')}
                                $d=Get-PSObjectValue $terminal 'Data' $null; if($null -ne $d){$safeData=Select-PAExecSafeData $d $redactions;$outputs[$id]=$safeData;$current.data=$safeData}
                            }
                        }elseif($kind -eq 'Relay'){
                            $from=[string]$step.SourceTarget
                            $src=[string](Resolve-PSValue $step.SourceDir $plan.Inventory $Secrets $outputs $runtimeValues)
                            $dst=[string](Resolve-PSValue $step.DestinationDir $plan.Inventory $Secrets $outputs $runtimeValues)
                            $sourceTarget=$plan.Inventory.Targets[$from]
                            if(-not $sourceTarget.Contains('Runtime')){$sourceTarget['Runtime']='WindowsPowerShell'}
                            $current.changed=Copy-PSRelayFiles $sourceTarget $plan.Target $Credentials $src $dst @($step.Files)
                            $acknowledged=$true
                        }elseif($kind -eq 'Transfer'){
                            $source=[string](Resolve-PSValue $step.Source $plan.Inventory $Secrets $outputs $runtimeValues)
                            $dest=[string](Resolve-PSValue $step.Destination $plan.Inventory $Secrets $outputs $runtimeValues)
                            $direction=[string](Get-PSObjectValue $step 'Direction' 'Upload')
                            if($direction -eq 'Upload'){
                                if(-not [IO.Path]::IsPathRooted($source)){$source=Get-PSPath $plan.Root $source}
                                if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Source missing: $source"}
                                $want=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToUpperInvariant()
                                $frozen=Get-Variable -Name PASeasyFrozenMedia -Scope Script -ErrorAction SilentlyContinue
                                if($frozen -and $null -ne $frozen.Value){
                                    $fullSource=[IO.Path]::GetFullPath($source)
                                    if(-not $frozen.Value.ContainsKey($fullSource) -or $frozen.Value[$fullSource] -ne $want){throw 'Frozen media changed or source was not approved in the run plan'}
                                }
                                $guard=[string](Get-PSObjectValue $step 'BeforeTransfer' '')
                                if($guard){
                                    $prepared=Get-PSCheck $plan $Credentials $guard $inputs 'Passed' 'Target'
                                    if(-not $prepared.Passed){throw 'Upload destination safety check failed'}
                                }
                                if($plan.Target.Protocol -eq 'WinRM' -and (Test-PSWindows)){
                                    $session=Get-PSConnection $plan.Target $Credentials
                                    $ref=[string](Get-PSObjectValue $plan.Target 'CredentialRef' '')
                                    $user=if($ref -and $Credentials.ContainsKey($ref)){[string]$Credentials[$ref].UserName}else{''}
                                    [void](Invoke-Command -Session $session -ScriptBlock (Get-PSWindowsFilePreparation) -ArgumentList $dest,$user -ErrorAction Stop)
                                }
                                $have=Get-PSRemoteFileHash $plan.Target $Credentials $dest
                                if($have -eq $want){
                                    $current.changed=$false
                                    Add-PSEvent $context 'TransferSkipped' $id "destination already has SHA-256 $want"
                                } else {
                                    # Parent computed textually: the controller OS may not share the target's path separator.
                                    $parent=$dest -replace '[\\/][^\\/]*$',''
                                    if(-not $parent){throw "Transfer destination must be an absolute file path: $dest"}
                                    if($plan.Target.Protocol -eq 'Local'){
                                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                                    } elseif($plan.Target.Runtime -eq 'Bash'){
                                        $mk=Invoke-PSRawSSH $plan.Target ("mkdir -p -- '" + $parent.Replace("'","'\''") + "'")
                                        if($mk.ExitCode -ne 0){throw "Cannot create remote directory ($($mk.ExitCode)): $($mk.Output)"}
                                    } else {
                                        [void](Invoke-PSAdapterCommand $plan.Target $Credentials ("New-Item -ItemType Directory -Path "+(ConvertTo-PSSingleQuoted $parent)+" -Force | Out-Null"))
                                    }
                                    $size=(Get-Item -LiteralPath $source).Length
                                    Add-PSEvent $context 'TransferStarted' $id ("uploading {0:N1} MiB" -f ($size/1MB))
                                    $sw=[Diagnostics.Stopwatch]::StartNew()
                                    Copy-PSAdapterFile $plan.Target $Credentials $source $dest
                                    $have=Get-PSRemoteFileHash $plan.Target $Credentials $dest
                                    if($have -ne $want){throw "SHA256 mismatch after upload (expected $want, remote '$have')"}
                                    $current.changed=$true
                                    Add-PSEvent $context 'TransferVerified' $id ("SHA-256 $want verified on target after {0:N0}s" -f $sw.Elapsed.TotalSeconds)
                                }
                                $current.sha256=$want
                            }else{
                                Copy-PSAdapterFile $plan.Target $Credentials $source $dest -Download
                                $current.sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
                            }
                            $acknowledged=$true
                        }elseif($kind -eq 'Reboot'){
                            if(Test-PAExecRebootRequired $step $outputs){
                                $nowBoot=Get-PSBootIdentifier $plan.Target $Credentials
                                $priorBoot=Get-PAExecPriorAttemptBoot $step $state
                                if($priorBoot -and $nowBoot -ne $priorBoot){
                                    $current.bootBefore=$priorBoot;$current.bootAfter=$nowBoot
                                    Add-PSEvent $context 'RebootAlreadyObserved' $id 'Boot changed after the same completed durable attempt; no second reboot requested'
                                    Save-PSState $context
                                }else{
                                    $current.bootBefore=$nowBoot
                                    Save-PSState $context
                                    $current.bootAfter=Invoke-PSReboot -Target $plan.Target -Credentials $Credentials -TimeoutSeconds $timeout -Context $context -TaskId $id -BootBefore ([string]$current.bootBefore)
                                }
                            }else{
                                $current.rebootSkipped=$true
                                $current.message='Vendor checkpoint explicitly reports no reboot required'
                                Add-PSEvent $context 'RebootNotRequired' $id $current.message
                            }
                            $acknowledged=$true
                        }elseif($kind -eq 'Wait'){
                            [void](Wait-PSMilestone $StateRoot $RunId ([string]$step.Milestone) $timeout $plan.TargetName $context $id)
                            $acknowledged=$true
                        }elseif($kind -eq 'Verify'){
                            # No action body exists. A failed check can be repeated on
                            # public Resume without replaying an installation attempt.
                            $acknowledged=$true
                        }
                    }
                    $current.status='Verifying';Save-PSState $context
                    if($acknowledged){$current.actionAcknowledged=$true;Save-PSState $context}
                    $verify=[string](Get-PSObjectValue $step 'Verify' '')
                    if($verify){
                        $check=Get-PAExecStepCheck -Plan $plan -Step $step -Credentials $Credentials -Inputs $inputs -Current $current -Context $context -Script $verify -Scope $scope -TimeoutSeconds $timeout
                        Complete-PAExecCheckGeneration $current
                        if(-not $check.Passed){throw "Verification failed for '$id': $($check.Message)"}
                        $current.verified=$true
                        $current.evidence=@($check.Evidence | ForEach-Object { Protect-PSText ([string]$_) $redactions })
                        Add-PSEvent $context 'TaskVerified' $id ((@($check.Evidence) -join '; ') + $(if($check.Message){' :: '+$check.Message}else{''}))
                    }
                    $current.status='Succeeded'
                }
                $current.endedUtc=Get-PSNow
                Save-PSState $context
                Add-PSEvent $context 'TaskCompleted' $id ([string]$current.status + $(if(Get-PSObjectValue $current 'message' ''){': '+(Get-PSObjectValue $current 'message' '')}else{''}))
                if($step.Contains('Publishes')){foreach($m in @($step.Publishes)){Write-PSMilestone $StateRoot $RunId ([string]$m) $plan.TargetName $id; Add-PSEvent $context 'MilestonePublished' $id ([string]$m)}}
                if(($mode -eq 'Detached' -or $durableBash) -and $current.status -eq 'Succeeded'){try{Finish-PSDetached $plan.Target $Credentials $attempt}catch{Add-PSEvent $context 'CleanupWarning' $id ('detached task cleanup failed: '+$_.Exception.Message) 'Warning'}}
                Complete-PAExecVaultOperation $stepOperationGates $plan.Target $Credentials $current $mode
                $stepOperationGates=@()
            }catch{
                $message=[string]$_.Exception.Message
                $uncertain=($message.StartsWith('PAExecUnknown:') -or ($dispatched -and -not $acknowledged -and $plan.Target.Protocol -ne 'Local' -and $scope -ne 'Controller'))
                if($uncertain){$current.status='Unknown'}else{$current.status='Failed'}
                $current.message=Protect-PSText $message $redactions
                $current.endedUtc=Get-PSNow
                Save-PSState $context
                Add-PSEvent $context $(if($uncertain){'TaskUnknown'}else{'TaskFailed'}) $id $message 'Error'
                throw "$($current.status): $id :: $message"
            }
        }
        # Boot-time recovery registrations are removed only once the entire workflow is verified.
        Clear-PSRecoveryTasks $plan $Credentials $state.steps
        $state.status='Succeeded';Save-PSState $context
        Add-PSEvent $context 'RunCompleted' '' 'Workflow finished and verified'
        return [pscustomobject]@{RunId=$RunId;Target=$plan.TargetName;Status='Succeeded';Steps=@($plan.Steps | ForEach-Object { [string]$_.Id })}
    }catch{
        $text=[string]$_.Exception.Message
        if($context.State -and $context.State.status -ne 'Succeeded'){
            if($text -match '^PAExecLocked:'){ $context.State.status='Blocked' }
            elseif($text -match '^(Unknown:|PAExecUnknown:)'){ $context.State.status='Unknown' }
            else { $context.State.status='Failed' }
            $context.State.lastError=Protect-PSText $text $redactions
            try { Save-PSState $context; Add-PSEvent $context 'RunStopped' '' "$($context.State.status): $text" 'Error' } catch { Write-Verbose 'state save failed' }
        }
        throw
    }finally{
        try{
            if(@($stepOperationGates).Count){Exit-PASeasyVaultOperation -Gates $stepOperationGates -Succeeded $false}
        }finally{
            if($remoteLock -and $context.State -and $context.State.status -eq 'Succeeded'){
                try{[void](Invoke-PSRemoteLock $plan $Credentials $RunId -Release)}catch{Write-Verbose 'lock release failed'}
            }
            try{Clear-PSConnections}finally{$lock.Dispose()}
        }
    }
}

function Test-PAExecRebootRequired {
    param($Step,[hashtable]$Outputs)
    $source=[string](Get-PSObjectValue $Step 'RebootRequiredFrom' '')
    if(-not $source){return $true}
    if(-not $Outputs.ContainsKey($source)){throw 'PAExecUnknown: missing vendor reboot checkpoint'}
    $record=$Outputs[$source]
    $required=Get-PSObjectValue $record 'RebootRequired' $null
    if($required -isnot [bool]){throw 'PAExecUnknown: vendor reboot checkpoint must be Boolean'}
    return $required
}

function Get-PAExecCompletedAttemptData {
    param($Remote,[string]$AttemptId,[string[]]$Redactions=@(),[switch]$RequireRebootEvidence)
    if((Get-PSObjectValue $Remote 'state' '') -ne 'Succeeded' -or (Get-PSObjectValue $Remote 'attemptId' '') -ne $AttemptId){throw 'PAExecUnknown: remote result does not prove the same completed attempt'}
    $data=Get-PSObjectValue $Remote 'data' $null
    if($null -eq $data){throw 'PAExecUnknown: completed remote attempt has no data checkpoint'}
    $safe=Select-PAExecSafeData $data $Redactions
    if($RequireRebootEvidence -and (Get-PSObjectValue $safe 'RebootRequired' $null) -isnot [bool]){throw 'PAExecUnknown: completed attempt has no Boolean reboot evidence'}
    return $safe
}

function Get-PAExecPriorAttemptBoot {
    param($Step,$State)
    $source=[string](Get-PSObjectValue $Step 'RebootFromAttempt' '')
    if(-not $source){return ''}
    $prior=Get-PSObjectValue $State.steps $source $null
    $remote=Get-PSObjectValue $prior 'remote' $null
    $attempt=[string](Get-PSObjectValue $prior 'attemptId' '')
    $boot=[string](Get-PSObjectValue $remote 'bootUtc' '')
    if((Get-PSObjectValue $prior 'status' '') -ne 'Succeeded' -or -not $attempt -or (Get-PSObjectValue $remote 'attemptId' '') -ne $attempt -or (Get-PSObjectValue $remote 'state' '') -ne 'Succeeded' -or -not $boot){throw 'PAExecUnknown: reboot predecessor lacks the same completed attempt boot evidence'}
    return $boot
}
