# Pure HTML renderers: plain objects in, escaped markup out. No SDK, no backend calls, so they
# are unit-testable without a window. Every value that came from the user or a backend is encoded.

function Get-PASUIEscaped { param([AllowNull()][string]$Value) return [Net.WebUtility]::HtmlEncode([string]$Value) }

$script:PASUIComponentNames = @{
    Vault = 'Primary Vault'; DRVault = 'DR Vault'; PVWA = 'PVWA'; CPM = 'CPM'; PSM = 'PSM'; PSMP = 'PSMP'; AD = 'Active Directory'
}
function Get-PASUIComponentName { param([string]$Type) if ($script:PASUIComponentNames.ContainsKey($Type)) { return $script:PASUIComponentNames[$Type] } return $Type }
function Get-PASUIItemName {
    <# Display name of a plan item: the instance name for components, the friendly name for Vault/DR. #>
    param($Item)
    if ($Item.Type -in @('Vault', 'DRVault')) { return (Get-PASUIComponentName $Item.Type) }
    if ($Item.PSObject.Properties['Name'] -and $Item.Name) { return [string]$Item.Name }
    return (Get-PASUIComponentName $Item.Type)
}
function Get-PASUICatalogKey { param([string]$Type) if ($Type -eq 'DRVault') { return 'DR' } return $Type }

function ConvertTo-PASUIMessageHtml {
    param([ValidateSet('info', 'ok', 'warn', 'error')][string]$Kind = 'info', [string]$Text)
    $icon = @{info = 'i'; ok = '✓'; warn = '!'; error = '×' }[$Kind]
    return '<div class="pas-msg ' + $Kind + '"><span class="pas-msg-icon">' + $icon + '</span><span>' + (Get-PASUIEscaped $Text) + '</span></div>'
}

