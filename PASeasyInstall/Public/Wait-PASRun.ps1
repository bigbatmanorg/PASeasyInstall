function Wait-PASRun {
    <#
    .SYNOPSIS
    Follows a run until it ends: prints its progress events as they arrive and returns the final run.
    .DESCRIPTION
    Every new event is written to the console as one line: local time, component, step, status, message.
    When the run reaches a final status the same object Get-PASRun -RunId returns is returned. Final
    statuses: Succeeded, Failed, LaunchFailed, Unknown, Interrupted, Blocked, Abandoned.

    Waiting does not influence the run. You can stop waiting with Ctrl+C at any time: the installation
    continues in its own process, and Wait-PASRun can be started again later. When started again it
    first prints the latest (up to 1000) events of the run.
    .PARAMETER RunId
    Run id (32 hexadecimal characters).
    .PARAMETER PollSeconds
    Seconds between two looks at the run (1 to 600). Default 15.
    .PARAMETER Quiet
    Prints nothing; only waits and returns the final run.
    .EXAMPLE
    Wait-PASRun -RunId 688d8e04f1874d41a75cda4441c00553
    .EXAMPLE
    $run = Install-PASLab -Path .\MyLab.json | Wait-PASRun -Quiet
    if ($run.Status -ne 'Succeeded') { $run.Components | Where-Object Status -ne 'Succeeded' }

    Waits silently and shows the components that did not succeed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$RunId,

        [ValidateRange(1, 600)]
        [int]$PollSeconds = 15,

        [switch]$Quiet
    )

    process {
        $finalStatuses = @('Succeeded', 'Failed', 'LaunchFailed', 'Unknown', 'Interrupted', 'Blocked', 'Abandoned')
        # Events already printed. An event is identified by its time stamp (100 ns resolution), component,
        # step and text. The Sequence number is not used: only engine events carry a real one, and it
        # restarts for every component.
        $printed = @{}

        while ($true) {
            $run = Get-PASRun -RunId $RunId -Tail 1000
            if (-not $Quiet) {
                foreach ($entry in @($run.Events)) {
                    $key = @([string]$entry.TimestampUtc, [string]$entry.Component, [string]$entry.Stage, [string]$entry.Event, [string]$entry.Message) -join '|'
                    if ($printed.ContainsKey($key)) {
                        continue
                    }
                    $printed[$key] = $true
                    $time = ''
                    try {
                        $time = ([datetime]$entry.TimestampUtc).ToLocalTime().ToString('HH:mm:ss')
                    } catch {
                        $time = ''
                    }
                    Write-Host ('{0,-8} {1,-10} {2,-24} {3,-8} {4}' -f $time, [string]$entry.Component, [string]$entry.Stage, [string]$entry.Status, [string]$entry.Message)
                }
            }
            if ([string]$run.Status -in $finalStatuses) {
                if (-not $Quiet) {
                    Write-Host ("Run $($run.RunId) ended: $($run.Status). $($run.Message)")
                    if ($run.Status -notin @('Succeeded', 'Abandoned')) {
                        $resume = "Resume-PASRun -RunId $($run.RunId)"
                        # A failed step is never repeated on its own. Name it, so the hint can be copied as it is.
                        $failedStep = @($run.Events | Where-Object { [string]$_.Status -in @('Failed', 'Unknown') -and [string]$_.Stage }) | Select-Object -Last 1
                        if ($failedStep) {
                            $resume += " -RetryStep $($failedStep.Component):$($failedStep.Stage)"
                        }
                        Write-Host "Look at the failed step (Get-PASRunEvent -RunId $($run.RunId) -Failed), correct the cause, then continue with: $resume"
                    }
                }
                return $run
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }
}
