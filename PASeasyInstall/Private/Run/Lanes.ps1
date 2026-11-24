# A parallel run (execution.mode = Parallel): the servers are installed at the same time.
#
#   Lane    the work of one server, in plan order, as in a sequential run. The lanes run side by side, each in
#           its own PowerShell runspace of the controller process with its own copy of this module (so the
#           remoting sessions and the approved media list of one lane are not shared with another).
#           The Vault is one lane, its DR Vault another, the new forest is one lane.
#   Signal  a wait handle that is set once and stays set:
#             Domain          the new forest is installed (set from the start when the run creates none)
#             Vault           the Primary Vault is installed, hardened and verified (set from the start when
#                             the run installs none). The DR Vault is not waited for.
#             PvwaRegistered  the first PVWA finished its step 'register'
#             Registered:<id> PVWA, CPM, PSM or PSMP <id> finished its step 'register'
#             Cert:<id>       PVWA <id> has its HTTPS certificate (its first step, 'certificate')
#             Done:<id>       component <id> is installed and verified
#             Fail:<signal>   the lane that would have set <signal> failed: who waits for it gives up
#             Cancel          the lanes are being taken down (set only when the run ends)
#   What waits for what (see site-src/concepts/parallel.md):
#             a joined server          Domain, before its join
#             a component that trusts
#             the PVWA certificate     Cert of every PVWA, before it starts (CPM, PSM, HTML5 Gateway, PTA)
#             a step that signs in
#             to the Vault             Vault; every component except the first PVWA also PvwaRegistered;
#                                      everything except PVWA and CPM also Registered of every CPM
#                                      (the vendor's order: PVWA, CPM, then the rest); PTA waits for Done of
#                                      every PVWA and registers last, after every PSM and PSMP
#             the DR Vault             nothing but the milestones of the Primary Vault (its keys, then
#                                      'primary-ready'); nothing waits for the DR Vault
#           One Vault sign-in at a time is the Vault lock that every such step takes (Engine\Locks.ps1).
#   A lane that fails stops only what depends on it. Registered:<id> is an order, not a need: when that server
#   fails, those that waited for it go on. Everything else in the list is a need: who waits for it is not
#   installed, and says so. The other servers are installed to the end, then the run ends Failed.
# Gateway registration and PTA trust are dependency-ready integration work; domain GPOs remain at the end.

