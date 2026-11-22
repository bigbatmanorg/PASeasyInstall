# The data behind the desktop window: what the user chose and what follows from it.
# Nothing here opens a window or calls the installer, so every function can be tested on its own.

$script:PASUIComponentTypes = @('PVWA', 'CPM', 'PSM', 'PSMP', 'HTML5GW', 'PTA')

$script:PASUITypeNames = @{
    Vault = 'Vault'
    DRVault = 'DR Vault'
    DR = 'DR Vault'
    PVWA = 'PVWA (web portal)'
    CPM = 'CPM (password changes)'
    PSM = 'PSM (session recording)'
    PSMP = 'PSMP (SSH sessions)'
    HTML5GW = 'HTML5 Gateway (sessions in the browser)'
    PTA = 'PTA (threat analytics)'
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
    HTML5GW = 'HTML5 Gateway (Linux)'
    PTA = 'PTA (Linux)'
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
    'certificate' = 'Creating the HTTPS certificate'
    'configuretls' = 'Setting up HTTPS'
    'register' = 'Registering with the Vault'
    'harden' = 'Hardening'
    'hardening' = 'Hardening'
    'postinstall' = 'Finishing the installation'
    'verify' = 'Verifying'
    'ssh-bootstrap' = 'Setting up the SSH key'
    'media-select' = 'Choosing the installer package'
    'ad-prerequisites' = 'Preparing the domain controller'
    'ad-install' = 'Creating the domain'
    'ad-verify' = 'Verifying the domain'
    'dns' = 'Pointing the server at the domain'
    'join' = 'Joining the domain'
    'local-admin' = 'Giving the domain account administrator rights'
    'rpm-signing-key' = 'Copying the CyberArk signing key'
    'pta-trust' = 'Making PVWA trust PTA'
    'pacli-upload' = 'Copying PACLI to the PVWA server'
    'gateway-register' = 'Registering the gateway in PVWA'
    'gpo-firewall' = 'Allowing the management port in the firewall'
    'gpo-import' = 'Importing the CyberArk hardening GPOs'
    'gpo-apply' = 'Applying the CyberArk hardening GPO'
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

        # Work that is under way in the background: the list of installations, the media scan.
        RunsLoading = $false
        Scanning = $false

        MediaPath = ''
        MediaSources = @()
        MediaItems = @()
        MediaSelection = @{}
        MediaScanned = $false

        LabName = 'MyPAM'
        Preset = 'standard'
        VaultMode = 'Primary'
        Counts = @{ PVWA = 1; CPM = 1; PSM = 1; PSMP = 0; HTML5GW = 0; PTA = 0 }
        # CPM on the PVWA server (one server less), in every lab that has both. Off: CPM gets its own server.
        Colocate = $true
        # Advanced: apply the vendor hardening. Off: the lab is installed without it (New-PASLabConfiguration -SkipHardening).
        Hardening = $true
        ExistingVault = ''
        # Active Directory: None, New (a new forest on one more server) or Existing.
        Domain = 'None'
        DomainName = 'pam.lab'

        # Per server: Name, Address, User, Password. Vault passwords: VaultAdmin, VaultMaster, DRPassword.
        # The window writes only a mark ('set') for a password that is typed; the password itself stays in
        # its password box as a SecureString. The checks below need no more than "typed or not".
        Slots = @{}
        Secrets = @{}
        Controller = $ControllerAddress
        # "Who installs" (Advanced): empty means the vendor defaults.
        InstallerName = ''
        # PTA (Advanced): the time zone of the Vault server as a tz database name; empty means UTC.
        VaultTimezone = ''
        InstallerCompany = ''
        AcceptEula = $false

        # Server check of the Servers step: running, and the configuration it passed for.
        Checking = $false
        # Which part of the server check runs: 'reach' (does each server answer) or 'signin'.
        CheckPhase = ''
        # An installation is being started in the background: the accounts it was started with, else $null.
        Starting = $null
        # The accounts of the Servers form while the server check runs.
        CheckAccounts = $null
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
        # The activity log of the installation page is unfolded.
        LogOpen = $false
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
        foreach ($type in $script:PASUIComponentTypes) {
            $State.Counts[$type] = [int]$preset.Counts[$type]
        }
    }
}

