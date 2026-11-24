# Simulator backend for demos, training and UI work. It contacts no server and installs nothing.
#
# Everything that only computes (media inventory and selection, configuration, validation, plan,
# stage catalog, credential requirements, project files) is the real PASeasyInstall module: this
# module imports it and passes those commands through unchanged. Only the run is simulated:
# Install-PASLab, Get-PASRun, Get-PASRunEvent, Resume-PASRun, Stop-PASRun, Export-PASDiagnostics,
# Test-PASPreflight and Test-PASHealth.
#
# A simulated run installs the servers at the same time, as the real installer does for a configuration with
# execution.mode Parallel (New-PASMockLaneTimeline); a Sequential configuration walks the plan one component
# after another. Every stage of the real stage catalog takes $env:PASUI_MOCK_STAGE_SECONDS seconds (default 1).
# The lab name selects the scenario:
#   name contains "fail"     the first install stage fails and the run ends Failed (Resume-PASRun finishes it)
#   name contains "unreach"  the server check reports one server that does not answer
#   name contains "warn"  reboot stages report a warning and continue
# Runs live in memory only and are gone when the process ends. Every runspace of the process sees the same
# runs: the window calls these commands from background runspaces.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Backend.Contract.ps1')
Import-Module (Get-PASUICoreModule) -ErrorAction Stop

# One table for the whole process, kept with the application domain.
$script:Runs = [AppDomain]::CurrentDomain.GetData('PASeasyInstall.Mock.Runs')
if ($null -eq $script:Runs) {
    $script:Runs = [hashtable]::Synchronized(@{})
    [AppDomain]::CurrentDomain.SetData('PASeasyInstall.Mock.Runs', $script:Runs)
}

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