function Get-PASRunLanes {
    <# The lanes of a configuration, in the order they are started. Each lane:
         Name        'ad', 'vault', 'dr' or the id of the server
         Kind        AD, Vault, DR or Server
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
        [void]$lanes.Add(@{ Name = 'vault'; Kind = 'Vault'; Join = $false; Components = @($vaultParts | Where-Object { $_.type -eq 'Vault' } | ForEach-Object { [string]$_.id }) })
        foreach ($part in @($vaultParts | Where-Object { $_.type -eq 'Vault' })) {
            $laneOfHost[[string]$part.host] = 'vault'
        }
        $drParts = @($vaultParts | Where-Object { $_.type -eq 'DRVault' })
        if ($drParts.Count) {
            # The DR Vault prepares itself while the Primary is installed and waits only for its milestones.
            [void]$lanes.Add(@{ Name = 'dr'; Kind = 'DR'; Join = $false; Components = @($drParts | ForEach-Object { [string]$_.id }) })
            foreach ($part in $drParts) {
                $laneOfHost[[string]$part.host] = 'dr'
            }
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
       The registrations follow the vendor's order: the first PVWA, the other PVWAs, every CPM, then the rest;
       PTA is the last one. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$Component)
    $id = [string]$Component.id
    $type = [string]$Component.type
    $pvwas = @($Config.components | Where-Object { $_.type -eq 'PVWA' } | ForEach-Object { [string]$_.id })
    $cpms = @($Config.components | Where-Object { $_.type -eq 'CPM' } | ForEach-Object { [string]$_.id })
    $sessions = @($Config.components | Where-Object { $_.type -in @('PSM', 'PSMP') } | ForEach-Object { [string]$_.id })
    $gate = @{ StartAfter = @(); VaultAfter = @('Vault'); StepSignals = @{}; DoneSignals = @('Done:' + $id) }
    if ([string](Get-PASValue (Get-PASValue $Component 'options' $null) 'pvwaTrustFrom' '')) {
        $gate.StartAfter = @($pvwas | ForEach-Object { 'Cert:' + $_ })
    }
    if ($type -eq 'PVWA') {
        $gate.StepSignals['certificate'] = @('Cert:' + $id)
        $gate.StepSignals['register'] = @('Registered:' + $id)
        $gate.DoneSignals += @(('Cert:' + $id), ('Registered:' + $id))
        if ($pvwas.Count -and $pvwas[0] -eq $id) {
            $gate.StepSignals['register'] += 'PvwaRegistered'
            $gate.DoneSignals += 'PvwaRegistered'
        } else {
            $gate.VaultAfter += 'PvwaRegistered'
        }
    } elseif ($type -eq 'CPM') {
        # The CPM registration looks at the certificate of every PVWA that is registered in the Vault.
        if ($pvwas.Count) {
            $gate.VaultAfter += 'PvwaRegistered'
        }
        $gate.VaultAfter += @($pvwas | ForEach-Object { 'Registered:' + $_ })
        $gate.StepSignals['register'] = @('Registered:' + $id)
        $gate.DoneSignals += 'Registered:' + $id
    } elseif ($type -eq 'PTA') {
        # The PTA configuration names the PVWA and signs in through it: the PVWA servers must be finished.
        $gate.VaultAfter += @($pvwas | ForEach-Object { 'Done:' + $_ })
        $gate.VaultAfter += @($cpms | ForEach-Object { 'Registered:' + $_ })
        # PTA registers last. Its configuration holds the Vault for about three minutes, while PSM still has
        # its hardening after its registration and the gateway registration waits for PSM: PSM and PSM for
        # SSH go first (an order only, as for CPM: a PSM that fails does not hold PTA back).
        $gate.VaultAfter += @($sessions | ForEach-Object { 'Registered:' + $_ })
    } else {
        if ($pvwas.Count) {
            $gate.VaultAfter += 'PvwaRegistered'
        }
        $gate.VaultAfter += @($cpms | ForEach-Object { 'Registered:' + $_ })
        if ($type -eq 'PSMP') {
            $gate.StepSignals['register'] = @('Registered:' + $id)
            $gate.DoneSignals += 'Registered:' + $id
        } elseif ($type -eq 'PSM') {
            # The PSM registration is a vendor checkpoint run up to three times (register, register-pass2,
            # register-pass3; Planning.ps1), each with the Vault lock. PSM has registered after the last pass:
            # announced earlier, PTA would take the Vault between the passes and hold PSM up for minutes.
            $gate.StepSignals['register-pass3'] = @('Registered:' + $id)
            $gate.DoneSignals += 'Registered:' + $id
        }
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
    }
    foreach ($cpm in @($components | Where-Object { $_.type -in @('CPM', 'PSM', 'PSMP') })) {
        $signals['Registered:' + [string]$cpm.id] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
    }
    foreach ($component in @($components | Where-Object { $_.type -notin @('AD', 'Vault', 'DRVault') })) {
        $signals['Done:' + [string]$component.id] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
    }
    # Every signal that is a need has a second handle that says "this will never come".
    foreach ($name in @($signals.Keys | Where-Object { $_ -ne 'Cancel' -and $_ -notlike 'Registered:*' })) {
        $signals['Fail:' + $name] = New-Object System.Threading.ManualResetEvent -ArgumentList $false
    }
    return $signals
}

function Get-PASLaneGate {
    # The gate for the named signals: the handles to wait for, and those that end the wait (the run is being
    # taken down, or the lane that would have set one of the signals failed).
    param([hashtable]$Signals, [string[]]$Names)
    $requested = @($Names | Where-Object { $_ } | Select-Object -Unique)
    $missing = @($requested | Where-Object { -not $Signals.ContainsKey($_) })
    if ($missing.Count) { throw ('Invalid workflow dependencies: ' + ($missing -join ', ')) }
    $cancel = @($Signals.Cancel) + @($requested | Where-Object { $Signals.ContainsKey('Fail:' + $_) } | ForEach-Object { $Signals['Fail:' + $_] })
    return @{ Wait = @($requested | ForEach-Object { $Signals[$_] }); Cancel = $cancel;
        Names = $requested; TimeoutSeconds = 14400 }
}

