# A parallel run (execution.mode = Parallel): the servers are installed at the same time.
#
#   Lane    the work of one server, in plan order, as in a sequential run. The lanes run side by side, each in
#           its own PowerShell runspace of the controller process with its own copy of this module (so the
#           remoting sessions and the approved media list of one lane are not shared with another).
#           The Vault and its DR Vault are one lane; the new forest is one lane.
#   Signal  a wait handle that is set once and stays set:
#             Domain          the new forest is installed (set from the start when the run creates none)
#             Vault           the Vault sequence is finished (set from the start when the run installs none)
#             PvwaRegistered  the first PVWA finished its step 'register'
#             Registered:<id> PVWA or CPM <id> finished its step 'register'
#             Cert:<id>       PVWA <id> has its HTTPS certificate (its first step, 'certificate')
#             Done:<id>       PVWA <id> is installed and verified
#             Cancel          a lane failed: lanes that wait give up, no lane starts another component
#   What waits for what (see Docs\PARALLEL.md):
#             a joined server          Domain, before its join
#             a component that trusts
#             the PVWA certificate     Cert of every PVWA, before it starts (CPM, HTML5 Gateway, PTA)
#             a step that signs in
#             to the Vault             Vault; every component except the first PVWA also PvwaRegistered;
#                                      everything except PVWA and CPM also Registered of every CPM
#                                      (the vendor's order: PVWA, CPM, then the rest); PTA waits for Done of
#                                      every PVWA
#           One Vault sign-in at a time is the Vault lock that every such step takes (Engine\Locks.ps1).
# What follows the lanes stays in order in the controller: gateway registration, PTA trust, GPOs.

function Get-PASRunLanes {
    <# The lanes of a configuration, in the order they are started. Each lane:
         Name        'ad', 'vault' or the id of the server
         Kind        AD, Vault or Server
         Join        $true when the server is joined to the domain before its components
         Components  ids of the components this lane installs, in plan order (AD and Vault lanes: their own) #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][object[]]$PlanItems)
    $lanes = New-Object System.Collections.ArrayList
    $components = @($Config.components | Where-Object { $null -ne $_ })
    $joined = @()
    if ([string]$Config.activeDirectory.mode -ne 'None') {
        $joined = @($Config.activeDirectory.join | ForEach-Object { [string]$_ })
    }
    $forest = @($components | Where-Object { $_.type -eq 'AD' })
    if ($forest.Count) {
        [void]$lanes.Add(@{ Name = 'ad'; Kind = 'AD'; Join = $false; Components = @([string]$forest[0].id) })
    }
    $vaultParts = @($components | Where-Object { $_.type -in @('Vault', 'DRVault') })
    $hasVault = @($vaultParts | Where-Object { $_.type -eq 'Vault' }).Count -gt 0
    # Servers that already have a lane of their own: anything else on them is installed after that lane's work.
    $laneOfHost = @{}
    if ($forest.Count) {
        $laneOfHost[[string]$forest[0].host] = 'ad'
    }
    if ($hasVault) {
        [void]$lanes.Add(@{ Name = 'vault'; Kind = 'Vault'; Join = $false; Components = @($vaultParts | ForEach-Object { [string]$_.id }) })
        foreach ($part in $vaultParts) {
            $laneOfHost[[string]$part.host] = 'vault'
        }
    }
    foreach ($item in @($PlanItems | Where-Object { $_.Type -notin @('Vault', 'DRVault', 'AD') })) {
        $component = @($components | Where-Object { $_.id -eq $item.Id })[0]
        $hostId = [string]$component.host
        if (-not $laneOfHost.ContainsKey($hostId)) {
            $laneOfHost[$hostId] = $hostId
            [void]$lanes.Add(@{ Name = $hostId; Kind = 'Server'; Join = ($joined -contains $hostId); Components = @() })
        }
        $lane = @($lanes | Where-Object { $_.Name -eq $laneOfHost[$hostId] })[0]
        if ($lane.Kind -eq 'Server') {
            $lane.Components = @($lane.Components) + @([string]$component.id)
        } else {
            # A component on the Vault server or on the domain controller: after that lane's own work.
            $lane.After = @(Get-PASValue $lane 'After' @()) + @([string]$component.id)
        }
    }
    # A joined server without a component still has to be joined.
    foreach ($hostId in $joined) {
        if (-not $laneOfHost.ContainsKey($hostId)) {
            $laneOfHost[$hostId] = $hostId
            [void]$lanes.Add(@{ Name = $hostId; Kind = 'Server'; Join = $true; Components = @() })
        }
    }
    return @($lanes.ToArray())
}