function New-PASMockLaneTimeline {
    <# Timed events for a run that installs the servers at the same time, the way the real installer does with
       execution.mode Parallel (Private\Run\Lanes.ps1 of the module):
         - every server is a lane and works through its own steps one after another; the Vault and its DR Vault
           are one lane;
         - a server that is joined to a new domain starts when the domain controller is finished;
         - a step 'register' waits until the Vault lane is finished and, except for the first PVWA, until the
           first PVWA is registered; the registrations run one at a time. A step that has to wait says so
           (event VaultWaiting), as the real one does.
       Steps: @{Id; Type; Host; Address; Stage} in plan order. Done: 'id|stage' of steps finished before (resume).
       With -Fail the first installation step fails and the run ends there; with -FailType too, the last step
       of the first component of that type fails instead (lab name 'fail-PTA'). Returns @{ Events; End; Outcome }. #>
    param([object[]]$Steps = @(), [double]$Start, [bool]$Fail, [bool]$Warn, [string[]]$Joined = @(), [hashtable]$Done = @{}, [string]$FailType = '')
    $seconds = Get-PASMockStageSeconds
    $pending = @($Steps | Where-Object { -not $Done.ContainsKey([string]$_.Id + '|' + [string]$_.Stage) })
    $failKey = ''
    if ($Fail -and $pending.Count) {
        $failing = @($pending | Where-Object { $_.Stage -match 'install' })[0]
        if ($FailType) {
            $ofType = @($pending | Where-Object { [string]$_.Type -eq $FailType })
            $first = @($ofType | ForEach-Object { [string]$_.Id } | Select-Object -First 1)
            $failing = @($ofType | Where-Object { [string]$_.Id -eq [string]$first[0] }) | Select-Object -Last 1
        }
        if (-not $failing) {
            $failing = $pending[[int][Math]::Floor($pending.Count / 2)]
        }
        $failKey = [string]$failing.Id + '|' + [string]$failing.Stage
    }
    # The lanes, in plan order.
    $lanes = [ordered]@{}
    foreach ($step in $pending) {
        $name = [string]$step.Host
        if ([string]$step.Type -in @('Vault', 'DRVault')) {
            $name = 'vault'
        }
        if (-not $lanes.Contains($name)) {
            $lanes[$name] = @{ Steps = New-Object System.Collections.ArrayList; Index = 0; Time = $Start; Joined = ($Joined -contains [string]$step.Host) }
        }
        [void]$lanes[$name].Steps.Add($step)
    }
    $forestPending = @($pending | Where-Object { [string]$_.Type -eq 'AD' }).Count
    $vaultPending = @($pending | Where-Object { [string]$_.Type -in @('Vault', 'DRVault') }).Count
    $firstPvwa = [string](@($Steps | Where-Object { [string]$_.Type -eq 'PVWA' } | ForEach-Object { [string]$_.Id })[0])
    $pvwaRegistered = $null
    if (-not $firstPvwa -or -not @($pending | Where-Object { [string]$_.Id -eq $firstPvwa -and [string]$_.Stage -eq 'register' }).Count) {
        $pvwaRegistered = $Start
    }
    $forestEnd = $null
    if (-not $forestPending) {
        $forestEnd = $Start
    }
    $vaultEnd = $null
    if (-not $vaultPending) {
        $vaultEnd = $Start
    }
    $vaultFree = $Start
    $events = New-Object System.Collections.ArrayList
    $order = 0
    $failedAt = $null
    while ($null -eq $failedAt) {
        # The lane whose next step can start first.
        $best = $null
        $bestAt = 0.0
        foreach ($name in @($lanes.Keys)) {
            $lane = $lanes[$name]
            if ($lane.Index -ge $lane.Steps.Count) {
                continue
            }
            $step = $lane.Steps[$lane.Index]
            $at = [double]$lane.Time
            if ($lane.Joined -and $lane.Index -eq 0) {
                if ($null -eq $forestEnd) {
                    continue
                }
                $at = [Math]::Max($at, [double]$forestEnd)
            }
            $signsIn = ([string]$step.Stage -eq 'register' -and [string]$step.Type -notin @('Vault', 'DRVault', 'AD'))
            if ($signsIn) {
                if ($null -eq $vaultEnd) {
                    continue
                }
                if ([string]$step.Id -ne $firstPvwa -and $null -eq $pvwaRegistered) {
                    continue
                }
                $at = [Math]::Max($at, [double]$vaultEnd)
                if ([string]$step.Id -ne $firstPvwa) {
                    $at = [Math]::Max($at, [double]$pvwaRegistered)
                }
                $at = [Math]::Max($at, $vaultFree)
            }
            if ($null -eq $best -or $at -lt $bestAt) {
                $best = $name
                $bestAt = $at
            }
        }
        if ($null -eq $best) {
            break
        }
        $lane = $lanes[$best]
        $step = $lane.Steps[$lane.Index]
        $signsIn = ([string]$step.Stage -eq 'register' -and [string]$step.Type -notin @('Vault', 'DRVault', 'AD'))
        if ($signsIn -and $bestAt -gt [double]$lane.Time + 0.0001) {
            [void]$events.Add(@{ At = [double]$lane.Time; Order = $order; Component = $step.Id; Stage = $step.Stage; Event = 'VaultWaiting'; Level = 'Information'
                    Message = 'Waiting for the Vault: this step signs in to the Vault and runs when the Vault is installed and no other server is signing in'
                })
            $order++
        }
        [void]$events.Add(@{ At = $bestAt; Order = $order; Component = $step.Id; Stage = $step.Stage; Event = 'TaskStarted'; Level = 'Information'
                Message = "Running $($step.Stage) on $($step.Host) ($($step.Address))"
            })
        $order++
        $time = $bestAt + $seconds
        if (([string]$step.Id + '|' + [string]$step.Stage) -eq $failKey) {
            [void]$events.Add(@{ At = $time; Order = $order; Component = $step.Id; Stage = $step.Stage; Event = 'TaskFailed'; Level = 'Error'
                    Message = 'Simulated failure: the installer exited with code 1603.'
                })
            $failedAt = $time
            break
        }
        if ($Warn -and $step.Stage -match 'reboot') {
            [void]$events.Add(@{ At = $time; Order = $order; Component = $step.Id; Stage = $step.Stage; Event = 'RebootWarning'; Level = 'Warning'
                    Message = 'The server is restarting; waiting for it to come back.'
                })
            $order++
            $time += $seconds
        }
        [void]$events.Add(@{ At = $time; Order = $order; Component = $step.Id; Stage = $step.Stage; Event = 'TaskCompleted'; Level = 'Information'
                Message = "$($step.Stage) completed"
            })
        $order++
        $lane.Time = $time
        $lane.Index++
        if ($signsIn) {
            $vaultFree = $time
            if ([string]$step.Id -eq $firstPvwa) {
                $pvwaRegistered = $time
            }
        }
        if ($lane.Index -ge $lane.Steps.Count) {
            if ($best -eq 'vault') {
                $vaultEnd = $time
            }
            if (@($lane.Steps | Where-Object { [string]$_.Type -eq 'AD' }).Count) {
                $forestEnd = $time
            }
        }
    }
    $sorted = @($events | Sort-Object -Property @{ Expression = { [double]$_.At } }, @{ Expression = { [int]$_.Order } })
    $outcome = 'Succeeded'
    $end = $Start
    if ($null -ne $failedAt) {
        # The run stops with the failure: what the other servers would have done later does not happen.
        $outcome = 'Failed'
        $sorted = @($sorted | Where-Object { [double]$_.At -le $failedAt })
        $end = $failedAt
    } elseif ($sorted.Count) {
        $end = [double]$sorted[-1].At
    }
    $result = New-Object System.Collections.ArrayList
    foreach ($entry in $sorted) {
        [void]$result.Add($entry)
    }
    return @{ Events = $result; End = $end; Outcome = $outcome }
}