function Wait-PASLaneSignal {
    # Waits until the named signals are set. Throws PASLaneStopped when one of them will never come.
    param([hashtable]$Signals, [string[]]$Names)
    [void](Wait-PASVaultGate (Get-PASLaneGate $Signals $Names))
}


function Assert-PASLaneSignalPlan {
    # Fail before remote dispatch if a dependency references a signal with no producer.
    # Per-host dependencies are enforced by the scheduler; this validates all named gates.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][object[]]$Lanes)
    $signals = New-PASLaneSignals -Config $Config
    try {
        foreach ($component in @($Config.components | Where-Object { $_.type -notin @('AD','Vault','DRVault') })) {
            $gate = Get-PASLaneComponentGate -Config $Config -Component $component
            [void](Get-PASLaneGate -Signals $signals -Names @($gate.StartAfter))
            [void](Get-PASLaneGate -Signals $signals -Names @($gate.VaultAfter))
            foreach ($key in @($gate.StepSignals.Keys)) {
                foreach ($name in @($gate.StepSignals[$key])) {
                    if (-not $signals.ContainsKey([string]$name)) {
                        throw "Signal '$name' published by $($component.id):$key has no declaration"
                    }
                }
            }
        }
        $producers = @{}
        foreach ($lane in $Lanes) {
            foreach ($signal in @(Get-PASLaneOwedSignals -Config $Config -Lane $lane)) {
                if ($producers.ContainsKey($signal)) { throw "Signal '$signal' has multiple producer lanes" }
                $producers[$signal] = [string]$lane.Name
            }
        }
        $laneByComponent = @{}
        foreach ($lane in $Lanes) {
            foreach ($id in @(@($lane.Components) + @(Get-PASValue $lane 'After' @()))) {
                $laneByComponent[[string]$id] = [string]$lane.Name
            }
        }
        # Inside a host lane execution is sequential. A gate published by a later
        # component in that same lane (or by itself) cannot ever open in time.
        # Cross-lane cycle checks alone cannot detect this deadlock.
        $componentIndex = @{}
        foreach ($lane in $Lanes) {
            $index = 0
            foreach ($id in @(@($lane.Components) + @(Get-PASValue $lane 'After' @()))) {
                $componentIndex[[string]$id] = $index
                $index++
            }
        }
        $producerComponent = @{}
        foreach ($component in @($Config.components | Where-Object { $_.type -notin @('AD', 'Vault', 'DRVault') })) {
            $gate = Get-PASLaneComponentGate -Config $Config -Component $component
            foreach ($signal in @(@($gate.DoneSignals) + @($gate.StepSignals.Values | ForEach-Object { $_ }))) {
                if ($signal) { $producerComponent[[string]$signal] = [string]$component.id }
            }
        }
        # Deadlock check per component, not per server lane: a lane is a sequence, and a lane-level cycle is
        # often harmless (lane A = PVWA1 then CPM1, lane B = PVWA2: PVWA2 waits for PVWA1's registration and CPM1
        # for PVWA2's; nothing waits for something that comes later). Nodes are components; an edge goes from a
        # component to the producer of every signal it waits for, and to the component before it in its lane.
        $edges = @{}
        foreach ($component in @($Config.components | Where-Object { $_.type -notin @('AD','Vault','DRVault') })) {
            $edges[[string]$component.id] = @()
        }
        foreach ($lane in $Lanes) {
            $previous = ''
            foreach ($id in @(@($lane.Components) + @(Get-PASValue $lane 'After' @()))) {
                if (-not $edges.ContainsKey([string]$id)) { continue }
                if ($previous) { $edges[[string]$id] += $previous }
                $previous = [string]$id
            }
        }
        foreach ($component in @($Config.components | Where-Object { $_.type -notin @('AD','Vault','DRVault') })) {
            $gate = Get-PASLaneComponentGate -Config $Config -Component $component
            foreach ($name in @(@($gate.StartAfter) + @($gate.VaultAfter))) {
                if (-not $signals[$name].WaitOne(0) -and -not $producers.ContainsKey($name)) {
                    throw "Dependency '$name' for '$($component.id)' cannot be published by any lane"
                }
                $consumerId = [string]$component.id
                if (-not $producerComponent.ContainsKey($name)) { continue }
                $sourceId = [string]$producerComponent[$name]
                $owner = [string]$laneByComponent[$consumerId]
                if ($owner -and $producers.ContainsKey($name) -and [string]$producers[$name] -eq $owner -and
                    [int]$componentIndex[$sourceId] -ge [int]$componentIndex[$consumerId]) {
                    throw "Cyclic or forward dependency '$name': $consumerId waits for $sourceId in the same server lane"
                }
                if ($sourceId -ne $consumerId) { $edges[$consumerId] += $sourceId }
            }
        }
        $visiting = @{}
        $visited = @{}
        function Assert-PASLaneAcyclicVisit {
            param([string]$Name, [hashtable]$Edges, [hashtable]$Visiting, [hashtable]$Visited)
            if ($Visiting.ContainsKey($Name)) { throw "Cyclic deployment dependency involving component '$Name'" }
            if ($Visited.ContainsKey($Name)) { return }
            $Visiting[$Name] = $true
            foreach ($provider in @($Edges[$Name] | Select-Object -Unique)) {
                Assert-PASLaneAcyclicVisit -Name ([string]$provider) -Edges $Edges -Visiting $Visiting -Visited $Visited
            }
            $Visiting.Remove($Name)
            $Visited[$Name] = $true
        }
        foreach ($node in @($edges.Keys)) {
            Assert-PASLaneAcyclicVisit -Name ([string]$node) -Edges $edges -Visiting $visiting -Visited $visited
        }
    } finally {
        foreach ($handle in @($signals.Values)) { $handle.Dispose() }
    }
}

