# The data behind the desktop window: what the user chose and what follows from it.
# Nothing here opens a window or calls the installer, so every function can be tested on its own.

$script:PASUIComponentTypes = @('PVWA', 'CPM', 'PSM', 'PSMP')

$script:PASUITypeNames = @{
    Vault = 'Vault'
    DRVault = 'DR Vault'
    DR = 'DR Vault'
    PVWA = 'PVWA (web portal)'
    CPM = 'CPM (password changes)'
    PSM = 'PSM (session recording)'
    PSMP = 'PSMP (SSH sessions)'
    AD = 'Domain controller'
}

$script:PASUIMediaNames = [ordered]@{
    Vault = 'Vault server'
    PACLI = 'PACLI (Vault command line)'
    KeyGen = 'Key generator'
    DR = 'Disaster Recovery'
    PVWA = 'PVWA'
    CPM = 'CPM'
    PSM = 'PSM'
    PSMP = 'PSMP (Linux)'
    License = 'Vault license (license.xml)'
    RecoveryKey = 'Recovery public key (recpub.key)'
    Prerequisite = 'Visual C++ runtimes'
}

$script:PASUIStageNames = @{
    'media-upload' = 'Copying the installer'
    'pvwa-trust-certificate' = 'Copying the PVWA certificate'
    'preflight' = 'Checking the server'
    'extract' = 'Unpacking the installer'
    'prerequisites' = 'Preparing the server'
    'install' = 'Installing'
    'configuretls' = 'Setting up HTTPS'
    'register' = 'Registering with the Vault'
    'harden' = 'Hardening'
    'hardening' = 'Hardening'
    'postinstall' = 'Finishing the installation'
    'verify' = 'Verifying'
    'ssh-bootstrap' = 'Setting up the SSH key'
    'media-select' = 'Choosing the installer package'
}

function New-PASUIState {
    # The state of one window. One hashtable, changed in place by the actions.
    param([string]$Backend = 'Live', [string]$StartDirectory = '', [string]$ControllerAddress = '')
    return @{
        Backend = $Backend
        StartDirectory = $StartDirectory
        Screen = 'home'
        Advanced = $false
        Notice = $null

        MediaPath = ''
        MediaSources = @()
        MediaItems = @()
        MediaSelection = @{}
        MediaScanned = $false

        LabName = 'MyPAM'
        Preset = 'standard'
        VaultMode = 'Primary'
        Counts = @{ PVWA = 1; CPM = 1; PSM = 1; PSMP = 0 }
        Colocate = $true
        ExistingVault = ''

        # Per server: Name, Address, User, Password. Vault passwords: VaultAdmin, VaultMaster, DRPassword.
        Slots = @{}
        Secrets = @{}
        Controller = $ControllerAddress
        # "Who installs" (Advanced): empty means the vendor defaults.
        InstallerName = ''
        InstallerCompany = ''
        AcceptEula = $false

        # Server check of the Servers step: running, and the configuration it passed for.
        Checking = $false
        # An installation is being started in the background: the accounts it was started with, else $null.
        Starting = $null
        # Accounts and Vault passwords of the installation started from this window (protected in memory),
        # so that "Try again" and "Check the lab" do not ask for them again while the window stays open.
        Kept = $null

        Configuration = $null
        Check = $null
        Plan = $null
        Requirements = @()
        Preflight = $null

        Runs = @()
        RunId = ''
        Run = $null
        RunPlan = @{}
        Health = $null
        Pending = $null
        DialogRequirements = @()
        Polling = $false
        ResumeUntil = $null
    }
}