function Get-PASMockJoinedHosts {
    # The servers a configuration joins to a domain the lab creates (they wait for the domain controller).
    param($Configuration)
    $directory = $Configuration['activeDirectory']
    if (-not $directory -or [string]$directory['mode'] -eq 'None') {
        return @()
    }
    return @($directory['join'] | ForEach-Object { [string]$_ })
}

function Test-PASMockParallel {
    # Does this configuration install the servers at the same time (the default of a new lab)?
    param($Configuration)
    $execution = $Configuration['execution']
    return ($execution -and [string]$execution['mode'] -eq 'Parallel')
}

function Get-PASMockRun {
    param([string]$RunId)
    if (-not $script:Runs.ContainsKey($RunId)) {
        throw "Run not found: $RunId (simulated runs exist only in the process that started them)"
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
        } elseif ($Run.Parallel -and $RunStatus -eq 'Failed') {
            # Servers installed at the same time: another server failed and this one stopped before its next
            # step. The real installer shows such a component as not finished, without an error of its own.
            $status = 'Pending'
            $message = 'Not finished: the installation stopped because another server failed.'
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
        LeftOut = @($run.LeftOut | Where-Object { $_ })
        Components = @(Get-PASMockComponents -Run $run -Events $events -RunStatus $clock.Status)
        Events = @($events | Select-Object -Last $Tail)
    }
}

