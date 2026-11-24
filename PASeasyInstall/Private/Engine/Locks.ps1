# Locks. There are three, and only three:
#
#   1. Run lock     <run>\controller.lock: an exclusive file handle held by the run's controller process
#                   (Invoke-PASRunController). It ends with the process, so a dead controller never blocks.
#   2. Target lock  a lock folder on the server that names the RunId installing it (Invoke-PASRemoteLock in
#                   Engine.ps1). It is kept when a run fails, on purpose: the same run takes it again on
#                   resume, and no other run touches a half-installed server. Stop-PASRun -ReleaseLocksAfterReset releases it after the server was restored.
#   3. Vault lock   the named mutex below: only one controller process on this machine works with an
#                   authenticated Vault session at a time. It is always released in a finally block,
#                   never kept after a failure, and leaves no files.

function Enter-PASVaultLock {
    # Waits for the Vault lock of one Vault address and returns it. Pass the result to Exit-PASVaultLock.
    # The mutex is re-entrant on the same thread: a workflow step may take it again while the controller
    # already holds it for the whole Vault installation.
    # -Cancel: one or more wait handles of a parallel run (Private\Run\Lanes.ps1). When one of them is set the
    # wait ends with PASLaneStopped, so a server does not wait for something that will never come.
    param([Parameter(Mandatory)][string]$Address, [int]$TimeoutSeconds = 180, $Cancel = $null)
    $key = $Address.Trim().TrimEnd('.').ToLowerInvariant() -replace '[^a-z0-9.-]', '_'
    if (-not $key) { throw 'The Vault lock needs the Vault address' }
    $name = 'Global\PASeasyInstall-Vault-' + $key
    # Every signed-in user of this controller machine may use the mutex, so two operators exclude each other too.
    $rights = [Security.AccessControl.MutexRights]'Synchronize,Modify'
    $security = [Security.AccessControl.MutexSecurity]::new()
    $everyUser = [Security.Principal.SecurityIdentifier]::new('S-1-5-11')
    $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($everyUser, $rights, 'Allow'))
    $created = $false
    try {
        $mutex = [Threading.Mutex]::new($false, $name, [ref]$created, $security)
    } catch [UnauthorizedAccessException] {
        # Created by another user: open it with the rights that user granted.
        $mutex = [Threading.Mutex]::OpenExisting($name, $rights)
    }
    $held = $false
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        while (-not $held -and [DateTime]::UtcNow -lt $deadline) {
            $held = $mutex.WaitOne(1000)
            if (-not $held -and (Test-PASGateCancelled $Cancel)) {
                $mutex.Dispose()
                throw 'PASLaneStopped: a server this one depends on failed, or the run is being stopped. Nothing was started for this step.'
            }
        }
    } catch [Threading.AbandonedMutexException] {
        # The previous holder ended without releasing it. The mutex is ours now.
        $held = $true
    }
    if (-not $held) {
        $mutex.Dispose()
        throw "Vault $Address is in use by another PASeasyInstall controller on this machine (waited $TimeoutSeconds seconds). Wait until it has finished, then resume this run."
    }
    return $mutex
}

function Wait-PASVaultGate {
    <# A parallel run (Private\Run\Lanes.ps1) hands every server a gate for its steps that sign in to the Vault:
         Wait    wait handles that must all be set first (the Vault is installed; the first PVWA is registered)
         Cancel  wait handles; one of them is set when the run is being stopped or when a server that this
                 one depends on failed.
       Returns $true when it had to wait. Throws PASLaneStopped when the run is stopped while waiting. #>
    param($Gate)
    if (-not $Gate) {
        return $false
    }
    $waited = $false
    $seconds = [int](Get-PASValue $Gate 'TimeoutSeconds' 14400)
    if ($seconds -le 0 -or $seconds -gt 172800) { throw 'Invalid dependency timeout budget' }
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    $names = @((Get-PASValue $Gate 'Names' @()) | ForEach-Object { [string]$_ })
    foreach ($handle in @($Gate.Wait)) {
        if ($null -eq $handle) {
            continue
        }
        while (-not $handle.WaitOne(0)) {
            $waited = $true
            if (Test-PASGateCancelled $Gate.Cancel) {
                throw 'PASLaneStopped: a server this one depends on failed, or the run is being stopped. Nothing was started for this step.'
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw ('PASLaneStopped: dependency wait timed out after ' + $seconds + ' seconds; waiting for: ' + ($names -join ', '))
            }
            [void]$handle.WaitOne(1000)
        }
        # Failure can race with publication; failure has priority over a spuriously open gate.
        if (Test-PASGateCancelled $Gate.Cancel) {
            throw 'PASLaneStopped: dependency failed while waiting; no dependent step was dispatched.'
        }
    }
    return $waited
}

function Test-PASGateCancelled {
    # $true when one of the cancel handles of a gate is set. Accepts one handle, several or none.
    param($Cancel)
    foreach ($handle in @($Cancel)) {
        if ($null -ne $handle -and $handle.WaitOne(0)) {
            return $true
        }
    }
    return $false
}

function Test-PASVaultGateOpen {
    # $true when a step would not have to wait at this gate.
    param($Gate)
    if (-not $Gate) {
        return $true
    }
    foreach ($handle in @($Gate.Wait)) {
        if ($null -ne $handle -and -not $handle.WaitOne(0)) {
            return $false
        }
    }
    return $true
}

function Exit-PASVaultLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try {
        $Lock.ReleaseMutex()
    } catch [ApplicationException] {
        # Not owned by this thread (PowerShell moved to another thread). Closing the handle is all that is left.
        Write-Verbose 'Vault lock was not owned by the releasing thread'
    } finally {
        $Lock.Dispose()
    }
}