function Get-PASUIPresets {
    # The ready-made labs of the "What to build" step.
    return @(
        @{ Id = 'starter'; Title = 'Starter'; What = 'Vault, web portal and password changes.'
            VaultMode = 'Primary'; Counts = @{ PVWA = 1; CPM = 1; PSM = 0; PSMP = 0 } }
        @{ Id = 'standard'; Title = 'Standard'; What = 'Starter plus recorded sessions through PSM.'
            VaultMode = 'Primary'; Counts = @{ PVWA = 1; CPM = 1; PSM = 1; PSMP = 0 }; Recommended = $true }
        @{ Id = 'full'; Title = 'Full'; What = 'Standard plus a DR Vault and SSH sessions through PSMP.'
            VaultMode = 'PrimaryDR'; Counts = @{ PVWA = 1; CPM = 1; PSM = 1; PSMP = 1 } }
        @{ Id = 'custom'; Title = 'Custom'; What = 'Choose every part yourself, or add to a Vault you already have.'
            VaultMode = ''; Counts = $null }
    )
}

function Set-PASUIPreset {
    param([hashtable]$State, [string]$Id)
    $State.Preset = $Id
    foreach ($preset in Get-PASUIPresets) {
        if ($preset.Id -ne $Id -or -not $preset.Counts) {
            continue
        }
        $State.VaultMode = $preset.VaultMode
        $State.Colocate = $true
        foreach ($type in $script:PASUIComponentTypes) {
            $State.Counts[$type] = [int]$preset.Counts[$type]
        }
    }
}

function Get-PASUIMaxCount {
    # Two of each is what was tested. The advanced view allows the four the installer accepts.
    param([hashtable]$State)
    if ($State.Advanced) {
        return 4
    }
    return 2
}

function Get-PASUIServerSlots {
    # The servers the chosen lab needs, in installation order. A slot is one server:
    # Key (stable id), Roles (text), Types, Os, DefaultName, Named (the computer name matters).
    param([hashtable]$State)
    $slots = New-Object System.Collections.ArrayList
    if ($State.VaultMode -ne 'Existing') {
        [void]$slots.Add(@{ Key = 'vault'; Roles = 'Vault'; Types = @('Vault'); Os = 'Windows'; DefaultName = ''; Named = $false })
        if ($State.VaultMode -eq 'PrimaryDR') {
            [void]$slots.Add(@{ Key = 'dr'; Roles = 'DR Vault'; Types = @('DRVault'); Os = 'Windows'; DefaultName = ''; Named = $false })
        }
    }
    $pvwa = [int]$State.Counts.PVWA
    $cpm = [int]$State.Counts.CPM
    for ($i = 1; $i -le $pvwa; $i++) {
        $types = @('PVWA')
        $roles = 'PVWA'
        if ($State.Colocate -and $i -le $cpm) {
            $types = @('PVWA', 'CPM')
            $roles = 'PVWA + CPM'
        }
        [void]$slots.Add(@{ Key = "pvwa$i"; Roles = $roles; Types = $types; Os = 'Windows'; DefaultName = ('PVWA{0:00}' -f $i); Named = $true })
    }
    for ($i = 1; $i -le $cpm; $i++) {
        if ($State.Colocate -and $i -le $pvwa) {
            continue
        }
        [void]$slots.Add(@{ Key = "cpm$i"; Roles = 'CPM'; Types = @('CPM'); Os = 'Windows'; DefaultName = ('CPM{0:00}' -f $i); Named = $true })
    }
    for ($i = 1; $i -le [int]$State.Counts.PSM; $i++) {
        [void]$slots.Add(@{ Key = "psm$i"; Roles = 'PSM'; Types = @('PSM'); Os = 'Windows'; DefaultName = ('PSM{0:00}' -f $i); Named = $true })
    }
    for ($i = 1; $i -le [int]$State.Counts.PSMP; $i++) {
        [void]$slots.Add(@{ Key = "psmp$i"; Roles = 'PSMP'; Types = @('PSMP'); Os = 'Linux'; DefaultName = ('psmp{0:00}' -f $i); Named = $true })
    }
    return @($slots)
}

