# Simulator backend for demos, training and UI work. It contacts no server and installs nothing.
#
# Everything that only computes (media inventory and selection, configuration, validation, plan,
# stage catalog, credential requirements, project files) is the real PASeasyInstall module: this
# module imports it and passes those commands through unchanged. Only the run is simulated:
# Install-PASLab, Get-PASRun, Get-PASRunEvent, Resume-PASRun, Stop-PASRun and Export-PASDiagnostics.
#
# A simulated run walks the plan one component after another; every stage of the real stage catalog
# takes $env:PASUI_MOCK_STAGE_SECONDS seconds (default 1). The lab name selects the scenario:
#   name contains "fail"  the first install stage fails and the run ends Failed (Resume-PASRun finishes it)
#   name contains "warn"  reboot stages report a warning and continue
# Runs live in memory only and are gone when the process ends.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Backend.Contract.ps1')
Import-Module (Get-PASUICoreModule) -ErrorAction Stop

$script:Runs = @{}

function Get-PASMockStageSeconds {
    if ($env:PASUI_MOCK_STAGE_SECONDS) {
        return [double]$env:PASUI_MOCK_STAGE_SECONDS
    }
    return 1.0
}

function Get-PASMockStages {
    # Stage names of one plan item type, in run order, from the real catalog.
    param([string]$Type)
    $component = $Type
    if ($Type -eq 'DRVault') {
        $component = 'DR'
    }
    return @(Get-PASStageCatalog -Component $component | Sort-Object -Property Order | ForEach-Object { [string]$_.Stage })
}

function New-PASMockTimeline {
    # Timed events for a list of steps (@{Id; Host; Address; Stage}), one after another from $Start.
    # Returns @{ Events; End; Outcome }.
    param([object[]]$Steps = @(), [double]$Start, [bool]$Fail, [bool]$Warn)
    $seconds = Get-PASMockStageSeconds
    $failIndex = -1
    if ($Fail -and $Steps.Count) {
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            if ($Steps[$i].Stage -match 'install') {
                $failIndex = $i
                break
            }
        }
        if ($failIndex -lt 0) {
            $failIndex = [int][Math]::Floor($Steps.Count / 2)
        }
    }
    $events = New-Object System.Collections.ArrayList
    $time = $Start
    $outcome = 'Succeeded'
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        [void]$events.Add(@{ At = $time
                Component = $step.Id
                Stage = $step.Stage
                Event = 'TaskStarted'
                Level = 'Information'
                Message = "Running $($step.Stage) on $($step.Host) ($($step.Address))"
            })
        $time += $seconds
        if ($i -eq $failIndex) {
            [void]$events.Add(@{ At = $time
                    Component = $step.Id
                    Stage = $step.Stage
                    Event = 'TaskFailed'
                    Level = 'Error'
                    Message = 'Simulated failure: the installer exited with code 1603.'
                })
            $outcome = 'Failed'
            break
        }
        if ($Warn -and $step.Stage -match 'reboot') {
            [void]$events.Add(@{ At = $time
                    Component = $step.Id
                    Stage = $step.Stage
                    Event = 'RebootWarning'
                    Level = 'Warning'
                    Message = 'The server is restarting; waiting for it to come back.'
                })
            $time += $seconds
        }
        [void]$events.Add(@{ At = $time
                Component = $step.Id
                Stage = $step.Stage
                Event = 'TaskCompleted'
                Level = 'Information'
                Message = "$($step.Stage) completed"
            })
    }
    return @{ Events = $events; End = $time; Outcome = $outcome }
}

function Get-PASMockRun {
    param([string]$RunId)
    if (-not $script:Runs.ContainsKey($RunId)) {
        throw "Run not found: $RunId (simulated runs exist only in the window that started them)"
    }
    return $script:Runs[$RunId]
}

function Get-PASMockClock {
    # Where a run stands now: the timeline position reached, and the run status.
    param($Run)
    $elapsed = ([datetime]::UtcNow - $Run.StartUtc).TotalSeconds
    if ($null -ne $Run.StoppedAt -and $elapsed -ge $Run.StoppedAt) {
        return @{ Position = [double]$Run.StoppedAt; Status = 'Abandoned'; Finished = $true }
    }
    if ($elapsed -ge $Run.End) {
        return @{ Position = [double]$Run.End; Status = [string]$Run.Outcome; Finished = $true }
    }
    return @{ Position = $elapsed; Status = 'Running'; Finished = $false }
}