function Install-PASLab {
    <# Simulated: validates with the real module, checks that every required credential and secret
       was handed over, then starts a timed fake run. Returns the run id. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)]$Configuration, [hashtable]$CredentialMap = @{}, [hashtable]$SecretMap = @{}, [securestring]$LabPassword)
    $checked = Test-PASLabConfiguration -Configuration $Configuration -CheckMedia
    if (-not $checked.Valid) {
        throw ('Configuration invalid: ' + ($checked.Issues -join '; '))
    }
    $cfg = $checked.Configuration
    foreach ($requirement in @(Get-PASCredentialRequirement -Configuration $cfg)) {
        if ($LabPassword) {
            # One lab password stands for every account and Vault password.
            continue
        }
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
                Type = [string]$item.Type
                Host = [string]$item.Host
                Address = [string]$item.Address
                Stage = $stage
            }
        }
    }
    $parallel = Test-PASMockParallel $cfg
    $joined = @(Get-PASMockJoinedHosts $cfg)
    if ($parallel) {
        $failType = ''
        if ($name -match '(?i)fail-(PVWA|CPM|PSMP|PSM|HTML5GW|PTA)') {
            $failType = $Matches[1].ToUpperInvariant()
        }
        $timeline = New-PASMockLaneTimeline -Steps $steps -Start 0.3 -Fail ($name -match '(?i)fail') -Warn ($name -match '(?i)warn') -Joined $joined -FailType $failType
    } else {
        $timeline = New-PASMockTimeline -Steps $steps -Start 0.3 -Fail ($name -match '(?i)fail') -Warn ($name -match '(?i)warn')
    }
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
    # As a real run does, the simulated one keeps its configuration (no password is in it), so that the
    # window can ask for the accounts of an installation it did not start.
    $runDirectory = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'PASeasyInstall-Mock') $runId
    $null = New-Item -ItemType Directory -Path $runDirectory -Force
    $null = Export-PASLabConfiguration -Configuration $cfg -Path (Join-Path $runDirectory 'config.json') -Force
    $script:Runs[$runId] = @{
        Name = $name
        LeftOut = @()
        StartUtc = [datetime]::UtcNow
        Items = $items
        Steps = $steps
        Timeline = $events
        End = $timeline.End
        Outcome = $timeline.Outcome
        StoppedAt = $null
        RunDirectory = $runDirectory
        Parallel = $parallel
        Joined = $joined
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
    <# Simulated: a running run ends now with status Abandoned (the real command needs -Force for that). #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$RunId, [switch]$Force)
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
    param([Parameter(Mandatory)][string]$RunId, $RetryStep, [string[]]$LeaveOut = @(), [hashtable]$CredentialMap, [hashtable]$SecretMap, [securestring]$LabPassword)
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
    # Left out (-LeaveOut): its steps are not run again, and the run finishes without it.
    $run.LeftOut = @(@($run.LeftOut) + @($LeaveOut) | Where-Object { $_ } | Select-Object -Unique)
    $steps = @($run.Steps | Where-Object { $run.LeftOut -notcontains $_.Id })
    $remaining = @($steps | Where-Object { -not $completed.ContainsKey($_.Id + '|' + $_.Stage) })
    $now = ([datetime]::UtcNow - $run.StartUtc).TotalSeconds
    [void]$kept.Add(@{ At = $now; Component = 'controller'; Stage = ''; Event = 'RunResumed'; Level = 'Information'
            Message = 'Simulated run resumed'
        })
    if ($run.Parallel) {
        $timeline = New-PASMockLaneTimeline -Steps $steps -Start ($now + 0.3) -Fail $false -Warn $false -Joined @($run.Joined) -Done $completed
    } else {
        $timeline = New-PASMockTimeline -Steps $remaining -Start ($now + 0.3) -Fail $false -Warn $false
    }
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
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$Path, [switch]$Force)
    $snapshot = Get-PASMockSnapshot -RunId $RunId -Tail 5000
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $full) {
        if (-not $Force) {
            throw "File already exists: $full"
        }
        Remove-Item -LiteralPath $full -Force
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

function Test-PASPreflight {
    <# Simulated: one "answers" row per server of the plan. A lab whose name contains "unreach" reports
       one server that does not answer. Contacts nothing. #>
    [CmdletBinding()]
    param($Configuration, [hashtable]$CredentialMap = @{}, [securestring]$LabPassword, [switch]$ConnectivityOnly)
    $plan = Get-PASLabPlan -Configuration $Configuration
    $seen = @{}
    $rows = New-Object System.Collections.ArrayList
    $bad = ([string]$Configuration['name'] -match '(?i)unreach')
    foreach ($item in @($plan.Items)) {
        $address = [string]$item.Address
        if ($seen.ContainsKey($address)) {
            continue
        }
        $seen[$address] = $true
        $passed = $true
        $detail = 'Simulated: the server answers'
        if ($bad -and $seen.Count -eq 1) {
            $passed = $false
            $detail = 'Simulated: no answer on the management port'
        }
        [void]$rows.Add([pscustomobject]@{ Server = [string]$item.Host; Address = $address; Check = 'TCP port'; Passed = $passed; Detail = $detail })
        if ($ConnectivityOnly -or -not $passed) {
            continue
        }
        [void]$rows.Add([pscustomobject]@{ Server = [string]$item.Host; Address = $address; Check = 'Sign-in'; Passed = $true; Detail = 'Simulated: signed in' })
        [void]$rows.Add([pscustomobject]@{ Server = [string]$item.Host; Address = $address; Check = 'Free disk space'; Passed = $true; Detail = 'Simulated: 80 GB free' })
    }
    return @($rows)
}

function Test-PASHealth {
    <# Simulated: every component of the configuration is reported as connected. #>
    [CmdletBinding()]
    param([string]$Path, $Configuration, [pscredential]$VaultCredential, [pscredential]$DRCredential)
    $rows = New-Object System.Collections.ArrayList
    if ($Configuration) {
        foreach ($item in @((Get-PASLabPlan -Configuration $Configuration).Items)) {
            if ([string]$item.Type -in @('Vault', 'DRVault', 'AD')) {
                continue
            }
            [void]$rows.Add([pscustomobject]@{ Component = [string]$item.Type; User = ([string]$item.Type + 'App_' + [string]$item.Name)
                    Address = [string]$item.Address; LoggedOn = $true; Version = 'simulated' })
        }
    }
    return [pscustomobject]@{
        Healthy = $true
        Message = 'Simulated: all components are connected to the Vault'
        Issues = @()
        Components = @($rows)
    }
}

# The whole contract is exported: the simulated commands defined above, and the commands of
# the real module imported above, passed through as they are.
Export-ModuleMember -Function @($script:PASUIBackendContract.Keys)