function Get-PASUISlotValue {
    # What the user typed for a server: Field is Name, Address, User or Password.
    # A name falls back to the default name, an account to Administrator (Windows) or root (Linux).
    # A password is returned exactly as typed.
    param([hashtable]$State, [hashtable]$Slot, [string]$Field)
    $value = ''
    if ($State.Slots.ContainsKey($Slot.Key) -and $State.Slots[$Slot.Key].ContainsKey($Field)) {
        $value = [string]$State.Slots[$Slot.Key][$Field]
    }
    if ($Field -eq 'Password') {
        return $value
    }
    $value = $value.Trim()
    if (-not $value -and $Field -eq 'Name') {
        return [string]$Slot.DefaultName
    }
    if (-not $value -and $Field -eq 'User') {
        if ($Slot.Os -eq 'Linux') {
            return 'root'
        }
        return 'Administrator'
    }
    return $value
}

function Get-PASUIVaultSecrets {
    # The Vault passwords the chosen lab needs: Key (as Install-PASLab wants it), Label, Hint.
    param([hashtable]$State)
    if ($State.VaultMode -eq 'Existing') {
        return @(@{ Key = 'VaultAdmin'; Label = 'Password of the Vault user Administrator'; Hint = 'The password it has now. Used to register the components.' })
    }
    $fields = @(
        @{ Key = 'VaultAdmin'; Label = 'Vault Administrator password'; Hint = 'New Vault: the password to set.' }
        @{ Key = 'VaultMaster'; Label = 'Vault Master password'; Hint = 'New Vault: the password to set.' }
    )
    if ($State.VaultMode -eq 'PrimaryDR') {
        $fields += @{ Key = 'DRPassword'; Label = 'Vault DR user password'; Hint = 'The password to set for the user the DR Vault replicates with.' }
    }
    return @($fields)
}

function Set-PASUISlotValue {
    param([hashtable]$State, [string]$Key, [string]$Field, [string]$Value)
    if (-not $State.Slots.ContainsKey($Key)) {
        $State.Slots[$Key] = @{}
    }
    $State.Slots[$Key][$Field] = $Value
}

function Get-PASUIInstances {
    # The -Instances list of New-PASLabConfiguration. A CPM on the PVWA server gets the PVWA's address.
    param([hashtable]$State)
    $instances = New-Object System.Collections.ArrayList
    $cpmNumber = 0
    foreach ($slot in Get-PASUIServerSlots $State) {
        $address = Get-PASUISlotValue $State $slot 'Address'
        $name = Get-PASUISlotValue $State $slot 'Name'
        foreach ($type in $slot.Types) {
            if ($type -in @('Vault', 'DRVault')) {
                continue
            }
            $instanceName = $name
            if ($type -eq 'CPM' -and $slot.Types.Count -gt 1) {
                $cpmNumber++
                $instanceName = ('CPM{0:00}' -f $cpmNumber)
            } elseif ($type -eq 'CPM') {
                $cpmNumber++
            }
            [void]$instances.Add(@{ Type = $type; Name = $instanceName; Address = $address; Username = (Get-PASUISlotValue $State $slot 'User') })
        }
    }
    return @($instances)
}