function Get-PASMockEvents {
    # Every event of the run up to a timeline position, in the shape of the real event log.
    param($Run, [string]$RunId, [double]$Position)
    $sequence = 0
    foreach ($entry in $Run.Timeline) {
        if ($entry.At -gt $Position) {
            continue
        }
        $status = 'Info'
        switch -Regex ([string]$entry.Event) {
            'Failed' {
                $status = 'Failed'
                break
            }
            'Warning' {
                $status = 'Warning'
                break
            }
            'Completed' {
                $status = 'Complete'
                break
            }
            'Started' {
                $status = 'Running'
                break
            }
        }
        $source = 'Engine'
        if (-not $entry.Stage) {
            $source = 'Controller'
        }
        [pscustomobject]@{
            TimestampUtc = $Run.StartUtc.AddSeconds($entry.At).ToString('o')
            RunId = $RunId
            Component = [string]$entry.Component
            Stage = [string]$entry.Stage
            Event = [string]$entry.Event
            Level = [string]$entry.Level
            Status = $status
            Source = $source
            Message = [string]$entry.Message
            Sequence = $sequence
        }
        $sequence++
    }
}

function Get-PASMockComponents {
    # One entry per plan item: Id, Type, Status, Message (the shape of Get-PASRun's Components).
    param($Run, [object[]]$Events = @(), [string]$RunStatus)
    foreach ($item in $Run.Items) {
        $last = @{}
        $message = ''
        foreach ($evt in @($Events | Where-Object { $_.Component -eq $item.Id -and $_.Stage })) {
            $last[$evt.Stage] = $evt.Status
            if ($evt.Status -eq 'Failed') {
                $message = $evt.Message
            }
        }
        $done = @($last.Values | Where-Object { $_ -eq 'Complete' }).Count
        if (@($last.Values | Where-Object { $_ -eq 'Failed' }).Count) {
            $status = 'Failed'
        } elseif ($item.StageCount -and $done -eq $item.StageCount) {
            $status = 'Succeeded'
            $message = ''
        } elseif (-not $last.Count) {
            $status = 'Pending'
        } elseif ($RunStatus -eq 'Running') {
            $status = 'Running'
            $message = ''
        } else {
            $status = 'Interrupted'
            $message = 'The run was stopped while this component was being installed.'
        }
        [pscustomobject]@{ Id = $item.Id; Type = $item.Type; Status = $status; Message = $message }
    }
}

function Get-PASMockSnapshot {
    param([string]$RunId, [int]$Tail = 150)
    $run = Get-PASMockRun $RunId
    $clock = Get-PASMockClock $run
    $events = @(Get-PASMockEvents -Run $run -RunId $RunId -Position $clock.Position)
    $staged = @($events | Where-Object { $_.Stage })
    $currentComponent = ''
    $lastStep = ''
    if ($staged.Count) {
        $currentComponent = $staged[-1].Component
        $lastStep = $staged[-1].Stage
    }
    $finishedUtc = ''
    $message = 'Simulated run in progress'
    if ($clock.Finished) {
        $finishedUtc = $run.StartUtc.AddSeconds($clock.Position).ToString('o')
        $message = 'Simulated run ended: ' + $clock.Status
    }
    return [pscustomobject]@{
        RunId = $RunId
        Name = [string]$run.Name
        Status = [string]$clock.Status
        CurrentComponent = $currentComponent
        Message = $message
        LastStep = $lastStep
        StartedUtc = $run.StartUtc.ToString('o')
        FinishedUtc = $finishedUtc
        CompletedEvents = @($events | Where-Object { $_.Event -eq 'TaskCompleted' }).Count
        ErrorEvents = @($events | Where-Object { $_.Status -eq 'Failed' }).Count
        RunDirectory = [string]$run.RunDirectory
        Components = @(Get-PASMockComponents -Run $run -Events $events -RunStatus $clock.Status)
        Events = @($events | Select-Object -Last $Tail)
    }
}

function Install-PASLab {
    <# Simulated: validates with the real module, checks that every required credential and secret
       was handed over, then starts a timed fake run. Returns the run id. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)]$Configuration, [hashtable]$CredentialMap = @{}, [hashtable]$SecretMap = @{})
    $checked = Test-PASLabConfiguration -Configuration $Configuration -CheckMedia
    if (-not $checked.Valid) {
        throw ('Configuration invalid: ' + ($checked.Issues -join '; '))
    }
    $cfg = $checked.Configuration
    foreach ($requirement in @(Get-PASCredentialRequirement -Configuration $cfg)) {
        if ($requirement.Kind -eq 'Credential') {
            $given = $CredentialMap.ContainsKey([string]$requirement.Key)
            if (-not $given -and $requirement.HostId) {
                $given = $CredentialMap.ContainsKey([string]$requirement.HostId)
            }
            if (-not $given) {
                throw "Missing credential: $($requirement.Label)"
            }
        } elseif (-not $SecretMap.ContainsKey([string]$requirement.Key)) {
            throw "Missing secret: $($requirement.Label)"
        }
    }
    $name = [string]$cfg['name']
    if (-not $PSCmdlet.ShouldProcess($name, 'Start a simulated installation')) {
        return
    }
    $plan = Get-PASLabPlan -Configuration $cfg
    $items = @()
    $steps = @()
    foreach ($item in @($plan.Items)) {
        $stages = @(Get-PASMockStages ([string]$item.Type))
        $items += @{ Id = [string]$item.Id; Type = [string]$item.Type; StageCount = $stages.Count }
        foreach ($stage in $stages) {
            $steps += @{
                Id = [string]$item.Id
                Host = [string]$item.Host
                Address = [string]$item.Address
                Stage = $stage
            }
        }
    }
    $timeline = New-PASMockTimeline -Steps $steps -Start 0.3 -Fail ($name -match '(?i)fail') -Warn ($name -match '(?i)warn')
    $events = New-Object System.Collections.ArrayList
    [void]$events.Add(@{ At = 0.0
            Component = 'controller'
            Stage = ''
            Event = 'ControllerLaunched'
            Level = 'Information'
            Message = 'Simulated controller started (no servers are contacted)'
        })
    $events.AddRange($timeline.Events)
    $runId = [guid]::NewGuid().ToString('N')
    $script:Runs[$runId] = @{
        Name = $name
        StartUtc = [datetime]::UtcNow
        Items = $items
        Steps = $steps
        Timeline = $events
        End = $timeline.End
        Outcome = $timeline.Outcome
        StoppedAt = $null
        RunDirectory = (Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'PASeasyInstall-Mock') $runId)
    }
    return $runId
}