function Get-PASLaneOwedSignals {
    # The names of the signals a lane sets when its work succeeds.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$Lane)
    if ($Lane.Kind -eq 'AD') {
        return @('Domain')
    }
    $names = @()
    if ($Lane.Kind -eq 'Vault') {
        $names += 'Vault'
    }
    foreach ($id in (@($Lane.Components) + @(Get-PASValue $Lane 'After' @()))) {
        $component = @($Config.components | Where-Object { $_.id -eq $id })[0]
        if (-not $component -or [string]$component.type -in @('AD', 'Vault', 'DRVault')) {
            continue
        }
        $gate = Get-PASLaneComponentGate -Config $Config -Component $component
        $names += @($gate.DoneSignals)
        foreach ($step in @($gate.StepSignals.Keys)) {
            $names += @($gate.StepSignals[$step])
        }
    }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
}

function Get-PASLaneConsumedSignals {
    # The names of the signals somebody waits for: a component gate (before it starts or before it signs in to
    # the Vault) or an integration (gateway registration, PTA trust). Every component publishes Done:<id>,
    # but a failed lane holds up only those signals that appear here.
    param([Parameter(Mandatory)]$Config)
    $names = @()
    foreach ($component in @($Config.components | Where-Object { $_.type -notin @('AD', 'Vault', 'DRVault') })) {
        $gate = Get-PASLaneComponentGate -Config $Config -Component $component
        $names += @($gate.StartAfter)
        $names += @($gate.VaultAfter)
    }
    foreach ($job in @(Get-PASParallelFinalizationJobs -Config $Config)) {
        $names += @($job.DependsOn)
    }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
}