function Get-PASUIInputIssues {
    # What is still missing on a step, in the user's words. Empty list: the step is complete.
    param([hashtable]$State, [string]$Screen)
    $issues = New-Object System.Collections.ArrayList
    if ($Screen -eq 'media') {
        if (-not $State.MediaScanned) {
            [void]$issues.Add('Choose the folder that holds the CyberArk installer media.')
        } elseif (-not @($State.MediaItems).Count) {
            [void]$issues.Add('No CyberArk installer was recognised in that folder.')
        }
    }
    if ($Screen -eq 'lab') {
        if ([string]$State.LabName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') {
            [void]$issues.Add('Give the lab a short name: letters, digits, dot, dash or underscore.')
        }
        $total = 0
        foreach ($type in $script:PASUIComponentTypes) {
            $total += [int]$State.Counts[$type]
        }
        if ($State.VaultMode -eq 'Existing' -and $total -eq 0) {
            [void]$issues.Add('With an existing Vault, choose at least one component to add.')
        }
        foreach ($missing in Get-PASUIMissingMedia $State) {
            [void]$issues.Add("The media folder has no installer for: $missing.")
        }
    }
    if ($Screen -eq 'servers') {
        $seen = @{}
        foreach ($slot in Get-PASUIServerSlots $State) {
            $address = Get-PASUISlotValue $State $slot 'Address'
            if (-not $address) {
                [void]$issues.Add("Enter the address of the $($slot.Roles) server.")
                continue
            }
            if ($address -notmatch '^[A-Za-z0-9][A-Za-z0-9.:-]*$') {
                [void]$issues.Add("'$address' is not an IP address or a DNS name.")
            }
            if ($seen.ContainsKey($address.ToLowerInvariant())) {
                [void]$issues.Add("$address is used for two servers. Every server needs its own address.")
            }
            $seen[$address.ToLowerInvariant()] = $true
            if ($slot.Named -and (Get-PASUISlotValue $State $slot 'Name') -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$') {
                [void]$issues.Add("The computer name of the $($slot.Roles) server may hold letters, digits and dashes only.")
            }
        }
        foreach ($slot in Get-PASUIServerSlots $State) {
            if (-not (Get-PASUISlotValue $State $slot 'Password')) {
                [void]$issues.Add("Enter the password of $(Get-PASUISlotValue $State $slot 'User') on the $($slot.Roles) server.")
            }
        }
        if ($State.VaultMode -eq 'Existing' -and -not ([string]$State.ExistingVault).Trim()) {
            [void]$issues.Add('Enter the address of the Vault you already have.')
        }
        foreach ($field in Get-PASUIVaultSecrets $State) {
            $value = ''
            if ($State.Secrets.ContainsKey($field.Key)) {
                $value = [string]$State.Secrets[$field.Key]
            }
            if (-not $value) {
                [void]$issues.Add("Enter the $($field.Label).")
            } elseif ($value -notmatch '^[\x21\x23-\x7E]+$') {
                [void]$issues.Add("The $($field.Label) may hold letters, digits and the usual signs, but no space and no double quote.")
            }
        }
        if ([int]$State.Counts.PSMP -gt 0 -and -not $State.AcceptEula) {
            [void]$issues.Add('Accept the CyberArk license agreement of the PSMP installer.')
        }
    }
    return @($issues)
}

function Get-PASUIMissingMedia {
    # Names of the parts of the chosen lab that have no installer in the media folder.
    param([hashtable]$State)
    $need = @()
    if ($State.VaultMode -ne 'Existing') {
        $need += 'Vault'
    }
    if ($State.VaultMode -eq 'PrimaryDR') {
        $need += 'DR'
    }
    foreach ($type in $script:PASUIComponentTypes) {
        if ([int]$State.Counts[$type] -gt 0) {
            $need += $type
        }
    }
    $missing = @()
    foreach ($kind in $need) {
        if (-not $State.MediaSelection.ContainsKey($kind)) {
            $missing += [string]$script:PASUIMediaNames[$kind]
        }
    }
    return @($missing)
}

function Get-PASUIMediaPaths {
    # Everything the media is read from: the folder in the text field and what was dropped on the window.
    param([hashtable]$State)
    $paths = @()
    $typed = ([string]$State.MediaPath).Trim().Trim('"')
    if ($typed) {
        $paths += $typed
    }
    foreach ($source in @($State.MediaSources)) {
        if ($source -and $paths -notcontains [string]$source) {
            $paths += [string]$source
        }
    }
    return @($paths)
}

