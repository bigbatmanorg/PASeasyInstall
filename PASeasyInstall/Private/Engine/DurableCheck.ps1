# Authenticated verifiers have their own immutable attempts. A completed action is
# never relaunched because its later independent check failed or was interrupted.
function Get-PASDurableCheck {
    param(
        $Plan,
        $Step,
        [hashtable]$Credentials,
        [hashtable]$Inputs,
        [hashtable]$Current,
        [hashtable]$Context,
        [string]$Purpose = 'Initial',
        [int]$TimeoutSeconds = 900
    )
    $authenticated = [bool](Get-PASValue $Step 'VerifyRequiresVaultSession' $false)
    if ($authenticated -and
        -not [bool](Get-PASValue $Context 'VaultLocked' $false)) { throw 'PAExecUnknown: authenticated check runs without the Vault lock' }
    $path = Assert-PASProjectPath $Plan.Root ([string]$Step.Verify)
    $payload = Get-PASRecipePayload $path
    $digest = Get-PASFileSetDigest $payload.Files
    $check = Get-PASValue $Current 'check' $null
    if ($check -and
        ($check -isnot [Collections.IDictionary] -or
        [int](Get-PASValue $check 'schemaVersion' 0) -ne 1 -or
        [string](Get-PASValue $check 'attemptId' '') -notmatch '^[a-f0-9]{32}$' -or
        (Get-PASValue $check 'consumed' $null) -isnot [bool])) { throw 'PAExecUnknown: durable check journal is invalid' }
    if (-not $check -or $check.consumed) {
        $previous = @()
        if ($check) { $previous = @(@(Get-PASValue $check 'previousAttempts' @()) + @([string]$check.attemptId)) }
        if ($previous.Count -ge 1000) { throw 'PAExecUnknown: check history limit reached; preserve the journal for review' }
        $check = @{
            schemaVersion = 1
            attemptId = [guid]::NewGuid().ToString('N')
            purpose = $Purpose
            status = 'Pending'
            scriptDigest = $digest
            consumed = $false
            previousAttempts = $previous
            startedUtc = (Get-PASNow)
        }
        $Current.check = $check
        Save-PASState $Context
    }
    if ($check.scriptDigest -cne $digest) { throw 'PAExecUnknown: durable check script changed' }
    if ($check.status -eq 'Pending') {
        # Dispatch intent is durable before any remote callback. Missing evidence
        # after that point is uncertain, never permission to allocate another ID.
        $check.status = 'Dispatched'
        Save-PASState $Context
        try { [void](Initialize-PASDetached -Target $Plan.Target -Credentials $Credentials -ScriptPath $path -Parameters (Select-PASDeclaredInputs $path $Inputs) -AttemptId $check.attemptId -TimeoutSeconds $TimeoutSeconds -Contract 'Check') }
        catch { throw ('PAExecUnknown: durable check staging interrupted: ' + $_.Exception.Message) }
    }
    if ($check.status -notin @('Dispatched', 'Completed')) { throw 'PAExecUnknown: durable check journal state is unsupported' }
    $remote = Wait-PASDetached -Target $Plan.Target -Credentials $Credentials -AttemptId $check.attemptId -TimeoutSeconds $TimeoutSeconds -Context $Context -TaskId ([string]$Step.Id) -AllowStart
    if ($remote.state -ne 'Succeeded' -or
        [string](Get-PASValue $remote 'attemptId' '') -cne $check.attemptId) { throw 'PAExecUnknown: durable check has no successful result from the same attempt; reconcile before another login' }
    Wait-PASDetachedSessionQuiescence $Plan.Target $Credentials $check.attemptId
    $result = Get-PASValue $remote 'check' $null
    if ($result -isnot [Collections.IDictionary] -or
        [int](Get-PASValue $result 'schemaVersion' 0) -ne 1 -or
        (Get-PASValue $result 'passed' $null) -isnot [bool]) { throw 'PAExecUnknown: durable check result has no typed acceptance result' }
    $closed = Get-PASValue $result 'sessionClosed' $null
    if ($authenticated -and
        ($closed -isnot [bool] -or
        -not $closed)) { throw 'PAExecUnknown: durable authenticated check did not acknowledge session closure' }
    $evidence = @(Get-PASValue $result 'evidence' @())
    if ($evidence.Count -gt 32) { throw 'PAExecUnknown: durable check evidence exceeds its limit' }
    foreach ($entry in $evidence) {
        if ($entry -isnot [string] -or
            $entry.Length -gt 2048) { throw 'PAExecUnknown: durable check evidence is malformed' }
    }
    $message = Get-PASValue $result 'message' ''
    if ($message -isnot [string] -or $message.Length -gt 4000) { throw 'PAExecUnknown: durable check message is malformed' }
    try { Finish-PASDetached $Plan.Target $Credentials $check.attemptId }catch { throw 'PAExecUnknown: completed check task cleanup is unconfirmed' }
    $check.status = 'Completed'
    $check.passed = $result.passed
    $check.sessionClosed = Get-PASValue $result 'sessionClosed' $false
    $check.endedUtc = Get-PASNow
    # Unconsumed until the parent accepts the result in its own atomic checkpoint.
    Save-PASState $Context
    return [pscustomobject]@{
        Passed = $result.passed
        Message = (Protect-PASText $message $Context.Redactions)
        Evidence = @($evidence | ForEach-Object { Protect-PASText $_ $Context.Redactions })
    }
}
function Complete-PASCheckGeneration {
    param([hashtable]$Current)
    $check = Get-PASValue $Current 'check' $null
    if ($check -and $check.status -eq 'Completed' -and -not $check.consumed) { $check.consumed = $true }
}
function Get-PASStepCheck {
    param(
        $Plan,
        $Step,
        [hashtable]$Credentials,
        [hashtable]$Inputs,
        [hashtable]$Current,
        [hashtable]$Context,
        [string]$Script,
        [string]$Property = 'Passed',
        [string]$Scope = 'Target',
        [string]$Purpose = 'Initial',
        [int]$TimeoutSeconds = 900
    )
    if ([bool](Get-PASValue $Step 'RequiresVaultSession' $false)) {
        Wait-PASDetachedSessionQuiescence $Plan.Target $Credentials ([string]$Current.attemptId)
    }
    if ([string](Get-PASValue $Step 'VerifyMode' 'Direct') -eq 'Detached') {
        if ($Script -cne [string]$Step.Verify -or
            $Property -ne 'Passed') { throw 'PAExecUnknown: detached verification cannot substitute another script or property' }
        return Get-PASDurableCheck $Plan $Step $Credentials $Inputs $Current $Context $Purpose $TimeoutSeconds
    }
    return Get-PASCheck $Plan $Credentials $Script $Inputs $Property $Scope $TimeoutSeconds
}