function Set-PASLaneFailed {
    # A lane ended with an error: what it still owed will never come. A signal that is only an order
    # (Registered:<id>) is set, so that who waited for its turn goes on; a signal that is a need gets its
    # Fail handle set, so that who waits for it gives up. Returns the names of the needs that failed.
    # -Consumed (Get-PASLaneConsumedSignals): when given, only needs that somebody waits for are returned.
    param([hashtable]$Signals, [string[]]$Owed, [string[]]$Consumed)
    $failed = @()
    foreach ($name in @($Owed)) {
        if (-not $Signals.ContainsKey($name) -or $Signals[$name].WaitOne(0)) {
            continue
        }
        if ($Signals.ContainsKey('Fail:' + $name)) {
            [void]$Signals['Fail:' + $name].Set()
            if ($null -eq $Consumed -or $Consumed -contains $name) {
                $failed += $name
            }
        } else {
            [void]$Signals[$name].Set()
        }
    }
    return $failed
}

function Test-PASLaneFinished {
    <# $true when everything of a lane was installed and verified by this run already (a continued run): every
       engine target of the lane has a journal that says Succeeded. Such a lane is not run again: its servers
       are left alone, and what it owes the others counts as done. Lanes that join a domain or install the
       forest are always run (their steps check themselves). #>
    param([Parameter(Mandatory)][hashtable]$Lane, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Directory)
    if ($Lane.Kind -eq 'AD' -or $Lane.Join) {
        return $false
    }
    $withDR = [bool]@($Config.components | Where-Object { $_.type -eq 'DRVault' }).Count
    $targets = @()
    if ($Lane.Kind -eq 'Vault') {
        $targets += 'primary'
        if ($withDR) {
            $targets += 'primary_final'
        }
    } elseif ($Lane.Kind -eq 'DR') {
        $targets += @('dr', 'dr_final')
    } else {
        $targets += @($Lane.Components)
    }
    $targets += @(Get-PASValue $Lane 'After' @())
    if (-not $targets.Count) {
        return $false
    }
    foreach ($target in $targets) {
        $statePath = Join-Path (Join-Path $Directory ([string]$target)) 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            return $false
        }
        $state = $null
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            return $false
        }
        if ([string]$state.status -ne 'Succeeded') {
            return $false
        }
    }
    return $true
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
            Write-PASRunEvent $run.Directory 'VaultSequence' 'Starting the installation of the Primary Vault'
            # The installation of the Primary holds the Vault lock; the steps of the other servers that sign in
            # to the Vault wait for the signal below and then for this lock.
            $vaultLock = Enter-PASVaultLock -Address ([string]$config.vault.address) -TimeoutSeconds 14400 -Cancel $signals.Cancel
            try {
                Invoke-PASVaultSequence -Run $run -Part Primary
            } finally {
                Exit-PASVaultLock $vaultLock
            }
            foreach ($id in @($Lane.Components)) {
                $Shared.Installed[[string]$id] = $true
            }
            # From here the other servers register, one at a time.
            [void]$signals.Vault.Set()
            # With a DR Vault: the test safe of the replication test, one short sign-in in that same queue.
            # With it the Primary Vault is finished; the DR Vault looks for the safe when it replicates.
            $run.VaultGate = @{ Wait = @(); Cancel = @($signals.Cancel) }
            Invoke-PASVaultSequence -Run $run -Part PrimaryTest
            $run.VaultGate = $null
        }
        if ($Lane.Kind -eq 'DR') {
            Write-PASRunEvent $run.Directory 'VaultSequence' 'Starting the installation of the DR Vault (next to the Primary Vault)' ([string]$Lane.Components[0])
            # Its own steps wait for the milestones of the Primary; the last one waits until the test safe the
            # Primary created has arrived here.
            $run.VaultGate = @{ Wait = @(); Cancel = @($signals.Cancel, $signals['Fail:Vault']) }
            Invoke-PASVaultSequence -Run $run -Part DR
            $run.VaultGate = $null
            foreach ($id in @($Lane.Components)) {
                $Shared.Installed[[string]$id] = $true
            }
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
                throw 'PASLaneStopped: the run is being stopped. This component was not started.'
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
            $run.VaultGate = Get-PASLaneGate $signals $gate.VaultAfter
            $run.StepSignals = @{}
            foreach ($step in @($gate.StepSignals.Keys)) {
                $run.StepSignals[$step] = @($gate.StepSignals[$step] | ForEach-Object { $signals[$_] })
            }
            Invoke-PASComponent -Run $run -Component $component
            $Shared.Installed[[string]$id] = $true
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

function Get-PASParallelFinalizationJobs {
    # Only direct component readiness matters; DR replication and unrelated servers never gate integrations.
    param([Parameter(Mandatory)]$Config)
    $pvwas = @($Config.components | Where-Object { $_.type -eq 'PVWA' } | ForEach-Object { [string]$_.id })
    $psms = @($Config.components | Where-Object { $_.type -eq 'PSM' } | ForEach-Object { [string]$_.id })
    $html = @($Config.components | Where-Object { $_.type -eq 'HTML5GW' } | ForEach-Object { [string]$_.id })
    $ptas = @($Config.components | Where-Object { $_.type -eq 'PTA' } | ForEach-Object { [string]$_.id })
    # Both integrations run on the first PVWA server (the gateway one also restarts its application pool):
    # everything else installed on that server must be finished first, and the gateway waits for the PTA
    # servers, whose registration signs in through that PVWA.
    $sameHost = @()
    if ($pvwas.Count) {
        $first = @($Config.components | Where-Object { [string]$_.id -eq $pvwas[0] })[0]
        $firstHost = [string](Get-PASValue $first 'host' '')
        $sameHost = @($Config.components | Where-Object {
                $firstHost -and [string](Get-PASValue $_ 'host' '') -eq $firstHost -and
                [string]$_.type -notin @('AD', 'Vault', 'DRVault') } | ForEach-Object { [string]$_.id })
    }
    $jobs = @()
    if ($html.Count) {
        if (-not $pvwas.Count) { throw 'HTML5 Gateway registration requires a PVWA in the configuration' }
        $jobs += ,@{ Name = 'GatewayRegistration'; DependsOn = @($pvwas + $psms + $html + $ptas + $sameHost | Select-Object -Unique | ForEach-Object { 'Done:' + $_ }) }
    }
    if ($ptas.Count) {
        if (-not $pvwas.Count) { throw 'PTA trust requires a PVWA in the configuration' }
        $jobs += ,@{ Name = 'PtaTrust'; DependsOn = @($pvwas + $ptas + $sameHost | Select-Object -Unique | ForEach-Object { 'Done:' + $_ }) }
    }
    return @($jobs)
}

function Invoke-PASParallelFinalizations {
    # Independent scheduler on a separate runspace. It waits on verified milestones and
    # serializes PVWA-side changes on purpose (both operations write to the first PVWA).
    param([Parameter(Mandatory)][hashtable]$Shared)
    $result = @{ Lane = 'integrations'; Error = ''; Target = ''; Component = ''; Stopped = $false }
    $run = $null
    try {
        $config = Read-PASConfiguration -Path (Join-Path $Shared.Directory 'config.json')
        $script:PASFrozenMedia = @{}
        foreach ($path in @($Shared.FrozenMedia.Keys)) {
            $script:PASFrozenMedia[[string]$path] = [string]$Shared.FrozenMedia[$path]
        }
        $run = @{
            RunId = $Shared.RunId; DataRoot = $Shared.DataRoot; Directory = $Shared.Directory
            Config = $config; Credentials = $Shared.Credentials.Clone(); Secrets = $Shared.Secrets.Clone()
            Record = @{ currentComponent = '' }; RecordPath = ''; Target = ''; SshReady = @{}
            RetryFailedPreflight = [bool]$Shared.RetryFailedPreflight; Retry = $Shared.Retry
            Lane = 'integrations'; Current = $Shared.Current; StepSignals = @{}
            # Gateway registration signs in to the Vault while other lanes may still register: wait for the turn
            # (as the server lanes do), not for the 180 seconds of an ungated step.
            VaultGate = @{ Wait = @(); Cancel = @($Shared.Signals.Cancel); Names = @(); TimeoutSeconds = 14400 }
        }
        $pending = @(Get-PASParallelFinalizationJobs -Config $config)
        $waitStarted = [DateTime]::UtcNow
        $lastWait = ''
        $failedJobs = @()
        while ($pending.Count) {
            if ($Shared.Signals.Cancel.WaitOne(0)) { throw 'PASLaneStopped: integration work cancelled' }
            $next = @()
            $progress = $false
            $waiting = @()
            foreach ($job in $pending) {
                $gate = Get-PASLaneGate -Signals $Shared.Signals -Names @($job.DependsOn)
                $failed = @($job.DependsOn | Where-Object {
                    $name = [string]$_
                    $Shared.Signals.ContainsKey('Fail:' + $name) -and $Shared.Signals['Fail:' + $name].WaitOne(0)
                })
                if ($failed.Count) {
                    $message = 'Integration ' + $job.Name + ' skipped: failed dependency ' + ($failed -join ', ')
                    Write-PASRunEvent $run.Directory 'IntegrationBlocked' $message $job.Name '' 'Warning'
                    $failedJobs += $message
                    $progress = $true
                    continue
                }
                $need = @($job.DependsOn | Where-Object { -not $Shared.Signals[$_].WaitOne(0) })
                if ($need.Count) {
                    $waiting += ($job.Name + ': ' + ($need -join ', '))
                    $next += ,$job
                    continue
                }
                $Shared.Current['integrations'] = $job.Name
                Write-PASRunEvent $run.Directory 'IntegrationReady' ('Integration ' + $job.Name + ' has all verified prerequisites') $job.Name
                try {
                    switch ([string]$job.Name) {
                        'GatewayRegistration' { Invoke-PASGatewayRegistration -Run $run }
                        'PtaTrust' { Invoke-PASPtaTrust -Run $run }
                        default { throw ('Unexpected integration ' + $job.Name) }
                    }
                    Write-PASRunEvent $run.Directory 'IntegrationComplete' ('Integration ' + $job.Name + ' completed') $job.Name
                } catch {
                    $message = 'Integration ' + $job.Name + ' failed: ' + [string]$_.Exception.Message
                    Write-PASRunEvent $run.Directory 'IntegrationFailed' $message $job.Name '' 'Warning'
                    $failedJobs += $message
                }
                $progress = $true
            }
            $pending = @($next)
            if ($progress) { $lastWait = ''; continue }
            $description = $waiting -join '; '
            if ($description -ne $lastWait) {
                # A signal arrived (or the first wait): the time limit counts from the last progress, not from the
                # start of the run. The producing lanes have their own time limits and fail with a Fail signal.
                $lastWait = $description
                $waitStarted = [DateTime]::UtcNow
                $Shared.Current['integrations'] = 'Waiting for ' + $description
                Write-PASRunEvent $run.Directory 'IntegrationWaiting' $description '' '' 'Information'
            }
            if ([DateTime]::UtcNow - $waitStarted -gt [timespan]::FromSeconds(14400)) {
                throw ('PASLaneStopped: timed out waiting for integration prerequisites: ' + $description)
            }
            Start-Sleep -Milliseconds 400
        }
        if ($failedJobs.Count) { throw ($failedJobs -join '; ') }
    } catch {
        $result.Error = [string]$_.Exception.Message
        $result.Stopped = $result.Error -match 'PASLaneStopped:'
        if ($run) {
            $result.Target = [string]$run.Target
            $result.Component = [string](Get-PASValue $run.Record 'currentComponent' '')
        }
    } finally {
        $Shared.Current.Remove('integrations')
        $script:PASFrozenMedia = $null
    }
    return $result
}

function Invoke-PASRunLanes {
    <# Starts every lane of the run in its own runspace and waits for all of them. While they work, run.json
       names the components that are being installed. When a lane fails, only what depends on it gives up
       (Set-PASLaneFailed); every other server is installed to the end.
       $Run.Installed then names the components that are installed.
       Throws the error of the lane that failed first; $Run.Target is then the engine target it failed in. #>
    param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][object[]]$PlanItems)
    $lanes = @(Get-PASRunLanes -Config $Run.Config -PlanItems $PlanItems)
    if (-not $lanes.Count) {
        return
    }
    # Compile dependency names before any controller starts remote work.
    Assert-PASLaneSignalPlan -Config $Run.Config -Lanes $lanes
    # Shared by the lanes: created once here so that no lane has to add to a table another lane reads.
    Add-PASDomainCredentialAlias -Config $Run.Config -Credentials $Run.Credentials
    foreach ($component in @($Run.Config.components | Where-Object { $_.type -eq 'PTA' })) {
        $root = Get-PASHostCredential $Run.Config $Run.Credentials ([string]$component.host) ([string]$component.id)
        if ($root -and $root.Password.Length) {
            $Run.Secrets['PTARoot-' + [string]$component.id] = $root.Password
        }
    }
    # The inventory file of the Vault workflows is shared by the Vault lane and the DR lane: written once, here.
    if (@($Run.Config.components | Where-Object { $_.type -eq 'Vault' }).Count) {
        Invoke-PASVaultSequence -Run $Run -Part Prepare
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
        Installed = [hashtable]::Synchronized(@{})
    }
    $manifest = Join-Path (Get-PASModuleRoot) 'PASeasyInstall.psd1'
    # A continued run: verify all saved successes again before releasing milestones.
    # Never assert dependencies solely from yesterday's successful journal. All previously
    # completed steps are re-verified read-only by Invoke-PASWorkflow on resume.
    $integrationJobs = @(Get-PASParallelFinalizationJobs -Config $Run.Config)
    foreach ($job in $integrationJobs) { [void](Get-PASLaneGate -Signals $shared.Signals -Names @($job.DependsOn)) }
    if ($integrationJobs.Count) {
        $lanes += ,@{ Name = 'integrations'; Kind = 'Finalization'; Join = $false; Components = @() }
    }
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
                        if ($Lane.Kind -eq 'Finalization') {
                            Invoke-PASParallelFinalizations -Shared $Shared
                        } else {
                            Invoke-PASLane -Lane $Lane -Shared $Shared
                        }
                    } $Lane $Shared
                }).AddArgument($manifest).AddArgument($lane).AddArgument($shared)
            $workers += @{ Lane = $lane; Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke(); Result = $null }
        }
        $consumed = @(Get-PASLaneConsumedSignals -Config $Run.Config)
        $shown = ''
        $firstFailure = $null
        while (@($workers | Where-Object { $null -eq $_.Result }).Count) {
            foreach ($worker in @($workers | Where-Object { $null -eq $_.Result -and $_.Handle.IsCompleted })) {
                $worker.Result = Complete-PASLaneWorker $worker
                if ($worker.Result.Error) {
                    if (-not $worker.Result.Stopped -and -not $firstFailure) {
                        $firstFailure = $worker.Result
                    }
                    $owed = @(Get-PASLaneOwedSignals -Config $Run.Config -Lane $worker.Lane)
                    $needs = @(Set-PASLaneFailed -Signals $shared.Signals -Owed $owed -Consumed $consumed)
                    $what = "Server lane '" + $worker.Result.Lane + "' stopped with an error."
                    if ($worker.Result.Stopped) {
                        $what = "Server lane '" + $worker.Result.Lane + "' is not installed, because a server it depends on failed."
                    }
                    if ($needs.Count) {
                        $what += ' What depends on it is not installed. Every other server is installed to the end.'
                    } else {
                        $what += ' Nothing else depends on it: every other server is installed to the end.'
                    }
                    Write-PASRunEvent $Run.Directory 'LaneFailed' $what ([string]$worker.Result.Component) '' 'Warning'
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
        $Run.Installed = @($shared.Installed.Keys | ForEach-Object { [string]$_ })
        if ($firstFailure) {
            $Run.Target = [string]$firstFailure.Target
            $Run.Record.currentComponent = [string]$firstFailure.Component
            $others = @($workers | Where-Object { $_.Result.Error -and -not $_.Result.Stopped -and $_.Result.Lane -ne $firstFailure.Lane } | ForEach-Object { [string]$_.Result.Lane })
            $skipped = @($workers | Where-Object { $_.Result.Error -and $_.Result.Stopped } | ForEach-Object { [string]$_.Result.Lane })
            $message = [string]$firstFailure.Error
            if ($others.Count) {
                $message += ' Also failed: ' + ($others -join ', ') + '.'
            }
            if ($skipped.Count) {
                $message += ' Not installed because of it: ' + ($skipped -join ', ') + '.'
            }
            throw $message
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
