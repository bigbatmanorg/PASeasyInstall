function Stop-PASRun {
    <#
    .SYNOPSIS
    Abandons a run, retaining target locks unless the lab machines were reset.
    .DESCRIPTION
    A run that stopped (Failed, Unknown, Blocked, Interrupted, LaunchFailed) keeps a lock folder on
    every server it did not finish, so that no other run touches a half-installed server. Stop-PASRun
    marks the run abandoned, but keeps the locks by default. A detached remote worker
    can outlive its controller. Restore or rebuild affected VMs before explicitly releasing the locks.

    - A run that is still running is refused, unless you add -Force: then the controller process of
      this run is stopped first.
    - The run is marked Abandoned. An abandoned run cannot be resumed.
    - Pass -ReleaseLocksAfterReset AND -CredentialMap only after restoring/rebuilding the affected lab VMs.
      Locks still held by another run are never released. Without both parameters the locks remain.

    No installed software is changed or removed: a server may be left with a partial installation.

    Returns RunId, Status, PreviousStatus, ControllerStopped and Locks (Target, Computer, LockFolder,
    Released, Message).
    .PARAMETER RunId
    Run id (32 hexadecimal characters).
    .PARAMETER CredentialMap
    Server accounts for explicit -ReleaseLocksAfterReset cleanup: @{ <server id> = PSCredential }.
    .PARAMETER Force
    Stops the controller only; detached workers may continue and target locks stay.
    .PARAMETER ReleaseLocksAfterReset
    Explicitly release locks after all affected lab targets have been reset/rebuilt. Not safe otherwise.
    .EXAMPLE
    Stop-PASRun -RunId 83cf015f78bd4743a54e6d0a9d0dd301 -CredentialMap @{ vault01 = (Get-Credential Administrator) }

    Gives up a failed run but leaves the remote target locks in place.
    .EXAMPLE
    Get-PASRun | Where-Object Status -eq 'Running' | Stop-PASRun -Force

    Stops every running installation after asking for confirmation, and lists the lock folders.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$RunId,

        [hashtable]$CredentialMap,

        [switch]$Force,

        [switch]$ReleaseLocksAfterReset
    )

    process {
        $id = $RunId.ToLowerInvariant()
        $record = Get-PASRunRecord -RunId $id
        if (-not $record) {
            throw "Run $id was not found under $(Get-PASDataRoot). Get-PASRun lists the runs of this controller."
        }
        $status = [string]$record.status
        $running = ($status -in @('Launching', 'Running'))
        if ($running -and -not $Force) {
            throw "Run $id is still running. Wait for it (Wait-PASRun -RunId $id), or stop it with Stop-PASRun -RunId $id -Force."
        }

        $action = 'Mark the run as Abandoned, retaining target locks'
        if ($running) {
            $action = 'Stop the controller, mark the run Abandoned, retain target locks'
        }
        if ($ReleaseLocksAfterReset) {
            if (-not $CredentialMap) { throw '-ReleaseLocksAfterReset requires -CredentialMap' }
            $action += '; release old target locks only because the operator confirms every affected lab VM was reset/rebuilt'
        }
        if (-not $PSCmdlet.ShouldProcess("run $id of environment '$([string]$record.name)' (status $status)", $action)) {
            return
        }

        $stop = @{
            RunId = $id
            Force = $Force
            ReleaseLocksAfterReset = $ReleaseLocksAfterReset
            Confirm = $false
        }
        if ($CredentialMap) {
            $stop['CredentialMap'] = $CredentialMap
        }
        return (Stop-PASDeployment @stop)
    }
}