function Get-PASRun {
    <# Simulated: the snapshot of one run, or without -RunId the list of runs, newest first. #>
    [CmdletBinding()]
    param([string]$RunId, [int]$Tail = 150)
    if ($RunId) {
        return (Get-PASMockSnapshot -RunId $RunId -Tail $Tail)
    }
    $list = foreach ($id in @($script:Runs.Keys)) {
        $snapshot = Get-PASMockSnapshot -RunId $id -Tail 1
        [pscustomobject]@{ RunId = $id
            Name = $snapshot.Name
            Status = $snapshot.Status
            StartedUtc = $snapshot.StartedUtc
            FinishedUtc = $snapshot.FinishedUtc
            Message = $snapshot.Message
        }
    }
    return @($list | Sort-Object -Property StartedUtc -Descending)
}

function Get-PASRunEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [int]$Tail = 150)
    return @((Get-PASMockSnapshot -RunId $RunId -Tail $Tail).Events)
}

function Stop-PASRun {
    <# Simulated: a running run ends now with status Abandoned. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$RunId)
    $run = Get-PASMockRun $RunId
    $clock = Get-PASMockClock $run
    if ($clock.Finished) {
        return
    }
    if ($PSCmdlet.ShouldProcess($RunId, 'Stop the simulated run')) {
        [void]$run.Timeline.Add(@{ At = $clock.Position
                Component = 'controller'
                Stage = ''
                Event = 'RunStopped'
                Level = 'Warning'
                Message = 'Simulated run stopped by the operator'
            })
        $run.StoppedAt = $clock.Position
    }
}

function Resume-PASRun {
    <# Simulated: a run that failed or was stopped continues with the stages that did not complete,
       this time without the simulated failure. Returns the run id. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$RunId, $RetryStep, [hashtable]$CredentialMap, [hashtable]$SecretMap)
    $run = Get-PASMockRun $RunId
    $clock = Get-PASMockClock $run
    if (-not $clock.Finished -or $clock.Status -eq 'Succeeded') {
        throw "Run $RunId is $($clock.Status); there is nothing to resume."
    }
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Resume the simulated run')) {
        return
    }
    $kept = New-Object System.Collections.ArrayList
    $completed = @{}
    foreach ($entry in $run.Timeline) {
        if ($entry.At -gt $clock.Position) {
            continue
        }
        [void]$kept.Add($entry)
        if ($entry.Event -eq 'TaskCompleted') {
            $completed[$entry.Component + '|' + $entry.Stage] = $true
        }
    }
    $remaining = @($run.Steps | Where-Object { -not $completed.ContainsKey($_.Id + '|' + $_.Stage) })
    $now = ([datetime]::UtcNow - $run.StartUtc).TotalSeconds
    [void]$kept.Add(@{ At = $now; Component = 'controller'; Stage = ''; Event = 'RunResumed'; Level = 'Information'
            Message = 'Simulated run resumed'
        })
    $timeline = New-PASMockTimeline -Steps $remaining -Start ($now + 0.3) -Fail $false -Warn $false
    $kept.AddRange($timeline.Events)
    $run.Timeline = $kept
    $run.End = $timeline.End
    $run.Outcome = 'Succeeded'
    $run.StoppedAt = $null
    return $RunId
}

function Export-PASDiagnostics {
    <# Simulated: writes a ZIP that holds the run snapshot as run.json. Returns the full path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$Path)
    $snapshot = Get-PASMockSnapshot -RunId $RunId -Tail 5000
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $full) {
        throw "File already exists: $full"
    }
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $writer = New-Object System.IO.StreamWriter($zip.CreateEntry('run.json').Open())
            try {
                $writer.Write(($snapshot | ConvertTo-Json -Depth 6))
            } finally {
                $writer.Dispose()
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    return $full
}

# The whole contract is exported: the six simulated commands defined above, and the commands of
# the real module imported above, passed through as they are.
Export-ModuleMember -Function @($script:PASUIBackendContract.Keys)
