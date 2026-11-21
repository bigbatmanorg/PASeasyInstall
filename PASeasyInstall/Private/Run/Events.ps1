# Read-only views of a run: its events and a snapshot (status, components, recent events).
# The run controller writes <run>\events.jsonl; every engine target writes <run>\<target>\events.jsonl
# and keeps its journal in <run>\<target>\state.json. Nothing here contacts a server.

function ConvertTo-PASComponentId {
    <# The Vault engine journals its two roles as primary/primary_final and dr/dr_final. #>
    param([string]$Component)
    switch -Regex ($Component) { '^primary(_final)?$' { return 'vault' } '^dr(_final)?$' { return 'dr' } default { return $Component } }
}

function Get-PASDeploymentEvents {
    # The last events of a run, controller and engine merged, oldest first.
    # Status of an event: Running, Complete, Failed, Warning or Info (derived from its type and level).
    [CmdletBinding()]param([Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{32}$')][string]$RunId,
        [string]$DataRoot = (Get-PASDataRoot), [ValidateRange(1, 1000)][int]$Tail = 150)
    $dir = Get-PASRunDirectory -RunId $RunId -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $sources = @()
    $controllerEvents = Join-Path $dir 'events.jsonl'
    if (Test-Path -LiteralPath $controllerEvents -PathType Leaf) {
        $sources += @{
            Path = $controllerEvents
            Type = 'Controller'
        }
    }
    foreach ($subdir in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction Stop)) {
        if ($subdir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $candidate = Join-Path $subdir.FullName 'events.jsonl'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $sources += @{ Path = $candidate; Type = 'Engine' } }
    }
    $events = New-Object System.Collections.ArrayList
    foreach ($source in $sources) {
        $lineNumber = 0
        foreach ($line in @(Get-Content -LiteralPath $source.Path -Tail $Tail -Encoding UTF8 -ErrorAction Stop)) {
            $lineNumber++
            if (-not $line) { continue }
            # A partially written last line may be observed; skip it, never guess a step state.
            try { $data = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $eventType = [string](Get-PASValue $data 'type' (Get-PASValue $data 'event' 'Event'))
            $level = [string](Get-PASValue $data 'level' 'Information')
            if ($level -notin @('Information', 'Warning', 'Error')) { $level = 'Information' }
            $state = 'Info'
            if ($level -eq 'Error' -or $eventType -match '(?i)(Failed|Unknown|Stopped)') { $state = 'Failed' }
            elseif ($level -eq 'Warning' -or $eventType -match '(?i)(Warning|Retry|Reconcile)') { $state = 'Warning' }
            elseif ($eventType -match '(?i)(Completed|Verified|Skipped|Revalidated|Published|Captured|Created)') { $state = 'Complete' }
            elseif ($eventType -match '(?i)(Started|Launched|Executing)') { $state = 'Running' }
            # Engine events name their target; show the component it belongs to (primary_final -> vault).
            $component = ConvertTo-PASComponentId ([string](Get-PASValue $data 'target' (Get-PASValue $data 'component' '')))
            [void]$events.Add([pscustomobject]@{
                    TimestampUtc = [string](Get-PASValue $data 'timestampUtc' '')
                    RunId = $RunId
                    Component = $component
                    Stage = [string](Get-PASValue $data 'taskId' '')
                    Event = $eventType
                    Level = $level
                    Status = $state
                    Source = $source.Type
                    Message = [string](Get-PASValue $data 'message' '')
                    Sequence = [int](Get-PASValue $data 'sequence' $lineNumber)
                })
        }
    }
    return @($events.ToArray() | Sort-Object -Property TimestampUtc, Source, Component, Sequence | Select-Object -Last $Tail)
}

function Get-PASRunComponents {
    <# One entry per plan item and per domain join: Id, Type, Status, Message.
       The status comes from the journals (state.json) of the engine targets that install the item:
         Pending      not started (or partly done and waiting for a resume)
         Running      being installed by the live controller
         Succeeded    every target of the item finished and was verified
         Failed / Unknown / Blocked   as recorded by the engine (see Get-PASRunFailureStatus)
         Interrupted  the journal says Running but the run has no live controller. #>
    param([string]$RunDirectory, [string]$RunStatus)
    $plan = Read-PASJson (Join-Path $RunDirectory 'plan.json')
    if (-not $plan) { return @() }
    $live = ($RunStatus -in @('Launching', 'Running'))
    $items = @(Get-PASValue $plan 'Items' @())
    $withDR = @($items | Where-Object { $_.Type -eq 'DRVault' }).Count -gt 0
    # Run order: AD, domain joins, then the other items in plan order.
    $entries = @()
    foreach ($item in @($items | Where-Object { $_.Type -eq 'AD' })) {
        $entries += @{
            Id = [string]$item.Id
            Type = 'AD'
            Targets = @([string]$item.Id)
        }
    }
    foreach ($join in @(Get-PASValue $plan 'DomainJoins' @())) {
        $entries += @{
            Id = [string]$join.Id
            Type = 'DomainJoin'
            Targets = @([string]$join.Id)
        }
    }
    foreach ($item in @($items | Where-Object { $_.Type -ne 'AD' })) {
        $targets = @([string]$item.Id)
        # With DR the Vault is installed in two phases per server, each with its own journal.
        if ($item.Type -eq 'Vault') {
            $targets = @('primary')
            if ($withDR) { $targets += 'primary_final' }
        }
        if ($item.Type -eq 'DRVault') { $targets = @('dr', 'dr_final') }
        $entries += @{ Id = [string]$item.Id; Type = [string]$item.Type; Targets = $targets }
    }
    foreach ($entry in $entries) {
        $statuses = @()
        $message = ''
        foreach ($target in $entry.Targets) {
            $state = $null
            try { $state = Read-PASJournal (Join-Path (Join-Path $RunDirectory $target) 'state.json') } catch {
                $state = @{
                    status = 'Unknown'
                    lastError = 'The journal of this target cannot be read'
                }
            }
            $status = [string](Get-PASValue $state 'status' '')
            $statuses += $status
            if (-not $message -and $status -and $status -ne 'Succeeded') { $message = [string](Get-PASValue $state 'lastError' '') }
        }
        $done = @($statuses | Where-Object { $_ -eq 'Succeeded' }).Count
        if ($statuses -contains 'Unknown') { $result = 'Unknown' }
        elseif ($statuses -contains 'Blocked') { $result = 'Blocked' }
        elseif ($statuses -contains 'Failed') { $result = 'Failed' }
        elseif ($statuses -contains 'Running') { $result = $(if ($live) { 'Running' } else { 'Interrupted' }) }
        elseif ($done -eq $statuses.Count) { $result = 'Succeeded' }
        elseif ($done -gt 0 -and $live) { $result = 'Running' }
        else { $result = 'Pending' }
        [pscustomobject]@{ Id = $entry.Id; Type = $entry.Type; Status = $result; Message = $message }
    }
}

function Get-PASDeploymentSnapshot {
    <# Status of a run for the desktop and the command line.
       Properties: RunId, Name, Status, CurrentComponent, Message, LastStep, StartedUtc, FinishedUtc,
       CompletedEvents, ErrorEvents, Components (Id, Type, Status, Message), Events, OperationallyVerified.
       Run status: Launching, Running, Succeeded, or one of the stopped states Failed, Unknown, Blocked,
       Interrupted, LaunchFailed, Abandoned. #>
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId, [string]$DataRoot = (Get-PASDataRoot), [int]$Tail = 150)
    $run = Get-PASRunRecord -RunId $RunId -DataRoot $DataRoot
    if (-not $run) { throw "Deployment run not found: $RunId" }
    $events = @(Get-PASDeploymentEvents -RunId $RunId -DataRoot $DataRoot -Tail $Tail)
    $latest = @($events | Where-Object { $_.Stage } | Select-Object -Last 1)
    $lastStep = ''
    if ($latest.Count) { $lastStep = [string]$latest[-1].Stage }
    return [pscustomobject]@{
        RunId = $RunId
        Name = [string]$run.name
        Status = [string]$run.status
        CurrentComponent = [string]$run.currentComponent
        Message = [string]$run.message
        LastStep = $lastStep
        StartedUtc = [string]$run.startedUtc
        FinishedUtc = [string]$run.finishedUtc
        CompletedEvents = @($events | Where-Object { $_.Event -eq 'TaskCompleted' }).Count
        ErrorEvents = @($events | Where-Object { $_.Status -eq 'Failed' }).Count
        Components = @(Get-PASRunComponents -RunDirectory (Get-PASRunDirectory $RunId $DataRoot) -RunStatus ([string]$run.status))
        Events = $events
        # A finished installer workflow does not prove that PAM works end to end (see Test-PASDeploymentHealth).
        OperationallyVerified = $false
    }
}
