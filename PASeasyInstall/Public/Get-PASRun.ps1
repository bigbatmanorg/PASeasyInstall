function Get-PASRun {
    <#
    .SYNOPSIS
    Lists the installation runs of this controller, or shows one run with its components and events.
    .DESCRIPTION
    Without -RunId: one line per run, newest first, with RunId, Name (the environment), Status,
    StartedUtc, FinishedUtc and Message.

    With -RunId: the run in detail, with RunId, Name, Status, CurrentComponent, Message, LastStep,
    StartedUtc, FinishedUtc, CompletedEvents, ErrorEvents, Components (Id, Type, Status, Message),
    Events (the last -Tail events, see Get-PASRunEvent), OperationallyVerified and RunDirectory (the
    folder that holds the run's files).

    Status of a run: Launching or Running while the controller works; Succeeded; or stopped as Failed,
    Unknown (an outcome on a server could not be determined), Blocked, Interrupted (the controller
    process ended), LaunchFailed or Abandoned (see Stop-PASRun). A stopped run is continued with
    Resume-PASRun. Succeeded means every installer step finished and was verified; Test-PASHealth
    checks that the lab works end to end.

    Reads local files only. No server is contacted.
    .PARAMETER RunId
    Run id (32 hexadecimal characters), as returned by the Install-* commands.
    .PARAMETER Tail
    With -RunId: how many of the latest events to include (1 to 1000). Default 150.
    .PARAMETER Last
    Without -RunId: only the newest <n> runs.
    .EXAMPLE
    Get-PASRun | Format-Table RunId, Name, Status, StartedUtc

    Lists all runs.
    .EXAMPLE
    Get-PASRun -RunId 688d8e04f1874d41a75cda4441c00553 | Format-List Status, CurrentComponent, LastStep, Message
    .EXAMPLE
    (Get-PASRun -Last 1 | Get-PASRun).Components | Format-Table Id, Type, Status, Message

    Shows the components of the newest run.
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Run', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$RunId,

        [Parameter(ParameterSetName = 'Run')]
        [ValidateRange(1, 1000)]
        [int]$Tail = 150,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, 100000)]
        [int]$Last = 0
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'List') {
            # Get-PASRunRecords returns the run records newest first.
            $records = @(Get-PASRunRecords)
            if ($Last -gt 0) {
                $records = @($records | Select-Object -First $Last)
            }
            foreach ($record in $records) {
                [pscustomobject]@{
                    RunId = [string]$record.id
                    Name = [string]$record.name
                    Status = [string]$record.status
                    StartedUtc = [string]$record.startedUtc
                    FinishedUtc = [string]$record.finishedUtc
                    Message = [string]$record.message
                }
            }
            return
        }

        $id = $RunId.ToLowerInvariant()
        if (-not (Get-PASRunRecord -RunId $id)) {
            throw "Run $id was not found under $(Get-PASDataRoot). Get-PASRun without parameters lists the runs of this controller and this Windows user."
        }
        $run = Get-PASDeploymentSnapshot -RunId $id -Tail $Tail
        $run | Add-Member -NotePropertyName RunDirectory -NotePropertyValue (Get-PASRunDirectory -RunId $id) -Force
        return $run
    }
}