function Get-PASLaneComponentGate {
    <# What one component waits for and what it announces.
         StartAfter   names of the signals it waits for before it starts
         VaultAfter   names of the signals its Vault steps wait for
         StepSignals  @{ <step id> = names of the signals that step sets }
         DoneSignals  names of the signals set when the component is installed and verified
       The registrations follow the vendor's order: the first PVWA, the other PVWAs, every CPM, then the rest. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$Component)
    $id = [string]$Component.id
    $type = [string]$Component.type
    $pvwas = @($Config.components | Where-Object { $_.type -eq 'PVWA' } | ForEach-Object { [string]$_.id })
    $cpms = @($Config.components | Where-Object { $_.type -eq 'CPM' } | ForEach-Object { [string]$_.id })
    $gate = @{ StartAfter = @(); VaultAfter = @('Vault'); StepSignals = @{}; DoneSignals = @() }
    if ([string](Get-PASValue (Get-PASValue $Component 'options' $null) 'pvwaTrustFrom' '')) {
        $gate.StartAfter = @($pvwas | ForEach-Object { 'Cert:' + $_ })
    }
    if ($type -eq 'PVWA') {
        $gate.StepSignals['certificate'] = @('Cert:' + $id)
        $gate.StepSignals['register'] = @('Registered:' + $id)
        $gate.DoneSignals = @(('Cert:' + $id), ('Registered:' + $id), ('Done:' + $id))
        if ($pvwas.Count -and $pvwas[0] -eq $id) {
            $gate.StepSignals['register'] += 'PvwaRegistered'
            $gate.DoneSignals += 'PvwaRegistered'
        } else {
            $gate.VaultAfter += 'PvwaRegistered'
        }
    } elseif ($type -eq 'CPM') {
        # The CPM registration looks at the certificate of every PVWA that is registered in the Vault.
        $gate.VaultAfter += @($pvwas | ForEach-Object { 'Registered:' + $_ })
        $gate.StepSignals['register'] = @('Registered:' + $id)
        $gate.DoneSignals = @('Registered:' + $id)
    } elseif ($type -eq 'PTA') {
        # The PTA configuration names the PVWA and signs in through it: the PVWA servers must be finished.
        $gate.VaultAfter += @($pvwas | ForEach-Object { 'Done:' + $_ })
        $gate.VaultAfter += @($cpms | ForEach-Object { 'Registered:' + $_ })
    } else {
        if ($pvwas.Count) {
            $gate.VaultAfter += 'PvwaRegistered'
        }
        $gate.VaultAfter += @($cpms | ForEach-Object { 'Registered:' + $_ })
    }
    return $gate
}

function New-PASLaneSignals {
    # The signals of one run. Those nothing in this run will ever set are set from the start.
    param([Parameter(Mandatory)]$Config)
    $signals = @{}
    foreach ($name in @('Domain', 'Vault', 'PvwaRegistered', 'Cancel')) {
        $signals[$name] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
    }
    $components = @($Config.components | Where-Object { $null -ne $_ })
    if (-not @($components | Where-Object { $_.type -eq 'AD' }).Count) {
        [void]$signals.Domain.Set()
    }
    if (-not @($components | Where-Object { $_.type -eq 'Vault' }).Count) {
        [void]$signals.Vault.Set()
    }
    $pvwas = @($components | Where-Object { $_.type -eq 'PVWA' })
    if (-not $pvwas.Count) {
        [void]$signals.PvwaRegistered.Set()
    }
    foreach ($pvwa in $pvwas) {
        $signals['Registered:' + [string]$pvwa.id] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
        $signals['Cert:' + [string]$pvwa.id] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
        $signals['Done:' + [string]$pvwa.id] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
    }
    foreach ($cpm in @($components | Where-Object { $_.type -eq 'CPM' })) {
        $signals['Registered:' + [string]$cpm.id] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
    }
    return $signals
}

function Wait-PASLaneSignal {
    # Waits until the named signals are set. Throws PASLaneStopped when the run is stopped meanwhile.
    param([hashtable]$Signals, [string[]]$Names)
    $handles = @($Names | Where-Object { $_ -and $Signals.ContainsKey($_) } | ForEach-Object { $Signals[$_] })
    [void](Wait-PASVaultGate @{ Wait = $handles; Cancel = $Signals.Cancel })
}

