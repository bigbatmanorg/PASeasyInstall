# Dummy backend for UI development. Implements the commands in ../Backend.Contract.ps1 and never
# contacts a server, installs software or stores secrets.
#
# Simulated deployment: every stage of every component "runs" for $env:PASUI_MOCK_STAGE_SECONDS
# (default 1.0) seconds. Scenario knobs, so failure/warning UI can be exercised:
#   - environment name containing "fail"  -> Vault (or first component) install fails, run ends Failed
#   - environment name containing "warn"  -> hardening-reboot emits a Warning and continues
#   - $env:PASUI_MOCK_CANCEL_CREDENTIALS=1 -> credential prompt behaves as if cancelled
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'MediaInventory.ps1')

$script:Runs = @{}
$script:StageNames = @{
    Vault = @('LocalPreflight','preflight','management-endpoint','prepare-paths','upload-server','upload-license','prerequisites','extract','keygen','install-server','configure-primary','harden-primary','hardening-reboot','verify-primary')
    DR    = @('LocalPreflight','preflight','relay-shared-keys','install-dr-server','prepare-standby','install-padr','configure-padr','first-replication','harden-dr','hardening-reboot','replication-after-hardening','test-safe-replication')
    PVWA  = @('LocalPreflight','management','media-upload','preflight','extract','prerequisites','install','configuretls','register','harden','verify')
    CPM   = @('LocalPreflight','management','media-upload','preflight','extract','prerequisites','install','configuretls','register','harden','verify')
    PSM   = @('LocalPreflight','management','media-upload','preflight','extract','prerequisites','install','register','harden','postinstall','verify')
    PSMP  = @('LocalPreflight','management','media-upload','preflight','extract','prerequisites','install','register','harden','verify')
    PTA   = @('LocalPreflight','management','media-upload','preflight','extract','prerequisites','install','configuretls','register','harden','verify')
    AD    = @('LocalPreflight','preflight','install-adds','promote-forest','reboot','verify-dns','verify-srv')
}
$script:Priority = @{AD=0;Vault=10;DRVault=20;PVWA=30;CPM=40;PSM=50;PSMP=60;PTA=70}
$script:MediaKey = @{Vault='Vault';DRVault='DR';PVWA='PVWA';CPM='CPM';PSM='PSM';PSMP='PSMP';PTA='PTA'}
$script:LinuxTypes = @('PSMP','PTA')

function ConvertTo-PASMockHashtable {
    # PS 5.1-compatible replacement for ConvertFrom-Json -AsHashtable.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}; foreach ($k in $Value.Keys) { $h[[string]$k] = ConvertTo-PASMockHashtable $Value[$k] }; return $h
    }
    if ($Value -is [pscustomobject]) {
        $h = @{}; foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-PASMockHashtable $p.Value }; return $h
    }
    if ($Value -is [System.Collections.IEnumerable]) { return ,@(foreach ($i in $Value) { ConvertTo-PASMockHashtable $i }) }
    return $Value
}
function Get-PASMockDigest {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function ConvertTo-PASMockCanonicalJson {
    param($Value)
    function Sort-Node($v) {
        if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) { return $v }
        if ($v -is [System.Collections.IDictionary]) {
            $o = [ordered]@{}; foreach ($k in @($v.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $o[$k] = Sort-Node $v[$k] }; return $o
        }
        if ($v -is [System.Collections.IEnumerable]) { return ,@(foreach ($i in $v) { Sort-Node $i }) }
        return $v
    }
    return ((Sort-Node (ConvertTo-PASMockHashtable $Value)) | ConvertTo-Json -Depth 30 -Compress)
}
function Test-PASMockAddress {
    param([string]$Value)
    return ($Value -match '^(\d{1,3}\.){3}\d{1,3}$' -or $Value -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9-]{1,63})*$')
}
function ConvertTo-PASMockMediaRef {
    # Accepts a path string, @{Path;Entry} or an inventory item.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { if ($Value) { return @{path=$Value; entry=''} } else { return $null } }
    $h = ConvertTo-PASMockHashtable $Value
    $p = if ($h.ContainsKey('Path')) { $h.Path } elseif ($h.ContainsKey('path')) { $h.path } else { '' }
    $e = if ($h.ContainsKey('Entry')) { $h.Entry } elseif ($h.ContainsKey('entry')) { $h.entry } else { '' }
    if (-not $p) { return $null }
    return @{path=[string]$p; entry=[string]$e}
}
function New-PASMockBaseConfiguration {
    param([string]$Environment,[string]$ControllerIP)
    return @{
        schemaVersion = 2; name = $Environment.Trim(); controllerAddress = $ControllerIP.Trim()
        security = @{profile='Secure'}; vault = @{address=''; existing=$false; managementHost=''}
        hosts = @{}; components = @(); media = @{}; activeDirectory = @{mode='None'; join=@()}; mock = $true
    }
}