function Add-PASUIMediaDrop {
    # Files or folders dropped on the window. One folder alone becomes the media folder;
    # anything else is added to the list of sources.
    param([hashtable]$State, [string[]]$Paths, [bool[]]$IsFolder)
    $list = @($Paths | Where-Object { $_ })
    if ($list.Count -eq 1 -and $IsFolder.Count -eq 1 -and $IsFolder[0] -and -not @($State.MediaSources).Count) {
        $State.MediaPath = [string]$list[0]
        return
    }
    foreach ($path in $list) {
        if (@($State.MediaSources) -notcontains $path) {
            $State.MediaSources = @($State.MediaSources) + $path
        }
    }
}

function Get-PASUIMediaRows {
    # One row per kind of media: Kind, Label, Found, Detail (file name and version).
    param([hashtable]$State)
    $rows = New-Object System.Collections.ArrayList
    foreach ($kind in $script:PASUIMediaNames.Keys) {
        $found = @($State.MediaItems | Where-Object { [string]$_.Component -eq $kind })
        $detail = ''
        if ($State.MediaSelection.ContainsKey($kind)) {
            $item = $State.MediaSelection[$kind]
            $detail = [string]$item.Name
            if ([string]$item.Version) {
                $detail = 'version ' + [string]$item.Version + ' (' + [string]$item.Name + ')'
            }
        } elseif ($found.Count) {
            $detail = (@($found | ForEach-Object { [string]$_.Name } | Select-Object -Unique) -join ', ')
        }
        $isFound = [bool]$found.Count
        if ($kind -eq 'Prerequisite' -and -not $isFound) {
            # The CPM, PVWA and PSM installers carry the runtimes; the Vault installation takes them from there.
            $carrier = @('CPM', 'PVWA', 'PSM' | Where-Object { $State.MediaSelection.ContainsKey($_) } | Select-Object -First 1)
            if ($carrier.Count) {
                $isFound = $true
                $detail = 'taken from the ' + $carrier[0] + ' installer'
            }
        }
        [void]$rows.Add([pscustomobject]@{
                Kind = [string]$kind
                Label = [string]$script:PASUIMediaNames[$kind]
                Found = $isFound
                Detail = $detail
            })
    }
    return @($rows)
}

function Get-PASUIEstimateMinutes {
    # A rough duration from the lab runs of November 2026: good enough to plan a coffee.
    param([hashtable]$State)
    $minutes = 0
    if ($State.VaultMode -ne 'Existing') {
        $minutes += 12
    }
    if ($State.VaultMode -eq 'PrimaryDR') {
        $minutes += 8
    }
    $minutes += 7 * [int]$State.Counts.PVWA
    $minutes += 3 * [int]$State.Counts.CPM
    $minutes += 13 * [int]$State.Counts.PSM
    $minutes += 3 * [int]$State.Counts.PSMP
    return $minutes
}

function Get-PASUICommandText {
    # The same installation from the PowerShell prompt, for the advanced view. No password in it.
    param([hashtable]$State)
    $lines = New-Object System.Collections.ArrayList
    $paths = (@(Get-PASUIMediaPaths $State | ForEach-Object { "'" + $_ + "'" }) -join ', ')
    [void]$lines.Add('$media = Get-PASMediaInventory -Path ' + $paths + ' | Get-PASMediaSelection')
    $instances = @(Get-PASUIInstances $State | ForEach-Object { "@{Type='$($_.Type)';Name='$($_.Name)';Address='$($_.Address)';Username='$($_.Username)'}" })
    $command = '$lab = New-PASLabConfiguration -Environment ' + [string]$State.LabName + ' -VaultMode ' + [string]$State.VaultMode
    foreach ($slot in Get-PASUIServerSlots $State) {
        if ($slot.Key -eq 'vault') {
            $command += ' -PrimaryAddress ' + (Get-PASUISlotValue $State $slot 'Address')
        }
        if ($slot.Key -eq 'dr') {
            $command += ' -DRAddress ' + (Get-PASUISlotValue $State $slot 'Address')
        }
    }
    if ($State.VaultMode -eq 'Existing') {
        $command += ' -ExistingVaultAddress ' + [string]$State.ExistingVault
    }
    $command += ' -ControllerAddress ' + [string]$State.Controller + ' -Media $media -SecurityProfile Lab'
    if ($State.AcceptEula) {
        $command += ' -AcceptEula'
    }
    if ($instances.Count) {
        $command += " ``" + "`n    -Instances @(" + ($instances -join ', ') + ')'
    }
    [void]$lines.Add($command)
    [void]$lines.Add('# Asks for the account of every server and for the Vault passwords:')
    [void]$lines.Add('Install-PASLab -Configuration $lab -Wait')
    return ($lines -join "`n")
}