function Test-PASUIAdvancedApplies {
    # Does the current page have anything that only the Advanced switch shows? The switch is hidden elsewhere.
    param([hashtable]$State)
    if ([string]$State.Screen -in @('servers', 'review', 'run')) {
        return $true
    }
    # The Custom lab allows more instances of a component in the advanced view.
    return ([string]$State.Screen -eq 'lab' -and [string]$State.Preset -eq 'custom')
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
    $domainSlot = Get-PASUIDomainSlot $State
    if ($domainSlot) {
        [void]$slots.Add($domainSlot)
    }
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
    # An HTML5 Gateway shares the server of a PSMP when there is one; otherwise it gets its own Linux server.
    $gateways = [int]$State.Counts['HTML5GW']
    for ($i = 1; $i -le [int]$State.Counts.PSMP; $i++) {
        $types = @('PSMP')
        $roles = 'PSMP'
        if ($i -le $gateways) {
            $types = @('PSMP', 'HTML5GW')
            $roles = 'PSMP + HTML5 Gateway'
        }
        [void]$slots.Add(@{ Key = "psmp$i"; Roles = $roles; Types = $types; Os = 'Linux'; DefaultName = ('psmp{0:00}' -f $i); Named = $true })
    }
    for ($i = [int]$State.Counts.PSMP + 1; $i -le $gateways; $i++) {
        [void]$slots.Add(@{ Key = "gw$i"; Roles = 'HTML5 Gateway'; Types = @('HTML5GW'); Os = 'Linux'; DefaultName = ('html5gw{0:00}' -f $i); Named = $true })
    }
    # PTA needs its own RHEL-family server with 8 GB.
    for ($i = 1; $i -le [int]$State.Counts['PTA']; $i++) {
        [void]$slots.Add(@{ Key = "pta$i"; Roles = 'PTA (RHEL family, 8 GB)'; Types = @('PTA'); Os = 'Linux'; DefaultName = ('pta{0:00}' -f $i); Named = $true })
    }
    return @($slots)
}

function Get-PASUIDomainSlot {
    # The form line of the domain, or $null without a domain. New: the server that becomes the domain
    # controller, with its local administrator. Existing: a DNS server of the domain, with a domain account
    # that may join computers. The password of that line is also the password the domain is joined with.
    param([hashtable]$State)
    $mode = ''
    if ($State.ContainsKey('Domain')) {
        $mode = [string]$State.Domain
    }
    if ($mode -eq 'New') {
        return @{ Key = 'dc'; Roles = 'Domain controller'; Types = @('AD'); Os = 'Windows'; DefaultName = ''; Named = $false }
    }
    if ($mode -eq 'Existing') {
        return @{ Key = 'domain'; Roles = 'Existing domain (a DNS server of it)'; Types = @(); Os = 'Windows'; DefaultName = ''; Named = $false }
    }
    return $null
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
            if ($type -in @('Vault', 'DRVault', 'AD')) {
                continue
            }
            $instanceName = $name
            if ($type -eq 'CPM' -and $slot.Types.Count -gt 1) {
                $cpmNumber++
                $instanceName = ('CPM{0:00}' -f $cpmNumber)
            } elseif ($type -eq 'CPM') {
                $cpmNumber++
            }
            $instance = @{ Type = $type; Name = $instanceName; Address = $address; Username = (Get-PASUISlotValue $State $slot 'User') }
            if ($type -eq 'PTA' -and ([string]$State.VaultTimezone).Trim()) {
                $instance.VaultTimezone = ([string]$State.VaultTimezone).Trim()
            }
            [void]$instances.Add($instance)
        }
    }
    return @($instances)
}