function New-PASDeploymentConfiguration {
    <#
      VaultMode : Primary | PrimaryDR | Existing (no Vault install; components join ExistingVaultAddress).
      Instances : @( @{Type='PVWA';Name='PVWA01';Address='10.0.0.21';Username='Administrator'}, ... ).
                  Type is PVWA|CPM|PSM|PSMP|PTA. Name is the server hostname. Username is optional (defaults
                  to -Username for Windows, -LinuxUsername for Linux).
                  Several instances of a type are allowed (PTA: one). Name identifies the instance and its
                  server; instances that share an address share one server (the first instance's name).
      Media     : @{Vault=..;DR=..;PVWA=..;License=..;RecoveryKey=..} — path string or @{Path;Entry}.
    #>
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][ValidateSet('Primary','PrimaryDR','Existing')][string]$VaultMode,
        [object[]]$Instances=@(),[AllowEmptyString()][string]$ControllerAddress='',
        [AllowEmptyString()][string]$PrimaryAddress='',[AllowEmptyString()][string]$DRAddress='',
        [AllowEmptyString()][string]$ExistingVaultAddress='',
        [string]$Username='Administrator',[string]$LinuxUsername='root',[hashtable]$Media=@{},
        [string]$PrimaryUsername='',[string]$DRUsername='',
        [ValidateSet('Sequential','Parallel')][string]$ExecutionMode='Sequential',
        [ValidateSet('Secure','Lab')][string]$SecurityProfile='Secure',[switch]$AcceptEula)
    $c = New-PASMockBaseConfiguration -Environment $Environment -ControllerIP $ControllerAddress
    $c.execution = @{mode=$ExecutionMode}
    $c.security.profile = $SecurityProfile
    $list = New-Object System.Collections.ArrayList
    $byAddress = @{}
    if ($VaultMode -eq 'Existing') {
        $c.vault.address = $ExistingVaultAddress.Trim(); $c.vault.existing = $true
    } else {
        $c.hosts['vault01'] = @{address=$PrimaryAddress.Trim(); os='Windows'; user=$(if ($PrimaryUsername) { $PrimaryUsername } else { $Username }); credentialRef='vault01'}
        $c.vault.address = $PrimaryAddress.Trim(); $c.vault.managementHost = 'vault01'
        [void]$list.Add(@{id='vault'; name='Vault'; type='Vault'; host='vault01'; variant=$(if ($VaultMode -eq 'PrimaryDR') {'PrimaryWithDR'} else {'Standalone'})})
        if ($VaultMode -eq 'PrimaryDR') {
            $c.hosts['dr01'] = @{address=$DRAddress.Trim(); os='Windows'; user=$(if ($DRUsername) { $DRUsername } else { $Username }); credentialRef='dr01'}
            [void]$list.Add(@{id='dr'; name='DR'; type='DRVault'; host='dr01'; variant='Standby'})
        }
    }
    foreach ($inst in @($Instances | Where-Object { $_ })) {
        $type = [string]$inst.Type; $name = ([string]$inst.Name).Trim(); $addr = ([string]$inst.Address).Trim()
        if ($type -notin @('PVWA','CPM','PSM','PSMP','PTA')) { throw "Unknown component: $type" }
        if (-not $name) { $name = $type }
        $os = if ($type -in $script:LinuxTypes) { 'Linux' } else { 'Windows' }
        $user = if ($inst.ContainsKey('Username') -and [string]$inst.Username) { ([string]$inst.Username).Trim() } elseif ($os -eq 'Linux') { $LinuxUsername } else { $Username }
        # Same address = same server; the host is named after the first instance placed on it.
        if ($addr -and $byAddress.ContainsKey($addr)) { $hostId = $byAddress[$addr] }
        else {
            $hostId = $name
            $c.hosts[$hostId] = @{address=$addr; os=$os; user=$user; credentialRef=$hostId}
            if ($addr) { $byAddress[$addr] = $hostId }
        }
        $options = @{}; if ($type -eq 'PSMP' -and $AcceptEula) { $options.acceptEula = $true }
        [void]$list.Add(@{id=$name; name=$name; type=$type; host=$hostId; user=$user; variant='Standard'; options=$options})
    }
    $c.components = @($list.ToArray())
    foreach ($k in @($Media.Keys)) { $ref = ConvertTo-PASMockMediaRef $Media[$k]; if ($ref) { $c.media[[string]$k] = $ref } }
    return $c
}