function Get-PASUIStatusKind {
    # Maps a run or component status to one of four looks: ok, run, bad, idle.
    param([string]$Status)
    switch ($Status) {
        'Succeeded' { return 'ok' }
        'Running' { return 'run' }
        'Launching' { return 'run' }
        'Starting' { return 'run' }
        'Failed' { return 'bad' }
        'LaunchFailed' { return 'bad' }
        'Unknown' { return 'bad' }
        'Interrupted' { return 'bad' }
        'Blocked' { return 'bad' }
    }
    return 'idle'
}

function Get-PASUIStatusText {
    # A run status in plain words.
    param([string]$Status)
    switch ($Status) {
        'Succeeded' { return 'Finished' }
        'Running' { return 'Installing' }
        'Launching' { return 'Starting' }
        'Starting' { return 'Starting' }
        'Failed' { return 'Stopped with an error' }
        'LaunchFailed' { return 'Could not start' }
        'Unknown' { return 'Stopped, result unclear' }
        'Interrupted' { return 'Interrupted' }
        'Blocked' { return 'Blocked by another installation' }
        'Abandoned' { return 'Stopped by you' }
        'Pending' { return 'Waiting' }
    }
    return $Status
}

function Test-PASUIRunActive {
    param([string]$Status)
    return ($Status -in @('Running', 'Launching', 'Starting'))
}

function Get-PASUIStageText {
    param([string]$Stage)
    if (-not $Stage) {
        return ''
    }
    if ($script:PASUIStageNames.ContainsKey($Stage)) {
        return [string]$script:PASUIStageNames[$Stage]
    }
    if ($Stage -match 'reboot') {
        return 'Restarting the server'
    }
    $text = $Stage -replace '-', ' '
    return ($text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1))
}

function Get-PASUIRunProgress {
    # What the run page shows: per component Done/Total steps and the current step; plus the totals.
    # Catalog: @{ <type> = <number of steps> }. PlanItems: @{ <component id> = @{ Address } }.
    param($Snapshot, [hashtable]$Catalog = @{}, [hashtable]$PlanItems = @{})
    $events = @($Snapshot.Events)
    $rows = New-Object System.Collections.ArrayList
    $doneAll = 0
    $totalAll = 0
    foreach ($component in @($Snapshot.Components)) {
        $id = [string]$component.Id
        $type = [string]$component.Type
        $mine = @($events | Where-Object { [string]$_.Component -eq $id -and [string]$_.Stage })
        $finished = @($mine | Where-Object { [string]$_.Event -in @('TaskCompleted', 'TaskRevalidated') } | ForEach-Object { [string]$_.Stage } | Select-Object -Unique)
        $total = 0
        $catalogKey = $type
        if ($type -eq 'DRVault') {
            $catalogKey = 'DR'
        }
        if ($Catalog.ContainsKey($catalogKey)) {
            $total = [int]$Catalog[$catalogKey]
        }
        $done = $finished.Count
        if ($done -gt $total) {
            $total = $done
        }
        $status = [string]$component.Status
        if ($status -eq 'Succeeded') {
            if ($total -eq 0) {
                $total = 1
            }
            $done = $total
        }
        $current = ''
        if ($mine.Count -and $status -ne 'Succeeded') {
            $current = [string]$mine[-1].Stage
        }
        $address = ''
        if ($PlanItems.ContainsKey($id)) {
            $address = [string]$PlanItems[$id].Address
        }
        $percent = 0
        if ($total -gt 0) {
            $percent = [int][math]::Floor(100 * $done / $total)
        }
        [void]$rows.Add([pscustomobject]@{
                Id = $id
                Type = $type
                Status = $status
                Kind = (Get-PASUIStatusKind $status)
                Message = [string]$component.Message
                Address = $address
                Done = $done
                Total = $total
                Percent = $percent
                Current = $current
            })
        $doneAll += $done
        $totalAll += $total
    }
    $percentAll = 0
    if ($totalAll -gt 0) {
        $percentAll = [int][math]::Floor(100 * $doneAll / $totalAll)
    }
    if ([string]$Snapshot.Status -eq 'Succeeded') {
        $percentAll = 100
    }
    return [pscustomobject]@{
        Components = @($rows)
        Done = $doneAll
        Total = $totalAll
        Percent = $percentAll
    }
}