function ConvertTo-PASUIReviewHtml {
    <# $Validation: Test-PASLabConfiguration result. $Plan: Get-PASLabPlan result or $null. $StageCounts: @{Vault=14;...} #>
    param(
        $Validation,
        $Plan,
        [hashtable]$StageCounts = @{},
        [string]$ErrorText = '',
        [string[]]$ExtraIssues = @(),
        [string]$CredentialMode = ''
    )
    $h = New-Object System.Text.StringBuilder
    if ($ErrorText) {
        [void]$h.Append('<div class="pas-issues"><div class="pas-issues-head">The plan could not be prepared</div><ul><li>')
        [void]$h.Append((Get-PASUIEscaped $ErrorText)).Append('</li></ul></div>')
        return $h.ToString()
    }
    $allIssues = @()
    if ($Validation -and -not $Validation.Valid) { $allIssues += @($Validation.Issues) }
    $allIssues += @($ExtraIssues | Where-Object { $_ })
    if ($allIssues.Count) {
        [void]$h.Append('<div class="pas-issues"><div class="pas-issues-head">Fix these before installing</div><ul>')
        foreach ($i in $allIssues) { [void]$h.Append('<li>').Append((Get-PASUIEscaped $i)).Append('</li>') }
        [void]$h.Append('</ul><div class="pas-issues-hint">Use Back or the steps on the left to correct the values.</div></div>')
        return $h.ToString()
    }
    if (-not $Plan) { return '<div class="pas-empty">No plan yet.</div>' }
    $items = @($Plan.Items)
    $stageTotal = 0
    foreach ($it in $items) { $stageTotal += [int]$StageCounts[(Get-PASUICatalogKey $it.Type)] }
    [void]$h.Append('<div class="pas-kpis">')
    foreach ($k in @(@('Components', $items.Count), @('Target servers', @($items | ForEach-Object { $_.Host } | Sort-Object -Unique).Count),
            @('Planned stages', $stageTotal))) {
        [void]$h.Append('<div class="pas-kpi"><div class="pas-kpi-v">').Append((Get-PASUIEscaped ([string]$k[1]))).Append('</div><div class="pas-kpi-l">').Append($k[0]).Append('</div></div>')
    }
    [void]$h.Append('</div><table class="pas-table"><thead><tr><th>#</th><th>Instance</th><th>Server</th><th>Address</th><th>Installer</th><th>Stages</th><th>Depends on</th></tr></thead><tbody>')
    $n = 0
    foreach ($it in $items) {
        $n++
        $deps = @($it.DependsOn) -join ', '
        if (-not $deps) { $deps = '—' }
        $addr = ''
        if ($it.PSObject.Properties['Address']) { $addr = [string]$it.Address }
        [void]$h.Append('<tr><td class="pas-num">').Append($n).Append('</td><td><strong>').Append((Get-PASUIEscaped (Get-PASUIItemName $it))).Append('</strong>')
        if ((Get-PASUIItemName $it) -ne (Get-PASUIComponentName $it.Type)) { [void]$h.Append(' <span class="pas-type">').Append((Get-PASUIEscaped $it.Type)).Append('</span>') }
        [void]$h.Append('</td>')
        [void]$h.Append('<td>').Append((Get-PASUIEscaped $it.Host)).Append('</td><td><span class="pas-mono">').Append((Get-PASUIEscaped $addr)).Append('</span></td>')
        $media = ''
        if ($it.PSObject.Properties['Media']) { $media = [string]$it.Media }
        [void]$h.Append('<td class="pas-small">').Append((Get-PASUIEscaped $media)).Append('</td>')
        [void]$h.Append('<td>').Append([int]$StageCounts[(Get-PASUICatalogKey $it.Type)]).Append('</td><td>').Append((Get-PASUIEscaped $deps)).Append('</td></tr>')
    }
    [void]$h.Append('</tbody></table>')
    $notes = @()
    if ($Plan.PSObject.Properties['ExistingVault'] -and
        $Plan.ExistingVault) { $notes += ('Components register to the existing Vault at <span class="pas-mono">' + (Get-PASUIEscaped $Plan.ExistingVault) + '</span>.') }
    if ($CredentialMode) { $notes += (Get-PASUIEscaped $CredentialMode) }
    foreach ($n in $notes) { [void]$h.Append('<div class="pas-note">').Append($n).Append('</div>') }
    $warnings = @($Plan.Warnings | Where-Object { $_ })
    if ($warnings.Count) {
        [void]$h.Append('<div class="pas-warnlist">')
        foreach ($w in $warnings) { [void]$h.Append('<div class="pas-warnitem">! ').Append((Get-PASUIEscaped $w)).Append('</div>') }
        [void]$h.Append('</div>')
    }
    [void]$h.Append('<div class="pas-foot">Components are installed one after another, in this order. Prepared without contacting any server.</div>')
    return $h.ToString()
}

function ConvertTo-PASUIReadinessHtml {
    <# Rows: @(@{Label;Done;Detail}) — one compact line per thing Install still needs. #>
    param([object[]]$Rows)
    $h = New-Object System.Text.StringBuilder
    [void]$h.Append('<div class="pas-ready">')
    foreach ($r in $Rows) {
        $cls = if ($r.Done) { 'done' } else { 'todo' }
        [void]$h.Append('<div class="pas-ready-row ').Append($cls).Append('"><span class="pas-ready-mark">').Append($(if ($r.Done) { '✓' } else { '○' })).Append('</span>')
        [void]$h.Append('<span class="pas-ready-l">').Append((Get-PASUIEscaped $r.Label)).Append('</span>')
        [void]$h.Append('<span class="pas-ready-d">').Append((Get-PASUIEscaped $r.Detail)).Append('</span></div>')
    }
    return ($h.Append('</div>').ToString())
}

