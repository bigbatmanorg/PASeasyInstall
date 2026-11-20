# Locks. There are three, and only three:
#
#   1. Run lock     <run>\controller.lock: an exclusive file handle held by the run's controller process
#                   (Invoke-PASRunController). It ends with the process, so a dead controller never blocks.
#   2. Target lock  a lock folder on the server that names the RunId installing it (Invoke-PASRemoteLock in
#                   Engine.ps1). It is kept when a run fails, on purpose: the same run takes it again on
#                   resume, and no other run touches a half-installed server. Stop-PASDeployment releases it.
#   3. Vault lock   the named mutex below: only one controller process on this machine works with an
#                   authenticated Vault session at a time. It is always released in a finally block,
#                   never kept after a failure, and leaves no files.

function Enter-PASVaultLock {
    # Waits for the Vault lock of one Vault address and returns it. Pass the result to Exit-PASVaultLock.
    # The mutex is re-entrant on the same thread: a workflow step may take it again while the controller
    # already holds it for the whole Vault installation.
    param([Parameter(Mandatory)][string]$Address,[int]$TimeoutSeconds = 180)
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
    try {
        $held = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
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