function Invoke-PASLane {
    <# The work of one lane. Runs inside the lane's own runspace (see Invoke-PASRunLanes), with its own copy of
       the run context: its own configuration object, credential and secret tables.
       Returns @{ Lane; Error; Target; Component; Stopped }: Error is '' when the lane finished. #>
    param([Parameter(Mandatory)][hashtable]$Lane, [Parameter(Mandatory)][hashtable]$Shared)
    $result = @{ Lane = [string]$Lane.Name; Error = ''; Target = ''; Component = ''; Stopped = $false }
    $run = $null
    try {
        $signals = $Shared.Signals
        $config = Read-PASConfiguration -Path (Join-Path $Shared.Directory 'config.json')
        $script:PASFrozenMedia = @{}
        foreach ($path in @($Shared.FrozenMedia.Keys)) {
            $script:PASFrozenMedia[[string]$path] = [string]$Shared.FrozenMedia[$path]
        }
        $run = @{
            RunId = $Shared.RunId
            DataRoot = $Shared.DataRoot
            Directory = $Shared.Directory
            Config = $config
            Credentials = $Shared.Credentials.Clone()
            Secrets = $Shared.Secrets.Clone()
            Record = @{ currentComponent = '' }
            RecordPath = ''
            Target = ''
            SshReady = @{}
            RetryFailedPreflight = [bool]$Shared.RetryFailedPreflight
            Retry = $Shared.Retry
            Lane = [string]$Lane.Name
            Current = $Shared.Current
            VaultGate = $null
            StepSignals = @{}
        }
        if ($Lane.Kind -eq 'AD') {
            Invoke-PASActiveDirectoryForest -Run $run
            [void]$signals.Domain.Set()
        }
        if ($Lane.Kind -eq 'Vault') {
            Write-PASRunEvent $run.Directory 'VaultSequence' 'Starting primary/DR installation'
            # The whole sequence holds the Vault lock; the steps of the other servers that sign in to the
            # Vault wait for the signal below and then for this lock.
            $vaultLock = Enter-PASVaultLock -Address ([string]$config.vault.address) -TimeoutSeconds 14400 -Cancel $signals.Cancel
            try {
                Invoke-PASVaultSequence -Run $run
            } finally {
                Exit-PASVaultLock $vaultLock
            }
            [void]$signals.Vault.Set()
        }
        if ($Lane.Join) {
            Wait-PASLaneSignal $signals @('Domain')
            Invoke-PASDomainJoins -Run $run -OnlyHost ([string]$Lane.Name)
        }
        foreach ($id in (@($Lane.Components) + @(Get-PASValue $Lane 'After' @()))) {
            $component = @($config.components | Where-Object { $_.id -eq $id })[0]
            if ([string]$component.type -in @('AD', 'Vault', 'DRVault')) {
                continue
            }
            if ($signals.Cancel.WaitOne(0)) {
                throw 'PASLaneStopped: the run is being stopped because another server failed. This component was not started.'
            }
            $gate = Get-PASLaneComponentGate -Config $config -Component $component
            if ($gate.StartAfter.Count) {
                $waitsFor = @($gate.StartAfter | Where-Object { $signals.ContainsKey($_) -and -not $signals[$_].WaitOne(0) })
                if ($waitsFor.Count) {
                    $run.Current[[string]$Lane.Name] = [string]$id
                    Write-PASRunEvent $run.Directory 'ComponentWaiting' 'Waiting for the PVWA certificate before this component starts' ([string]$id)
                }
                Wait-PASLaneSignal $signals $gate.StartAfter
            }
            $run.VaultGate = @{
                Wait = @($gate.VaultAfter | Where-Object { $signals.ContainsKey($_) } | ForEach-Object { $signals[$_] })
                Cancel = $signals.Cancel
            }
            $run.StepSignals = @{}
            foreach ($step in @($gate.StepSignals.Keys)) {
                $run.StepSignals[$step] = @($gate.StepSignals[$step] | ForEach-Object { $signals[$_] })
            }
            Invoke-PASComponent -Run $run -Component $component
            foreach ($name in @($gate.DoneSignals)) {
                [void]$signals[$name].Set()
            }
        }
    } catch {
        $result.Error = [string]$_.Exception.Message
        $result.Stopped = ($result.Error -match 'PASLaneStopped:')
        if ($run) {
            $result.Target = [string]$run.Target
            $result.Component = [string]$run.Record.currentComponent
        }
    } finally {
        $Shared.Current.Remove([string]$Lane.Name)
        $script:PASFrozenMedia = $null
    }
    return $result
}