function Get-PASUIInputIssues {
    # What is still missing on a step, in the user's words. Empty list: the step is complete.
    param([hashtable]$State, [string]$Screen)
    $issues = New-Object System.Collections.ArrayList
    if ($Screen -eq 'media') {
        if (-not @(Get-PASUIMediaPaths $State).Count) {
            [void]$issues.Add('Add the folder or the files that hold the CyberArk installer media.')
        } elseif (-not $State.MediaScanned) {
            [void]$issues.Add('The media is still being looked through.')
        } elseif (-not @($State.MediaItems | Where-Object { $script:PASUIMediaNames.Contains([string]$_.Component) }).Count) {
            [void]$issues.Add('No CyberArk installer was recognised in what you added.')
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
        if ((Get-PASUIDomainSlot $State) -and [string]$State.DomainName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$') {
            [void]$issues.Add('Enter the DNS name of the domain, for example pam.lab.')
        }
        if ([int]$State.Counts['PTA'] -gt 0) {
            if ([int]$State.Counts.PVWA -eq 0) {
                [void]$issues.Add('PTA connects to PVWA: add a PVWA to the lab.')
            }
            if ($State.MediaScanned -and -not $State.MediaSelection.ContainsKey('PSMP')) {
                [void]$issues.Add('PTA needs a PSMP package in the media folder (it holds the CyberArk package signing key).')
            }
        }
        if ([int]$State.Counts['HTML5GW'] -gt 0) {
            if ([int]$State.Counts.PVWA -eq 0 -or ([int]$State.Counts.PSM -eq 0 -and $State.VaultMode -ne 'Existing')) {
                [void]$issues.Add('The HTML5 Gateway opens PSM sessions and is registered in PVWA: add a PVWA and a PSM to the lab.')
            }
            if ($State.MediaScanned -and -not $State.MediaSelection.ContainsKey('PACLI')) {
                [void]$issues.Add('The HTML5 Gateway needs the PACLI package in the media folder.')
            }
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
        if (([int]$State.Counts.PSMP -gt 0 -or [int]$State.Counts['HTML5GW'] -gt 0 -or [int]$State.Counts['PTA'] -gt 0) -and -not $State.AcceptEula) {
            [void]$issues.Add('Accept the CyberArk license agreement of the Linux installers (PSMP, HTML5 Gateway, PTA).')
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
    # Everything the media is read from: the folders and files that were added, and a path that is typed
    # into the field but not added yet.
    param([hashtable]$State)
    $paths = @()
    foreach ($source in @($State.MediaSources)) {
        if ($source -and $paths -notcontains [string]$source) {
            $paths += [string]$source
        }
    }
    $typed = ([string]$State.MediaPath).Trim().Trim('"')
    if ($typed -and $paths -notcontains $typed) {
        $paths += $typed
    }
    return @($paths)
}

function Add-PASUIMediaSource {
    # Adds folders or files to the places the media is read from. Returns how many were new.
    param([hashtable]$State, [string[]]$Paths)
    $added = 0
    foreach ($path in @($Paths)) {
        $clean = ([string]$path).Trim().Trim('"')
        if ($clean.Length -gt 3) {
            $clean = $clean.TrimEnd([char]92)
        }
        if (-not $clean -or @($State.MediaSources) -contains $clean) {
            continue
        }
        $State.MediaSources = @($State.MediaSources) + $clean
        $added++
    }
    if ($added) {
        $State.MediaScanned = $false
    }
    return $added
}

function Remove-PASUIMediaSource {
    # Forgets one of the places the media is read from (by its position in the list).
    param([hashtable]$State, [int]$Index)
    $sources = @($State.MediaSources)
    if ($Index -lt 0 -or $Index -ge $sources.Count) {
        return
    }
    $kept = @()
    for ($i = 0; $i -lt $sources.Count; $i++) {
        if ($i -ne $Index) {
            $kept += $sources[$i]
        }
    }
    $State.MediaSources = $kept
    $State.MediaScanned = $false
    if (-not $kept.Count -and -not ([string]$State.MediaPath).Trim()) {
        $State.MediaItems = @()
        $State.MediaSelection = @{}
    }
}

function Get-PASUIMediaSourceOf {
    # The added folder or file a media item came from: the source that is the file itself or the folder
    # it lies in (the longest match). '' when none matches.
    param([hashtable]$State, $Item)
    $path = [string]$Item.Path
    $best = ''
    foreach ($source in @(Get-PASUIMediaPaths $State)) {
        $candidate = [string]$source
        $inside = ($path -ieq $candidate) -or $path.StartsWith($candidate.TrimEnd([char]92) + [char]92, [StringComparison]::OrdinalIgnoreCase)
        if ($inside -and $candidate.Length -gt $best.Length) {
            $best = $candidate
        }
    }
    return $best
}

function Get-PASUIMediaRows {
    # One row per kind of media: Kind, Label, Found, Detail (version and file name), Source (the added folder
    # or file it was found in) and Inside (the ZIP bundle that holds it, when it lies inside one).
    param([hashtable]$State)
    $rows = New-Object System.Collections.ArrayList
    foreach ($kind in $script:PASUIMediaNames.Keys) {
        $found = @($State.MediaItems | Where-Object { [string]$_.Component -eq $kind })
        $detail = ''
        $source = ''
        $inside = ''
        $item = $null
        if ($State.MediaSelection.ContainsKey($kind)) {
            $item = $State.MediaSelection[$kind]
            $detail = [string]$item.Name
            if ([string]$item.Version) {
                $detail = 'version ' + [string]$item.Version + ' (' + [string]$item.Name + ')'
            }
        } elseif ($found.Count) {
            $item = $found[0]
            $detail = (@($found | ForEach-Object { [string]$_.Name } | Select-Object -Unique) -join ', ')
        }
        if ($item -and $item.PSObject.Properties['Path']) {
            $source = Get-PASUIMediaSourceOf $State $item
            if ($item.PSObject.Properties['Entry'] -and [string]$item.Entry) {
                $inside = [IO.Path]::GetFileName([string]$item.Path)
            }
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
                Source = $source
                Inside = $inside
            })
    }
    return @($rows)
}

function Get-PASUIMediaSourceRows {
    # One row per added folder or file: Index, Path, Count (recognised items in it), Labels (what they are)
    # and Missing (the path does not exist).
    param([hashtable]$State)
    $rows = New-Object System.Collections.ArrayList
    $sources = @($State.MediaSources)
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $path = [string]$sources[$i]
        $labels = @()
        $count = 0
        $missing = $false
        foreach ($item in @($State.MediaItems)) {
            $kind = [string]$item.Component
            if ($kind -eq 'Missing' -and [string]$item.Path -ieq $path) {
                # The installer reports a path that does not exist as an item of its own.
                $missing = $true
            }
            if (-not $script:PASUIMediaNames.Contains($kind)) {
                continue
            }
            if ((Get-PASUIMediaSourceOf $State $item) -ne $path) {
                continue
            }
            $count++
            $label = [string]$script:PASUIMediaNames[$kind]
            if ($labels -notcontains $label) {
                $labels += $label
            }
        }
        # In the order of the result table below.
        $labels = @($script:PASUIMediaNames.Values | Where-Object { $labels -contains [string]$_ })
        [void]$rows.Add([pscustomobject]@{ Index = $i; Path = $path; Count = $count; Labels = @($labels); Missing = $missing })
    }
    return @($rows)
}

function Get-PASUIEstimateMinutes {
    # A rough duration, good enough to plan a coffee. The servers are installed at the same time, so the lab
    # takes as long as its longest part: the Vault, then the registrations one after the other, or one server
    # that takes longer than all of that. From the lab runs of 22 November 2026 (Full lab with DR: 23 minutes;
    # new domain with PVWA, CPM, PSM and PSMP: 20 minutes).
    param([hashtable]$State)
    $vault = 0
    if ($State.VaultMode -ne 'Existing') {
        $vault = 9
    }
    if ($State.VaultMode -eq 'PrimaryDR') {
        $vault = 16
    }
    $pvwa = [int]$State.Counts.PVWA
    $cpm = [int]$State.Counts.CPM
    $psm = [int]$State.Counts.PSM
    # What one server needs on its own, from the first upload to the last check.
    $alone = @(0)
    if ($pvwa) {
        $web = 8
        if ($cpm -and $State.Colocate) {
            $web += 3
        }
        $alone += $web
    }
    if ($cpm -and -not $State.Colocate) {
        $alone += 5
    }
    if ($psm) {
        $alone += 13
    }
    if ([int]$State.Counts.PSMP -or [int]$State.Counts['HTML5GW']) {
        $alone += 3 + 3 * [Math]::Sign([int]$State.Counts['HTML5GW'])
    }
    if ([int]$State.Counts['PTA']) {
        $alone += 15
    }
    $longest = [int]($alone | Measure-Object -Maximum).Maximum
    # What is left once the Vault is there: the registrations in turn, then hardening and the last checks.
    $after = 0
    if ($pvwa) {
        $after = 3
    }
    if ($cpm) {
        $after += 4
    }
    if ($psm) {
        $after = [Math]::Max($after, 8)
    }
    $instances = $pvwa + $cpm + $psm + [int]$State.Counts.PSMP + [int]$State.Counts['HTML5GW'] + [int]$State.Counts['PTA']
    $after += 2 * [Math]::Max(0, $instances - 4)
    $minutes = [Math]::Max($vault + $after, $longest)
    if ((Get-PASUIDomainSlot $State)) {
        # A new forest first, and one restart for every server that joins.
        $minutes += 4
    }
    return [int][Math]::Max(3, $minutes)
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
    if (-not $State.Hardening) {
        $command += ' -SkipHardening'
    }
    if ($State.AcceptEula) {
        $command += ' -AcceptEula'
    }
    $domainSlot = Get-PASUIDomainSlot $State
    if ($domainSlot) {
        $command += ' -DomainMode ' + [string]$State.Domain + ' -DomainName ' + [string]$State.DomainName + ' -DomainControllerAddress ' + (Get-PASUISlotValue $State $domainSlot 'Address')
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
    if ($Stage -match '^(.+)-pass\d+$') {
        # The same step again after a restart the vendor installer asked for.
        return ((Get-PASUIStageText $Matches[1]) + ' (continued after the restart)')
    }
    $text = $Stage -replace '-', ' '
    return ($text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1))
}

function Get-PASUIStepOfStage {
    # The step of the list a stage belongs to. A component can run a step in several parts: the step itself, a
    # restart of the server (<step>-reboot) and the step again (<step>-pass2). They count as the one step,
    # so that the number of steps does not grow while a component is installed. Seen: the stages that occurred.
    param([string]$Stage, [string[]]$Seen)
    if ($Stage -match '^(.+?)(-pass\d+)?(-reboot)?$' -and $Matches[1] -ne $Stage -and $Seen -contains $Matches[1]) {
        return [string]$Matches[1]
    }
    return $Stage
}

function Get-PASUIRunProgress {
    # What the run page shows: per component Done/Total steps and the current step; plus the totals.
    # Catalog: @{ <type> = <names of its steps> } (or the number of steps). With names, only these steps are
    # counted: what a run does besides them (the controller's own checks, an extra upload) changes no number.
    # PlanItems: @{ <component id> = @{ Address } }.
    param($Snapshot, [hashtable]$Catalog = @{}, [hashtable]$PlanItems = @{})
    $events = @($Snapshot.Events)
    $rows = New-Object System.Collections.ArrayList
    $doneAll = 0
    $totalAll = 0
    foreach ($component in @($Snapshot.Components)) {
        $id = [string]$component.Id
        $type = [string]$component.Type
        $mine = @($events | Where-Object { [string]$_.Component -eq $id -and [string]$_.Stage })
        $seen = @($mine | ForEach-Object { [string]$_.Stage } | Select-Object -Unique)
        $finished = @($mine | Where-Object { [string]$_.Event -in @('TaskCompleted', 'TaskRevalidated') } | ForEach-Object { Get-PASUIStepOfStage ([string]$_.Stage) $seen } | Select-Object -Unique)
        if ($mine.Count -and [string]$mine[-1].Event -notin @('TaskCompleted', 'TaskRevalidated', 'TaskSkipped')) {
            # A later part of a step is running (its restart, or the step again): the step is not finished yet.
            $running = Get-PASUIStepOfStage ([string]$mine[-1].Stage) $seen
            $finished = @($finished | Where-Object { $_ -ne $running })
        }
        $total = 0
        $catalogKey = $type
        if ($type -eq 'DRVault') {
            $catalogKey = 'DR'
        }
        if ($Catalog.ContainsKey($catalogKey)) {
            $entry = $Catalog[$catalogKey]
            if ($entry -is [int]) {
                $total = $entry
            } else {
                $known = @($entry | ForEach-Object { [string]$_ })
                $total = $known.Count
                $finished = @($finished | Where-Object { $known -contains $_ })
            }
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
        # A parallel installation: the component waits for the Vault or for the PVWA certificate.
        $waiting = ''
        $latest = @($events | Where-Object { [string]$_.Component -eq $id }) | Select-Object -Last 1
        if ($latest -and $status -notin @('Succeeded', 'Failed', 'Unknown', 'Blocked')) {
            if ([string]$latest.Event -eq 'VaultWaiting') {
                $waiting = 'Waiting for its turn at the Vault'
            } elseif ([string]$latest.Event -eq 'ComponentWaiting') {
                $waiting = 'Waiting for PVWA'
            }
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
                Waiting = $waiting
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