function Merge-PASUIEventHistory {
    <#
      Keeps every event of a run across refreshes. The dashboard polls only the newest events, so a stage's
      "Complete" event must not be forgotten when it falls out of that window (long runs).
      $History: a hashtable owned by the caller (@{} for a new run). Returns all events, oldest first.
    #>
    param([Parameter(Mandatory)][hashtable]$History, [object[]]$Events = @())
    if (-not $History.ContainsKey('Keys')) {
        $History.Keys = @{}
        $History.List = New-Object System.Collections.ArrayList
    }
    $added = $false
    foreach ($e in @($Events | Where-Object { $_ })) {
        $k = '{0}|{1}|{2}|{3}|{4}|{5}' -f $e.TimestampUtc, $e.Component, $e.Stage, $e.Event, $e.Status, $e.Message
        if ($History.Keys.ContainsKey($k)) { continue }
        $History.Keys[$k] = $true
        [void]$History.List.Add($e)
        $added = $true
    }
    if ($added) {
        # Stable ordering by time (Windows PowerShell 5.1 has no Sort-Object -Stable): arrival index breaks ties.
        $i = 0
        $sorted = @($History.List | ForEach-Object {
                [pscustomobject]@{
                    T = [string]$_.TimestampUtc
                    I = $i
                    E = $_
                }
                $i++
            } |
                Sort-Object -Property T, I | ForEach-Object { $_.E })
        $History.List = New-Object System.Collections.ArrayList
        foreach ($e in $sorted) { [void]$History.List.Add($e) }
    }
    return @($History.List)
}

function Get-PASUIStatusClass {
    <# CSS state for a run status or a component status reported by Get-PASRun. #>
    param([string]$Status)
    if ($Status -eq 'Succeeded') {
        return 'complete'
    }
    if ($Status -in @('Launching', 'Running')) {
        return 'running'
    }
    if ($Status -in @('Failed', 'LaunchFailed', 'Unknown', 'Interrupted', 'Blocked', 'Abandoned')) {
        return 'failed'
    }
    return 'pending'   # Pending, Skipped
}

function Test-PASUIRunActive {
    <# True while the controller of a run is still working (the window keeps polling). #>
    param([string]$Status)
    return ($Status -in @('Launching', 'Running'))
}