# Back-compat with the Orchestrator v0.1 API (kept so older UI generations can drive the mock).
function New-PASFreshEnvironment {
    [CmdletBinding()]param([AllowEmptyString()][string]$PrimaryIP='',[AllowEmptyString()][string]$ControllerIP='',
        [AllowEmptyString()][string]$MediaRoot='',[string]$Environment='MyPAM',[string]$Username='Administrator',
        [switch]$WithDR,[string]$DRIP='',[string]$LicenseFile='',[string]$PublicRecoveryKey='')
    $media = @{}; if ($LicenseFile) { $media.License = $LicenseFile }; if ($PublicRecoveryKey) { $media.RecoveryKey = $PublicRecoveryKey }
    if ($MediaRoot) { $media.Vault = $MediaRoot; if ($WithDR) { $media.DR = $MediaRoot } }
    return New-PASDeploymentConfiguration -Environment $Environment -VaultMode $(if ($WithDR) {'PrimaryDR'} else {'Primary'}) `
        -ControllerAddress $ControllerIP -PrimaryAddress $PrimaryIP -DRAddress $DRIP -Username $Username -Media $media
}
function New-PASExistingVaultComponent {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateSet('PVWA','CPM','PSM','PSMP','PTA')][string]$Component,
        [AllowEmptyString()][string]$TargetAddress='',[AllowEmptyString()][string]$VaultAddress='',
        [AllowEmptyString()][string]$MediaZip='',[string]$Environment='MyPAM',[string]$Username='')
    return New-PASDeploymentConfiguration -Environment $Environment -VaultMode Existing `
        -Instances @(@{Type=$Component;Name=($Component+'01');Address=$TargetAddress}) `
        -ExistingVaultAddress $VaultAddress -Media @{$Component=$MediaZip} -Username $(if ($Username) {$Username} else {'Administrator'})
}

function Test-PASEnvironment {
    [CmdletBinding()]param([string]$Config,$Configuration,[switch]$CheckMedia)
    $issues = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    if ($Config) {
        if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) { throw "Configuration not found: $Config" }
        $Configuration = (Get-Content -LiteralPath $Config -Raw -Encoding UTF8) | ConvertFrom-Json
    }
    $c = ConvertTo-PASMockHashtable $Configuration
    if (-not $c) { return [pscustomobject]@{Valid=$false; Issues=@('No configuration supplied'); Warnings=@(); Configuration=$null} }
    if (-not [string]$c.name) { [void]$issues.Add('Environment name is required') }
    elseif ([string]$c.name -notmatch '^[A-Za-z0-9_.-]{1,64}$') { [void]$issues.Add('Environment name may contain only letters, digits, dot, dash and underscore') }
    $existing = [bool]$c.vault.existing
    $comps = @($c.components)
    if (-not $comps.Count) { [void]$issues.Add('Nothing selected to install') }
    if (-not [string]$c.controllerAddress) { [void]$issues.Add('Controller address is required') }
    elseif (-not (Test-PASMockAddress ([string]$c.controllerAddress))) { [void]$issues.Add("Controller address is not a valid IP address or host name: $($c.controllerAddress)") }
    if (-not [string]$c.vault.address) { [void]$issues.Add($(if ($existing) { 'Existing Vault address is required' } else { 'Primary Vault address is required' })) }
    $seen = @{}
    foreach ($hostId in @($c.hosts.Keys | Sort-Object)) {
        $h = $c.hosts[$hostId]; $addr = [string]$h.address
        $label = (@($comps | Where-Object { $_.host -eq $hostId } | ForEach-Object { if ($_.ContainsKey('name') -and $_.name) { $_.name } else { $_.type } }) -join ' + ')
        if (-not $label) { $label = $hostId }
        if (-not $addr) { [void]$issues.Add("Server address for $label is required"); continue }
        if (-not (Test-PASMockAddress $addr)) { [void]$issues.Add("Server address for $label is not a valid IP address or host name: $addr") }
        if ($addr -match '^(192\.0\.2|198\.51\.100|203\.0\.113)\.') { [void]$issues.Add("$label uses a documentation-only TEST-NET address ($addr)") }
        if ($seen.ContainsKey($addr)) { [void]$issues.Add("$label and $($seen[$addr]) cannot share $addr") } else { $seen[$addr] = $label }
        if (-not [string]$h.user) { [void]$issues.Add("Remote account for $label is required") }
    }
    if ([string]$c.controllerAddress -and $seen.ContainsKey([string]$c.controllerAddress)) { [void]$issues.Add('The controller must not be one of the target servers') }
    if ($existing -and $seen.ContainsKey([string]$c.vault.address)) { [void]$issues.Add('A component cannot be installed on the existing Vault server') }
    $names = @{}
    foreach ($comp in $comps) {
        $n = if ($comp.ContainsKey('name')) { [string]$comp.name } else { [string]$comp.id }
        if ($comp.type -notin @('Vault','DRVault')) {
            if ($n -notmatch '^[A-Za-z][A-Za-z0-9-]{0,62}$') { [void]$issues.Add("Hostname '$n' must start with a letter and use only letters, digits and dashes (max 63)") }
            if ($names.ContainsKey($n.ToLowerInvariant())) { [void]$issues.Add("Hostname '$n' is used twice") } else { $names[$n.ToLowerInvariant()] = $true }
            if ($comp.ContainsKey('user') -and $comp.user -and $c.hosts.ContainsKey([string]$comp.host) -and [string]$c.hosts[[string]$comp.host].user -ne [string]$comp.user) {
                [void]$issues.Add("$n shares a server with $($comp.host) but uses account '$($comp.user)' instead of '$($c.hosts[[string]$comp.host].user)'")
            }
        }
    }
    if (@($comps | Where-Object { $_.type -eq 'PTA' }).Count -gt 1) { [void]$issues.Add('Only one PTA server is supported') }
    foreach ($comp in @($comps | Where-Object { $_.type -eq 'PSMP' })) {
        $ok = $comp.ContainsKey('options') -and $comp.options -and $comp.options.ContainsKey('acceptEula') -and [bool]$comp.options.acceptEula
        if (-not $ok) { [void]$issues.Add("Accept the CyberArk license agreement (EULA) for the PSMP installer ($($comp.name))") }
    }
    $media = if ($c.ContainsKey('media') -and $c.media) { $c.media } else { @{} }
    foreach ($type in @($comps | ForEach-Object { [string]$_.type } | Select-Object -Unique)) {
        if (-not $media.ContainsKey($script:MediaKey[$type])) { [void]$issues.Add("No installer media selected for $(if ($type -eq 'DRVault') {'DR Vault'} else {$type})") }
    }
    $installsVault = @($comps | Where-Object { $_.type -eq 'Vault' }).Count -gt 0
    if ($installsVault) {
        foreach ($k in @('License','RecoveryKey')) {
            if (-not $media.ContainsKey($k)) {
                $msg = if ($k -eq 'License') { 'No license file found in the media' } else { 'No public recovery key (recpub.key) found in the media' }
                if ($CheckMedia) { [void]$issues.Add($msg) } else { [void]$warnings.Add($msg + '; installation will stop at the media check') }
            }
        }
        if (-not $media.ContainsKey('PACLI')) { [void]$warnings.Add('No PACLI package found; Vault post-install checks need it') }
    }
    if ($CheckMedia) {
        foreach ($k in @($media.Keys)) {
            $p = [string]$media[$k].path
            if ($p -and -not (Test-Path -LiteralPath $p)) { [void]$issues.Add("Installer media not found: $p") }
        }
    }
    return [pscustomobject]@{Valid=($issues.Count -eq 0); Issues=@($issues.ToArray()); Warnings=@($warnings.ToArray()); Configuration=$c}
}

function Get-PASEnvironmentPlan {
    [CmdletBinding()]param([string]$Config,$Configuration,[switch]$ResolveMedia)
    $valid = Test-PASEnvironment -Config $Config -Configuration $Configuration
    if (-not $valid.Valid) { throw ('Configuration incomplete: ' + ($valid.Issues -join '; ')) }
    $c = $valid.Configuration
    $ordered = @($c.components | Sort-Object -Property @{Expression={ [int]$script:Priority[[string]$_.type] }}, @{Expression={ [string]$_.id }})
    $hasVault = @($ordered | Where-Object { $_.type -eq 'Vault' }).Count -gt 0
    $items = foreach ($e in $ordered) {
        $type = [string]$e.type; $deps = @()
        if ($type -notin @('AD','Vault') -and $hasVault) { $deps += @($ordered | Where-Object { $_.type -eq 'Vault' } | ForEach-Object { [string]$_.id }) }
        if ($type -eq 'PTA') { $deps += @($ordered | Where-Object { $_.type -eq 'PVWA' } | ForEach-Object { [string]$_.id }) }
        $readiness = if ($type -in @('Vault','DRVault')) { 'MigratedNeedsRequalification' } else { 'RecipePreparedNeedsVendorMediaQualification' }
        $m = $c.media[$script:MediaKey[$type]]
        [pscustomobject]@{Id=[string]$e.id; Name=$(if ($e.ContainsKey('name') -and $e.name) { [string]$e.name } else { [string]$e.id }); Type=$type; Host=[string]$e.host; Address=[string]$c.hosts[[string]$e.host].address
            Os=[string]$c.hosts[[string]$e.host].os; Variant=[string]$e.variant; DependsOn=@($deps); Readiness=$readiness
            Media=$(if ($m) { [IO.Path]::GetFileName($(if ($m.entry) { [string]$m.entry } else { [string]$m.path })) } else { '' })}
    }
    return [pscustomobject]@{Name=[string]$c.name; ConfigDigest=(Get-PASMockDigest (ConvertTo-PASMockCanonicalJson $c))
        SourceDigest='mock'; MediaResolved=[bool]$ResolveMedia; Media=@(); Items=@($items); DomainJoins=@()
        ExistingVault=$(if ($c.vault.existing) { [string]$c.vault.address } else { '' })
        Warnings=@($valid.Warnings); ExecutionMode=$(if ($c.ContainsKey('execution') -and $c.execution -and $c.execution.mode) { [string]$c.execution.mode } else { 'Sequential' }); SchemaVersion=2}
}

function Save-PASEnvironment {
    [CmdletBinding(SupportsShouldProcess=$true)]param([Parameter(Mandatory)]$Configuration,[Parameter(Mandatory)][string]$Path,[switch]$Force)
    $valid = Test-PASEnvironment -Configuration $Configuration
    if (-not $valid.Valid) { throw ('Configuration incomplete: ' + ($valid.Issues -join '; ')) }
    $full = [IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not $Force) { throw "Configuration already exists: $full. Reopen or explicitly use -Force." }
    if ($PSCmdlet.ShouldProcess($full, 'Save deployment configuration')) {
        $dir = [IO.Path]::GetDirectoryName($full)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllText($full, ($valid.Configuration | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
        return $full
    }
}

function Get-PASStageCatalog {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateSet('Vault','DR','PVWA','CPM','PSM','PSMP','PTA','AD')][string]$Component)
    foreach ($s in $script:StageNames[$Component]) {
        [pscustomobject]@{Component=$Component; Stage=$s; ReadOnly=($s -eq 'LocalPreflight'); TargetExecutionQualified=$false}
    }
}

function Start-PASEnvironment {
    [CmdletBinding(SupportsShouldProcess=$true)]param([string]$Config,$Configuration,
        [hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},[switch]$PlanOnly)
    $valid = Test-PASEnvironment -Config $Config -Configuration $Configuration -CheckMedia:(!$PlanOnly)
    if (-not $valid.Valid) { throw ('Configuration incomplete: ' + ($valid.Issues -join '; ')) }
    if ($PlanOnly) { return (Get-PASEnvironmentPlan -Configuration $valid.Configuration) }
    $c = $valid.Configuration
    foreach ($hostId in @($c.hosts.Keys)) { if (-not $CredentialMap.ContainsKey($hostId)) { throw "Missing server credential for $hostId" } }
    $types = @($c.components | ForEach-Object { $_.type })
    $roles = @('VaultAdmin'); if ('Vault' -in $types) { $roles += 'VaultMaster' }; if ('DRVault' -in $types) { $roles += 'DRPassword' }
    foreach ($r in $roles) { if (-not $SecretMap.ContainsKey($r)) { throw "Missing Vault password: $r" } }
    if (-not $PSCmdlet.ShouldProcess([string]$c.name, 'Start selected component deployment')) { return }
    $plan = Get-PASEnvironmentPlan -Configuration $c
    $runId = [guid]::NewGuid().ToString('N')
    $stageSeconds = 1.0
    if ($env:PASUI_MOCK_STAGE_SECONDS) { $stageSeconds = [double]$env:PASUI_MOCK_STAGE_SECONDS }
    $timeline = New-Object System.Collections.ArrayList
    $fail = ([string]$c.name -match '(?i)fail'); $warn = ([string]$c.name -match '(?i)warn')
    $script:MockOutcome = 'Succeeded'
    # Lanes run concurrently; stages inside a lane run in order. Sequential = one lane for everything.
    # Parallel = Vault and DR first (one lane), then one lane per target server. Registration with the
    # Vault is serialized across lanes, standing in for the orchestrator's coordination of Vault sessions.
    $vaultItems = @($plan.Items | Where-Object { $_.Type -in @('Vault','DRVault') })
    $compItems  = @($plan.Items | Where-Object { $_.Type -notin @('Vault','DRVault') })
    $parallel = ($plan.ExecutionMode -eq 'Parallel')
    function New-Lane([object[]]$Items, [double]$Start) {
        $q = New-Object System.Collections.Queue
        foreach ($it in $Items) { foreach ($st in $script:StageNames[$(if ($it.Type -eq 'DRVault') {'DR'} else {$it.Type})]) { $q.Enqueue(@{Item=$it; Stage=$st}) } }
        return @{Queue=$q; T=$Start; Dead=$false}
    }
    function Invoke-Lanes([object[]]$Lanes) {
        $registerFree = 0.0; $end = 0.0
        while ($true) {
            $live = @($Lanes | Where-Object { -not $_.Dead -and $_.Queue.Count })
            if (-not $live.Count) { break }
            $lane = @($live | Sort-Object { $_.T })[0]
            $job = $lane.Queue.Dequeue(); $it = $job.Item; $st = $job.Stage
            if ($st -eq 'register' -and $registerFree -gt $lane.T) {
                [void]$timeline.Add(@{At=$lane.T; Component=$it.Id; Stage=$st; Event='WaitingForVault'; Level='Information'; Message='Another server is registering with the Vault; the orchestrator queues this registration.'})
                $lane.T = $registerFree
            }
            [void]$timeline.Add(@{At=$lane.T; Component=$it.Id; Stage=$st; Event='TaskStarted'; Level='Information'; Message=("Running $st on $($it.Host) ($($it.Address))")})
            $lane.T += $stageSeconds
            if ($fail -and $st -in @('install-server','install') -and $script:MockOutcome -ne 'Failed') {
                [void]$timeline.Add(@{At=$lane.T; Component=$it.Id; Stage=$st; Event='TaskFailed'; Level='Error'; Message='Mock failure: installer exited with code 1603. Attempt state recorded; inspect before resuming.'})
                $script:MockOutcome = 'Failed'; $lane.Dead = $true
                if (-not $parallel) { foreach ($l in $Lanes) { $l.Dead = $true } }
                if ($lane.T -gt $end) { $end = $lane.T }; continue
            }
            if ($warn -and $st -eq 'hardening-reboot') {
                [void]$timeline.Add(@{At=$lane.T; Component=$it.Id; Stage=$st; Event='RebootWarning'; Level='Warning'; Message='Target is rebooting; waiting for WinRM to come back.'})
                $lane.T += $stageSeconds
            }
            [void]$timeline.Add(@{At=$lane.T; Component=$it.Id; Stage=$st; Event='TaskCompleted'; Level='Information'; Message=("$st completed")})
            if ($st -eq 'register') { $registerFree = $lane.T }
            if ($lane.T -gt $end) { $end = $lane.T }
        }
        return $end
    }
    if ($parallel) {
        $t = Invoke-Lanes @(New-Lane $vaultItems 0.3)
        if ($script:MockOutcome -ne 'Failed' -or -not $vaultItems.Count) {
            $hostLanes = @($compItems | Group-Object Host | ForEach-Object { New-Lane @($_.Group) ([Math]::Max($t, 0.3)) })
            if ($hostLanes.Count) { $t = [Math]::Max($t, (Invoke-Lanes $hostLanes)) }
        }
    } else {
        $t = Invoke-Lanes @(New-Lane @($plan.Items) 0.3)
    }
    # At equal times a stage ends before the next one starts.
    $timeline = [System.Collections.ArrayList]@($timeline.ToArray() | Sort-Object @{Expression={ [double]$_.At }}, @{Expression={ if ($_.Event -eq 'TaskStarted') { 1 } else { 0 } }})
    $outcome = $script:MockOutcome
    $script:Runs[$runId] = @{Name=[string]$c.name; StartUtc=[datetime]::UtcNow; Timeline=$timeline; EndAt=$t; Outcome=$outcome}
    return $runId
}

function Get-PASEnvironmentSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[int]$Tail=150)
    $run = $script:Runs[$RunId]
    if (-not $run) { throw "Deployment run not found: $RunId" }
    $elapsed = ([datetime]::UtcNow - $run.StartUtc).TotalSeconds
    $events = New-Object System.Collections.ArrayList
    [void]$events.Add([pscustomobject]@{TimestampUtc=$run.StartUtc.ToString('o'); RunId=$RunId; Component='controller'; Stage=''; Event='ControllerLaunched'; Level='Information'; Status='Running'; Source='Controller'; Message='Mock controller started (no servers are contacted)'; Sequence=0})
    $seq = 1
    foreach ($e in $run.Timeline) {
        if ($e.At -gt $elapsed) { break }
        $status = switch -Regex ($e.Event) { 'Failed' {'Failed'} 'Warning' {'Warning'} 'Completed' {'Complete'} 'Started' {'Running'} default {'Info'} }
        [void]$events.Add([pscustomobject]@{TimestampUtc=$run.StartUtc.AddSeconds($e.At).ToString('o'); RunId=$RunId; Component=$e.Component; Stage=$e.Stage
            Event=$e.Event; Level=$e.Level; Status=$status; Source='Engine'; Message=$e.Message; Sequence=$seq})
        $seq++
    }
    $done = $elapsed -ge $run.EndAt
    $status = if ($done) { $run.Outcome } else { 'Running' }
    $staged = @($events | Where-Object { $_.Stage })
    $last = if ($staged.Count) { $staged[-1] } else { $null }
    return [pscustomobject]@{
        RunId=$RunId; Name=$run.Name; Status=$status
        CurrentComponent=$(if ($last) { [string]$last.Component } else { '' })
        Message=$(if ($done) { "Mock run $($run.Outcome.ToLowerInvariant())" } else { 'Mock run in progress' })
        LastStep=$(if ($last) { [string]$last.Stage } else { '' })
        CompletedEvents=@($events | Where-Object { $_.Event -eq 'TaskCompleted' }).Count
        ErrorEvents=@($events | Where-Object { $_.Status -eq 'Failed' }).Count
        Events=@($events.ToArray() | Select-Object -Last $Tail)
        OperationallyVerified=$false
    }
}
function Get-PASEnvironmentEvents {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[int]$Tail=150)
    return @((Get-PASEnvironmentSnapshot -RunId $RunId -Tail $Tail).Events)
}
function Request-PASeasyUICredential {
    [CmdletBinding()]param([string]$UserName,[string]$Message)
    if ($env:PASUI_MOCK_CANCEL_CREDENTIALS -eq '1') { return $null }
    $secure = New-Object Security.SecureString
    foreach ($ch in [guid]::NewGuid().ToString('N').ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return [pscredential]::new($(if ($UserName) { $UserName } else { 'mock-user' }), $secure)
}

Export-ModuleMember -Function @('Get-PASMediaInventory','Get-PASMediaSelection','New-PASDeploymentConfiguration',
    'New-PASFreshEnvironment','New-PASExistingVaultComponent','Test-PASEnvironment',
    'Get-PASEnvironmentPlan','Save-PASEnvironment','Start-PASEnvironment','Get-PASEnvironmentSnapshot',
    'Get-PASEnvironmentEvents','Get-PASStageCatalog','Request-PASeasyUICredential')