function Get-PASUIFailure {
    # The step that stopped a run: Component, Stage, Message and the retry step for Resume-PASRun.
    param($Snapshot)
    $failed = @($Snapshot.Events | Where-Object { [string]$_.Status -in @('Failed', 'Unknown') -and [string]$_.Stage }) | Select-Object -Last 1
    if (-not $failed) {
        return $null
    }
    return [pscustomobject]@{
        Component = [string]$failed.Component
        Stage = [string]$failed.Stage
        Message = [string]$failed.Message
        RetryStep = ([string]$failed.Component + ':' + [string]$failed.Stage)
    }
}

function Format-PASUIWhen {
    # A UTC time stamp as local "21 Nov 14:05". Empty when it cannot be read.
    param([string]$Utc)
    if (-not $Utc) {
        return ''
    }
    $when = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetime]::TryParse($Utc, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$when)) {
        return ''
    }
    return $when.ToLocalTime().ToString('d MMM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-PASUITime {
    # A UTC time stamp as local "14:05:09", for the activity log.
    param([string]$Utc)
    $when = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not $Utc -or -not [datetime]::TryParse($Utc, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$when)) {
        return ''
    }
    return $when.ToLocalTime().ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-PASUIEventKind {
    # How a log line is coloured: bad (failed), warn, ok (a step finished), run (a step started), or nothing.
    param($Entry)
    if ([string]$Entry.Status -in @('Failed', 'Unknown') -or [string]$Entry.Level -eq 'Error') {
        return 'bad'
    }
    if ([string]$Entry.Level -eq 'Warning' -or [string]$Entry.Event -eq 'Warning') {
        return 'warn'
    }
    if ([string]$Entry.Event -in @('TaskCompleted', 'TaskRevalidated', 'RunCompleted', 'ComponentCompleted')) {
        return 'ok'
    }
    if ([string]$Entry.Event -in @('TaskStarted', 'RunStarted', 'RunResumed', 'ControllerLaunched')) {
        return 'run'
    }
    return ''
}

function Format-PASUIDuration {
    # Minutes between two UTC time stamps (or until now) as "42 min" or "1 h 05 min".
    param([string]$StartUtc, [string]$EndUtc = '')
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $start = [datetime]::MinValue
    if (-not [datetime]::TryParse($StartUtc, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$start)) {
        return ''
    }
    $end = [datetime]::UtcNow
    if ($EndUtc) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($EndUtc, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            $end = $parsed
        }
    }
    $minutes = [int][math]::Max(0, [math]::Floor(($end - $start).TotalMinutes))
    if ($minutes -lt 60) {
        return "$minutes min"
    }
    return ('{0} h {1:00} min' -f [int][math]::Floor($minutes / 60), ($minutes % 60))
}