function ConvertTo-PASUIDashboardHtml {
    <#
      $Snapshot : Get-PASRun -RunId result (or $null before launch)
      $PlanItems: plan items, to show every component with its full stage list (pending in grey)
      $Catalog  : @{Vault=@('LocalPreflight',...); ...} stage names per catalog key
      A component's state comes from the snapshot's Components list; its stage chips come from the events.
      Progress is shown as observed stage counts, never as an estimated percentage.
    #>
    param($Snapshot, [object[]]$PlanItems = @(), [hashtable]$Catalog = @{})
    if (-not $Snapshot) { return '<div class="pas-empty">Nothing is running yet. When you click Install, each component and its stages appear here as the controller reports them.</div>' }
    $events = @($Snapshot.Events)
    $h = New-Object System.Text.StringBuilder
    $runId = [string]$Snapshot.RunId
    $status = [string]$Snapshot.Status
    $active = Test-PASUIRunActive $status
    $statusClass = Get-PASUIStatusClass $status
    $components = @{}
    foreach ($component in @($Snapshot.Components | Where-Object { $_ })) {
        $components[[string]$component.Id] = $component
    }
    $currentName = [string]$Snapshot.CurrentComponent
    foreach ($it in $PlanItems) { if ($it.Id -eq $currentName) { $currentName = Get-PASUIItemName $it } }
    [void]$h.Append('<div class="pas-runhead"><span class="pas-pill ').Append($statusClass).Append('">').Append((Get-PASUIEscaped $status)).Append('</span>')
    [void]$h.Append('<span class="pas-runmeta">')
    $runningNow = @()
    if ($active) {
        foreach ($it in $PlanItems) {
            $lastEvt = @($events | Where-Object { $_.Component -eq $it.Id -and $_.Stage -and $_.Status -ne 'Info' } | Select-Object -Last 1)
            if ($lastEvt.Count -and
                $lastEvt[0].Status -eq 'Running') { $runningNow += ((Get-PASUIItemName $it) + ' / ' + $lastEvt[0].Stage) }
        }
    }
    if ($runningNow.Count) { [void]$h.Append('running: <strong>').Append((Get-PASUIEscaped ($runningNow -join ', '))).Append('</strong> · ') }
    elseif ($currentName) { [void]$h.Append('last: <strong>').Append((Get-PASUIEscaped $currentName)).Append('</strong> / ').Append((Get-PASUIEscaped ([string]$Snapshot.LastStep))).Append(' · ') }
    [void]$h.Append('failures: <strong>').Append([int]$Snapshot.ErrorEvents).Append('</strong></span></div>')
    # The full run id and the run folder: both are needed at the prompt (Get-PASRun, Resume-PASRun).
    [void]$h.Append('<div class="pas-runinfo">Run id <span class="pas-mono">').Append((Get-PASUIEscaped $runId)).Append('</span></div>')
    $runDirectory = [string]$Snapshot.RunDirectory
    if ($runDirectory) {
        [void]$h.Append('<div class="pas-runinfo">Run folder <span class="pas-mono">').Append((Get-PASUIEscaped $runDirectory)).Append('</span></div>')
    }
    if (-not $active -and $status -ne 'Succeeded') {
        $zip = '.\PASeasyInstall-' + $runId.Substring(0, [Math]::Min(8, $runId.Length)) + '.zip'
        [void]$h.Append('<div class="pas-cmds"><div class="pas-cmds-head">The run stopped: ').Append((Get-PASUIEscaped $status))
        if ([string]$Snapshot.Message) { [void]$h.Append(' · ').Append((Get-PASUIEscaped ([string]$Snapshot.Message))) }
        [void]$h.Append('</div><div class="pas-cmds-text">Fix the cause, then continue the same run from a Windows PowerShell prompt. It carries on after the last completed step:</div>')
        [void]$h.Append('<div class="pas-cmd">').Append((Get-PASUIEscaped ('Resume-PASRun -RunId ' + $runId))).Append('</div>')
        [void]$h.Append('<div class="pas-cmds-text">To collect the logs of this run in one ZIP file (no passwords):</div>')
        [void]$h.Append('<div class="pas-cmd">').Append((Get-PASUIEscaped ('Export-PASDiagnostics -RunId ' + $runId + ' -Path ' + $zip))).Append('</div></div>')
    }

    [void]$h.Append('<div class="pas-lanes">')
    $shown = @{}
    foreach ($it in $PlanItems) {
        $shown[[string]$it.Id] = $true
        $stages = @($Catalog[(Get-PASUICatalogKey $it.Type)])
        $mine = @($events | Where-Object { $_.Component -eq $it.Id -and $_.Stage })
        # Informational lines (e.g. "remote attempt ... is Succeeded") never downgrade a stage's state.
        $last = @{}
        foreach ($e in $mine) {
            $s = ([string]$e.Status).ToLowerInvariant()
            if ($s -eq 'info' -and
                $last.ContainsKey([string]$e.Stage)) { continue }
            $last[[string]$e.Stage] = $s
        }
        $done = @($stages | Where-Object { $last[$_] -eq 'complete' }).Count
        $component = $components[[string]$it.Id]
        $componentStatus = ''
        if ($component) {
            $componentStatus = [string]$component.Status
            $laneState = Get-PASUIStatusClass $componentStatus
        } else {
            $laneState = if (@($last.Values | Where-Object { $_ -eq 'failed' }).Count) { 'failed' } elseif ($stages.Count -and
                $done -eq $stages.Count) { 'complete' } elseif ($mine.Count -and
                $active) { 'running' } else { 'pending' }
        }
        [void]$h.Append('<div class="pas-lane ').Append($laneState).Append('"><div class="pas-lane-head"><span class="pas-lane-name">').Append((Get-PASUIEscaped (Get-PASUIItemName $it))).Append('</span>')
        if ((Get-PASUIItemName $it) -ne (Get-PASUIComponentName $it.Type)) { [void]$h.Append('<span class="pas-type">').Append((Get-PASUIEscaped $it.Type)).Append('</span>') }
        $addr = ''
        if ($it.PSObject.Properties['Address']) { $addr = ' · ' + [string]$it.Address }
        [void]$h.Append('<span class="pas-lane-host">').Append((Get-PASUIEscaped ($it.Host + $addr))).Append('</span>')
        if ($componentStatus -and $componentStatus -notin @('Pending', 'Running', 'Succeeded')) {
            [void]$h.Append('<span class="pas-lane-status ').Append($laneState).Append('">').Append((Get-PASUIEscaped $componentStatus)).Append('</span>')
        }
        [void]$h.Append('<span class="pas-lane-count">').Append($done).Append(' / ').Append($stages.Count).Append(' stages</span></div><div class="pas-chips">')
        foreach ($s in $stages) {
            $k = $last[$s]
            if (-not $k) { $k = 'pending' } elseif ($k -notin @('running', 'complete', 'failed', 'warning')) { $k = 'info' }
            # A stage cannot still be running once its component or the run has stopped.
            if ($k -eq 'running' -and $laneState -ne 'running') { $k = $(if ($laneState -eq 'failed') { 'failed' } else { 'info' }) }
            [void]$h.Append('<span class="pas-chip ').Append($k).Append('">').Append((Get-PASUIEscaped $s)).Append('</span>')
        }
        [void]$h.Append('</div>')
        if ($component -and [string]$component.Message -and $componentStatus -ne 'Succeeded') {
            [void]$h.Append('<div class="pas-lane-msg">').Append((Get-PASUIEscaped ([string]$component.Message))).Append('</div>')
        }
        [void]$h.Append('</div>')
    }
    # Components the run reports that are not plan items (for example domain joins): state only.
    foreach ($component in @($Snapshot.Components | Where-Object { $_ -and -not $shown.ContainsKey([string]$_.Id) })) {
        $laneState = Get-PASUIStatusClass ([string]$component.Status)
        [void]$h.Append('<div class="pas-lane ').Append($laneState).Append('"><div class="pas-lane-head"><span class="pas-lane-name">').Append((Get-PASUIEscaped ([string]$component.Id))).Append('</span>')
        [void]$h.Append('<span class="pas-type">').Append((Get-PASUIEscaped ([string]$component.Type))).Append('</span><span class="pas-lane-host"></span>')
        [void]$h.Append('<span class="pas-lane-status ').Append($laneState).Append('">').Append((Get-PASUIEscaped ([string]$component.Status))).Append('</span></div>')
        if ([string]$component.Message) {
            [void]$h.Append('<div class="pas-lane-msg">').Append((Get-PASUIEscaped ([string]$component.Message))).Append('</div>')
        }
        [void]$h.Append('</div>')
    }
    [void]$h.Append('</div><div class="pas-stream-head">Event log · newest first</div><div class="pas-stream">')
    foreach ($evt in @($events | Select-Object -Last 40)[-1..-40]) {
        if ($null -eq $evt) { continue }
        $state = ([string]$evt.Status).ToLowerInvariant()
        if ($state -notin @('running', 'complete', 'failed', 'warning')) { $state = 'info' }
        $clock = ''
        try { $clock = ([datetime]$evt.TimestampUtc).ToLocalTime().ToString('HH:mm:ss') } catch { $clock = [string]$evt.TimestampUtc }
        [void]$h.Append('<div class="pas-event"><span class="pas-dot ').Append($state).Append('"></span><span class="pas-time">').Append((Get-PASUIEscaped $clock)).Append('</span>')
        [void]$h.Append('<span class="pas-evt-comp">').Append((Get-PASUIEscaped ([string]$evt.Component))).Append('</span><span class="pas-evt-msg"><strong>')
        [void]$h.Append((Get-PASUIEscaped ([string]$evt.Event))).Append('</strong> ').Append((Get-PASUIEscaped ([string]$evt.Message))).Append('</span></div>')
    }
    if (-not $events.Count) { [void]$h.Append('<div class="pas-empty">Controller started. Waiting for the first event…</div>') }
    [void]$h.Append('</div>')
    if ($status -eq 'Succeeded') {
        [void]$h.Append('<div class="pas-foot">Installer workflow completed. That alone does not prove every PAM integration works — run the component health checks before production use.</div>')
    }
    return $h.ToString()
}

