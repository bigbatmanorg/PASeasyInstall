function Get-PASRunEvent {
    <#
    .SYNOPSIS
    Returns the progress events of a run, oldest first.
    .DESCRIPTION
    Each event has TimestampUtc, RunId, Component (the component id of the configuration), Stage (the
    step), Event (its type, e.g. TaskStarted, TaskCompleted), Level (Information, Warning or Error),
    Status (Running, Complete, Failed, Warning or Info), Source (Controller or Engine), Message and
    Sequence.

    The events of the controller and of every component are merged. Reads local files only.
    .PARAMETER RunId
    Run id (32 hexadecimal characters).
    .PARAMETER Tail
    How many of the latest events to read (1 to 1000). Default 150.
    .PARAMETER Failed
    Only the events whose Status is Failed.
    .EXAMPLE
    Get-PASRunEvent -RunId 688d8e04f1874d41a75cda4441c00553 -Tail 50 | Format-Table TimestampUtc, Component, Stage, Status, Message
    .EXAMPLE
    Get-PASRun -Last 1 | Get-PASRunEvent -Tail 1000 -Failed | Format-List Component, Stage, Message

    Shows what failed in the newest run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$RunId,

        [ValidateRange(1, 1000)]
        [int]$Tail = 150,

        [switch]$Failed
    )

    process {
        $id = $RunId.ToLowerInvariant()
        if (-not (Get-PASRunRecord -RunId $id)) {
            throw "Run $id was not found under $(Get-PASDataRoot). Get-PASRun lists the runs of this controller."
        }
        $events = @(Get-PASDeploymentEvents -RunId $id -Tail $Tail)
        if ($Failed) {
            $events = @($events | Where-Object { $_.Status -eq 'Failed' })
        }
        return $events
    }
}