function Invoke-PASRunLanes {
    <# Starts every lane of the run in its own runspace and waits for all of them. While they work, run.json
       names the components that are being installed. When a lane fails the others are told to stop: a lane
       that waits gives up, a lane that works finishes the component it is installing.
       Throws the error of the lane that failed first; $Run.Target is then the engine target it failed in. #>
    param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][object[]]$PlanItems)
    $lanes = @(Get-PASRunLanes -Config $Run.Config -PlanItems $PlanItems)
    if (-not $lanes.Count) {
        return
    }
    # Shared by the lanes: created once here so that no lane has to add to a table another lane reads.
    Add-PASDomainCredentialAlias -Config $Run.Config -Credentials $Run.Credentials
    foreach ($component in @($Run.Config.components | Where-Object { $_.type -eq 'PTA' })) {
        $root = Get-PASHostCredential $Run.Config $Run.Credentials ([string]$component.host) ([string]$component.id)
        if ($root -and $root.Password.Length) {
            $Run.Secrets['PTARoot-' + [string]$component.id] = $root.Password
        }
    }
    $frozen = @{}
    if ($script:PASFrozenMedia) {
        foreach ($path in @($script:PASFrozenMedia.Keys)) {
            $frozen[$path] = $script:PASFrozenMedia[$path]
        }
    }
    $shared = @{
        RunId = $Run.RunId
        DataRoot = $Run.DataRoot
        Directory = $Run.Directory
        Credentials = $Run.Credentials
        Secrets = $Run.Secrets
        RetryFailedPreflight = $Run.RetryFailedPreflight
        Retry = $Run.Retry
        FrozenMedia = $frozen
        Signals = (New-PASLaneSignals -Config $Run.Config)
        Current = [hashtable]::Synchronized(@{})
    }
    $manifest = Join-Path (Get-PASModuleRoot) 'PASeasyInstall.psd1'
    Write-PASRunEvent $Run.Directory 'LanesStarted' ('Installing ' + $lanes.Count + ' server lane(s) at the same time: ' + (($lanes | ForEach-Object { $_.Name }) -join ', '))
    $workers = @()
    try {
        foreach ($lane in $lanes) {
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.ThreadOptions = 'ReuseThread'
            $runspace.Open()
            $shell = [powershell]::Create()
            $shell.Runspace = $runspace
            [void]$shell.AddScript({
                    param([string]$Manifest, [hashtable]$Lane, [hashtable]$Shared)
                    $ErrorActionPreference = 'Stop'
                    Import-Module $Manifest -ErrorAction Stop
                    & (Get-Module -Name PASeasyInstall) {
                        param($Lane, $Shared)
                        Invoke-PASLane -Lane $Lane -Shared $Shared
                    } $Lane $Shared
                }).AddArgument($manifest).AddArgument($lane).AddArgument($shared)
            $workers += @{ Lane = $lane; Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke(); Result = $null }
        }
        $shown = ''
        $firstFailure = $null
        while (@($workers | Where-Object { $null -eq $_.Result }).Count) {
            foreach ($worker in @($workers | Where-Object { $null -eq $_.Result -and $_.Handle.IsCompleted })) {
                $worker.Result = Complete-PASLaneWorker $worker
                if ($worker.Result.Error) {
                    if (-not $worker.Result.Stopped -and -not $firstFailure) {
                        $firstFailure = $worker.Result
                    }
                    if (-not $shared.Signals.Cancel.WaitOne(0)) {
                        [void]$shared.Signals.Cancel.Set()
                        Write-PASRunEvent $Run.Directory 'LanesStopping' ("Server lane '" + $worker.Result.Lane + "' stopped with an error. The other servers finish the component they are installing; those that wait give up.") ([string]$worker.Result.Component) '' 'Warning'
                    }
                }
            }
            $current = (@($shared.Current.Values | Sort-Object) -join ', ')
            if ($current -ne $shown) {
                $shown = $current
                $Run.Record.currentComponent = $current
                Write-PASJsonAtomic $Run.RecordPath $Run.Record
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $firstFailure) {
            $firstFailure = @($workers | Where-Object { $_.Result.Error } | ForEach-Object { $_.Result })[0]
        }
        if ($firstFailure) {
            $Run.Target = [string]$firstFailure.Target
            $Run.Record.currentComponent = [string]$firstFailure.Component
            throw [string]$firstFailure.Error
        }
        $Run.Target = ''
        $Run.Record.currentComponent = ''
    } finally {
        [void]$shared.Signals.Cancel.Set()
        foreach ($worker in $workers) {
            try {
                if (-not $worker.Handle.IsCompleted) {
                    $worker.Shell.Stop()
                }
            } catch {
                Write-Verbose 'lane stop failed'
            }
            $worker.Shell.Dispose()
            $worker.Runspace.Dispose()
        }
        foreach ($signal in @($shared.Signals.Values)) {
            $signal.Dispose()
        }
    }
}

function Complete-PASLaneWorker {
    # The result of a lane whose runspace has ended.
    param([hashtable]$Worker)
    $name = [string]$Worker.Lane.Name
    try {
        $output = @($Worker.Shell.EndInvoke($Worker.Handle))
        $result = @($output | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Lane') }) | Select-Object -Last 1
        if ($result) {
            return $result
        }
        $problem = 'The lane ended without a result.'
        if ($Worker.Shell.Streams.Error.Count) {
            $problem = [string]$Worker.Shell.Streams.Error[0]
        }
        return @{ Lane = $name; Error = $problem; Target = ''; Component = ''; Stopped = $false }
    } catch {
        return @{ Lane = $name; Error = [string]$_.Exception.Message; Target = ''; Component = ''; Stopped = $false }
    }
}