$script:PASUIMediaOrder = @(
    @{C = 'Vault'; L = 'Vault server' }, @{C = 'PACLI'; L = 'PACLI' }, @{C = 'DR'; L = 'DR Vault' }, @{C = 'PVWA'; L = 'PVWA' }, @{C = 'CPM'; L = 'CPM' },
    @{C = 'PSM'; L = 'PSM' }, @{C = 'PSMP'; L = 'PSMP' }, @{C = 'License'; L = 'License' }, @{C = 'RecoveryKey'; L = 'Recovery key' })
function ConvertTo-PASUIMediaHtml {
    <# Detection chips + what was not recognised. The chosen installer per component is shown by the
       dropdowns the app renders below this block; alternatives live inside those dropdowns. #>
    param([object[]]$Inventory = @(), [hashtable]$Selection = @{}, [string[]]$Sources = @())
    $h = New-Object System.Text.StringBuilder
    [void]$h.Append('<div class="pas-detect">')
    foreach ($m in $script:PASUIMediaOrder) {
        $item = $Selection[$m.C]
        $cls = if ($item) { 'found' } else { 'missing' }
        $ver = ''
        if ($item) {
            $ver = if ($m.C -eq 'PSMP' -and
                $item.Variant) { ' ' + $item.Variant } elseif ($item.Version) { ' ' + $item.Version } else { '' }
        }
        [void]$h.Append('<span class="pas-det ').Append($cls).Append('">').Append($(if ($item) { '✓ ' } else { '· ' }))
        [void]$h.Append((Get-PASUIEscaped $m.L)).Append('<em>').Append((Get-PASUIEscaped $ver)).Append('</em></span>')
    }
    [void]$h.Append('</div>')
    if (-not @($Sources).Count) {
        [void]$h.Append('<div class="pas-empty">No media added yet. What you can install is worked out from what you add here.</div>')
        return $h.ToString()
    }
    $other = @($Inventory | Where-Object { $_.Component -in @('Unknown', 'Missing') })
    if ($other.Count) {
        $names = @($other | ForEach-Object { if ($_.Component -eq 'Missing') { $_.Name + ' (not found)' } else { $_.Name } }) |
            Select-Object -Unique
        [void]$h.Append('<div class="pas-note">Not CyberArk PAM installers, ignored: ').Append((Get-PASUIEscaped ($names -join ', '))).Append('</div>')
    }
    [void]$h.Append('<div class="pas-note">Added: ').Append((Get-PASUIEscaped ((@($Sources) | ForEach-Object { [IO.Path]::GetFileName($_.TrimEnd('/', '\')) }) -join ', '))).Append('</div>')
    return $h.ToString()
}
function Get-PASUIMediaOptionLabel {
    param($Item, [bool]$Recommended)
    $parts = @()
    if ($Item.Version) { $parts += $Item.Version }
    if ($Item.Variant) { $parts += $Item.Variant }
    $label = (@($parts) + @($Item.Name)) -join '  ·  '
    if ($Recommended) { $label = '★ ' + $label + '  (recommended)' }
    return $label
}
function ConvertTo-PASUIOptionsHtml {
    <# <option> list for one installer dropdown. Values are indexes into the candidate list. #>
    param([object[]]$Candidates = @(), [int]$Selected = 0, [int]$Recommended = 0)
    $h = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt @($Candidates).Count; $i++) {
        [void]$h.Append('<option value="').Append($i).Append('"')
        if ($i -eq $Selected) { [void]$h.Append(' selected') }
        [void]$h.Append('>').Append((Get-PASUIEscaped (Get-PASUIMediaOptionLabel $Candidates[$i] ($i -eq $Recommended)))).Append('</option>')
    }
    return $h.ToString()
}
function ConvertTo-PASUIComponentMediaHtml {
    <# One line under the component checkboxes: which installers were found. #>
    param([hashtable]$Selection = @{})
    $found = @('PVWA', 'CPM', 'PSM', 'PSMP' | Where-Object { $Selection[$_] })
    $missing = @('PVWA', 'CPM', 'PSM', 'PSMP' | Where-Object { -not $Selection[$_] })
    $t = if ($found.Count) { 'Installers found for ' + ($found -join ', ') + '.' } else { 'No component installers found in the media yet.' }
    if ($missing.Count -and $found.Count) { $t += ' Not found: ' + ($missing -join ', ') + '.' }
    return '<div class="pas-note">' + (Get-PASUIEscaped $t) + '</div>'
}
