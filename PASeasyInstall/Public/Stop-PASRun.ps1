function Stop-PASRun {
    <#
    .SYNOPSIS
    Stops or gives up a run: marks it Abandoned and releases the locks it holds on the servers.
    .DESCRIPTION
    A run that stopped (Failed, Unknown, Blocked, Interrupted, LaunchFailed) keeps a lock folder on
    every server it did not finish, so that no other run touches a half-installed server. Stop-PASRun
    gives those servers back. Use it when you will not resume the run, typically after you reset or
    rebuilt the servers.

    - A run that is still running is refused, unless you add -Force: then the controller process of
      this run is stopped first.
    - The run is marked Abandoned. An abandoned run cannot be resumed.
    - With -CredentialMap the lock on every unfinished server is released, if it still belongs to
      this run. A server that cannot be reached becomes a warning.
    - Without -CredentialMap no server is contacted; the lock folders to delete by hand are listed.

    No installed software is changed or removed: a server may be left with a partial installation.

    Returns RunId, Status, PreviousStatus, ControllerStopped and Locks (Target, Computer, LockFolder,
    Released, Message).
    .PARAMETER RunId
    Run id (32 hexadecimal characters).
    .PARAMETER CredentialMap
    Server accounts used to release the locks: @{ <server id> = PSCredential }, as for Install-PASLab.
    .PARAMETER Force
    Also stops a run that is still running, by ending its controller process.
    .EXAMPLE
    Stop-PASRun -RunId 83cf015f78bd4743a54e6d0a9d0dd301 -CredentialMap @{ vault01 = (Get-Credential Administrator) }

    Gives up a failed run and releases its lock on the Vault server.
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

        [switch]$Force
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

        $action = 'Mark the run as Abandoned and release its server locks'
        if ($running) {
            $action = 'Stop the running installation, mark the run as Abandoned and release its server locks'
        }
        if (-not $PSCmdlet.ShouldProcess("run $id of environment '$([string]$record.name)' (status $status)", $action)) {
            return
        }

        $stop = @{
            RunId   = $id
            Force   = $Force
            Confirm = $false
        }
        if ($CredentialMap) {
            $stop['CredentialMap'] = $CredentialMap
        }
        return (Stop-PASDeployment @stop)
    }
}
