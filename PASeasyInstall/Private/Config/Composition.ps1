# Deployment composition for the desktop UI and scripted callers: one configuration for a new
# Primary (+DR) or an existing Vault plus any number of component instances. Pure configuration
# work: no server is contacted. The only side effect is extracting a selected installer that lives
# inside a ZIP bundle into the controller's media cache (read-only on the source).

$script:PASComponentTypes = @('PVWA', 'CPM', 'PSM', 'PSMP', 'HTML5GW')
$script:PASLinuxTypes = @('PSMP', 'HTML5GW')
# Engine/journal names that must never be used as instance ids (event mapping and credential aliases).
$script:PASReservedIds = @('vault', 'dr', 'primary', 'primary_final', 'dr_final', 'vault01', 'dr01', 'primaryadmin', 'dradmin', 'controller')

function Get-PASSafeName {
    param([string]$Value, [int]$Max = 40)
    $s = ([string]$Value).Trim().ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    $s = $s.Trim('-')
    if (-not $s) { $s = 'server' }
    if ($s -notmatch '^[a-z]') { $s = 's-' + $s }
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max).TrimEnd('-') }
    return $s
}
function Get-PASMediaItemValue {
    param($Item, [string]$Name)
    if ($null -eq $Item) { return '' }
    if ($Item -is [string]) {
        if ($Name -eq 'Path') { return $Item }
        return ''
    }
    if ($Item -is [System.Collections.IDictionary]) {
        foreach ($k in @($Name, $Name.ToLowerInvariant())) { if ($Item.Contains($k)) { return [string]$Item[$k] } }
        return ''
    }
    $p = $Item.PSObject.Properties[$Name]
    if ($p) { return [string]$p.Value }
    return ''
}
function Resolve-PASMediaItemPath {
    <# A plain file is used where it is. An entry inside a ZIP bundle is extracted once into
       <DataRoot>/MediaCache/<key>/<entry file name>; the key covers bundle path, entry, size and time. #>
    param($Item, [string]$DataRoot = (Get-PASDataRoot))
    $path = Get-PASMediaItemValue $Item 'Path'
    $entry = Get-PASMediaItemValue $Item 'Entry'
    if (-not $path) { return '' }
    if (-not $entry) { return $path }
    if (-not(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Media bundle not found: $path" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $info = Get-Item -LiteralPath $path
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($info.FullName + '|' + $entry + '|' + $info.Length + '|' + $info.LastWriteTimeUtc.Ticks))))).Replace('-', '').Substring(0, 24).ToLowerInvariant() }
    finally { $sha.Dispose() }
    $name = [IO.Path]::GetFileName($entry.Replace('\', '/'))
    if (-not $name -or $name -in @('.', '..')) { throw "Unsafe bundle entry name: $entry" }
    $dir = Join-Path (Join-Path $DataRoot 'MediaCache') $key
    $target = Join-Path $dir $name
    $zip = [IO.Compression.ZipFile]::OpenRead($info.FullName)
    try {
        $e = @($zip.Entries | Where-Object { $_.FullName -eq $entry })
        if ($e.Count -ne 1) { throw "Entry '$entry' not found once in $($info.Name)" }
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Item -LiteralPath $target).Length -eq $e[0].Length) { return $target }
        if (-not(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = $target + '.' + [guid]::NewGuid().ToString('N') + '.part'
        try {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e[0], $tmp, $true)
            if ((Get-Item -LiteralPath $tmp).Length -ne $e[0].Length) { throw "Extracted size mismatch for $entry" }
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
            [IO.File]::Move($tmp, $target)
        } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
    } finally { $zip.Dispose() }
    return $target
}
function Select-PASVaultMediaRoot {
    <# The Vault recipe scans one media folder for the packages and the VC++ runtimes. Start at the folder that
       holds the Vault packages and walk up only while the runtimes are missing; stop at the first folder where
       the media resolver finds them unambiguously, so sibling media trees (other versions) are never scanned. #>
    param([string]$Start, [string]$Limit, [string]$Mode, [hashtable]$Overrides = @{})
    if (-not $Start) { return $Limit }
    if (-not $Limit) { $Limit = $Start }
    $dir = $Start
    while ($dir) {
        $rows = @(Find-PASMedia -Path $dir -Mode $Mode -Overrides $Overrides | Where-Object { $_.Key -in @('VCx86', 'VCx64') })
        $ambiguous = @($rows | Where-Object Status -eq 'Ambiguous')
        if ($ambiguous.Count) { throw ("Several copies of the VC++ runtime were found under $dir (" + (($ambiguous | ForEach-Object { $_.Candidates }) -join ', ') + '). Keep one copy next to the Vault media, or add the media folder itself instead of its parent.') }
        if (@($rows | Where-Object Status -ne 'Ready').Count -eq 0) { return $dir }
        # Never climb above the common folder of all selected Vault media (the previous behaviour).
        if ($dir.TrimEnd('\', '/').Equals($Limit.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Path]::GetDirectoryName($dir.TrimEnd('\', '/'))
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $Limit
}
function Get-PASCommonDirectory {
    param([string[]]$Paths)
    $dirs = @($Paths | Where-Object { $_ } | ForEach-Object {
            $full = [IO.Path]::GetFullPath($_)
            if (Test-Path -LiteralPath $full -PathType Container) { $full }else { [IO.Path]::GetDirectoryName($full) }
        })
    if (-not $dirs.Count) { return '' }
    $common = $dirs[0]
    foreach ($d in $dirs) {
        while ($common -and
            -not ($d.Equals($common, [StringComparison]::OrdinalIgnoreCase) -or
                $d.StartsWith($common.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
            $parent = [IO.Path]::GetDirectoryName($common)
            if (-not $parent -or $parent -eq $common) {
                $common = ''
                break
            }
            $common = $parent
        }
    }
    return $common
}

function New-PASDeploymentConfiguration {
    <#
    .SYNOPSIS
    Composes one deployment configuration: Vault (Primary, Primary + DR, or an existing Vault) and any
    number of component instances. Nothing is contacted or installed.
    .PARAMETER Instances
    @( @{Type='PVWA';Name='PVWA01';Address='10.0.0.21';Username=''} ). Type PVWA|CPM|PSM|PSMP
    (up to 4 of each). Name is the server hostname shown in the UI; the configuration id is its lowercase
    form. Instances with the same address share one server, named after the first instance.
    Linux instances may carry IdentityFile/KnownHostsFile; otherwise the controller's per-environment
    key under <DataRoot>/ssh/<environment>/ is used (created and authorised on first install).
    .PARAMETER Media
    @{Vault=item;PACLI=item;DR=item;PVWA=item;...;License=item;RecoveryKey=item}: inventory items from
    Get-PASMediaInventory/Get-PASMediaSelection, @{Path;Entry} or plain paths.
    .PARAMETER SecurityProfile
    Lab adds the explicit, audited lab deviations a template-built lab needs (self-signed WinRM
    certificates, RDP to the Vault from the controller, self-signed PVWA certificate pinned by CPM).
    .EXAMPLE
    $sel = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path D:\CyberArkMedia)
    $cfg = New-PASDeploymentConfiguration -Environment MyLab -VaultMode PrimaryDR -PrimaryAddress 192.0.2.11 -DRAddress 192.0.2.12 `
             -ControllerAddress 192.0.2.10 -Media $sel -SecurityProfile Lab `
             -Instances @(@{Type='PVWA';Name='PVWA01';Address='192.0.2.21'},@{Type='CPM';Name='CPM01';Address='192.0.2.21'})
    Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab.json
    #>
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][ValidateSet('Primary', 'PrimaryDR', 'Existing')][string]$VaultMode,
        [object[]]$Instances = @(), [AllowEmptyString()][string]$ControllerAddress = '',
        [AllowEmptyString()][string]$PrimaryAddress = '', [AllowEmptyString()][string]$DRAddress = '',
        [AllowEmptyString()][string]$ExistingVaultAddress = '',
        [string]$Username = 'Administrator', [string]$LinuxUsername = 'root', [hashtable]$Media = @{},
        [ValidateSet('Sequential', 'Parallel')][string]$ExecutionMode = 'Sequential',
        [AllowEmptyString()][string]$PrimaryUsername = '', [AllowEmptyString()][string]$DRUsername = '',
        [ValidateSet('Secure', 'Lab')][string]$SecurityProfile = 'Secure', [switch]$AcceptEula,
        [AllowEmptyString()][string]$InstallerName = '', [AllowEmptyString()][string]$InstallerCompany = '',
        [ValidateSet('None', 'New', 'Existing')][string]$DomainMode = 'None', [AllowEmptyString()][string]$DomainName = '',
        [AllowEmptyString()][string]$DomainControllerAddress = '', [AllowEmptyString()][string]$DomainUsername = '',
        [string]$DataRoot = (Get-PASDataRoot))
    $lab = ($SecurityProfile -eq 'Lab')
    $overrides = [ordered]@{}
    $c = [ordered]@{
        schemaVersion = 2; name = $Environment.Trim(); mediaRoot = ''; controllerAddress = $ControllerAddress.Trim()
        security = [ordered]@{profile = $SecurityProfile; overrides = $overrides }
        vault = [ordered]@{
            address = ''
            adminUser = 'Administrator'
            secretRef = 'VaultAdmin'
            masterSecretRef = 'VaultMaster'
            drSecretRef = 'DRPassword'
            existing = ($VaultMode -eq 'Existing')
        }
        activeDirectory = [ordered]@{
            mode = 'None'
            host = 'dc01'
            domain = 'pam.lab'
            join = @()
            joinUser = 'PAM\Administrator'
            createTestAccounts = $false
        }
        hosts = [ordered]@{}; components = @(); media = [ordered]@{}; options = [ordered]@{}
        execution = [ordered]@{mode = $ExecutionMode }
    }
    # "Who installs": the user and company name the vendor installers record. Empty: the vendor defaults.
    if ($InstallerName.Trim()) {
        $c.options.installerName = $InstallerName.Trim()
    }
    if ($InstallerCompany.Trim()) {
        $c.options.installerCompany = $InstallerCompany.Trim()
    }
    $components = New-Object System.Collections.ArrayList
    $anyWindows = $false
    if ($VaultMode -eq 'Existing') {
        $c.vault.address = $ExistingVaultAddress.Trim()
    } else {
        # The Vault management endpoint is bound to one LOCAL account: plain name, no '.\' prefix.
        $pu = if ($PrimaryUsername) { $PrimaryUsername }else { $Username }
        $pu = ([string]$pu).Trim()
        if ($pu.StartsWith('.\')) { $pu = $pu.Substring(2) }
        $c.vault.address = $PrimaryAddress.Trim()
        $c.vault.managementHost = 'vault01'
        $c.hosts['vault01'] = [ordered]@{address = $PrimaryAddress.Trim(); os = 'Windows'; user = $pu; credentialRef = 'vault01' }
        [void]$components.Add([ordered]@{id = 'vault'; name = 'Vault'; type = 'Vault'; host = 'vault01'; variant = 'Standalone' })
        if ($VaultMode -eq 'PrimaryDR') {
            $du = if ($DRUsername) { $DRUsername }else { $pu }
            $du = ([string]$du).Trim()
            if ($du.StartsWith('.\')) { $du = $du.Substring(2) }
            $c.hosts['dr01'] = [ordered]@{address = $DRAddress.Trim(); os = 'Windows'; user = $du; credentialRef = 'dr01' }
            [void]$components.Add([ordered]@{id = 'dr'; name = 'DR'; type = 'DRVault'; host = 'dr01'; variant = 'StandardDR' })
        }
        $anyWindows = $true
        # The media folder is the common folder of the Vault media (it also holds the VC++ runtimes and
        # the Vault Ansible role the backend takes PAKeyGen and response templates from).
        $vaultItems = @('Vault', 'PACLI', 'DR', 'KeyGen' | Where-Object { $Media.ContainsKey($_) } | ForEach-Object { Get-PASMediaItemValue $Media[$_] 'Path' })
        $vaultStart = Get-PASCommonDirectory $vaultItems
        $vaultLimit = Get-PASCommonDirectory @($vaultItems + @('License', 'RecoveryKey' | Where-Object { $Media.ContainsKey($_) } | ForEach-Object { Get-PASMediaItemValue $Media[$_] 'Path' }))
        foreach ($pair in @(@('Vault', 'ServerZip'), @('PACLI', 'PACLIZip'), @('DR', 'DisasterRecoveryZip'))) {
            if (-not $Media.ContainsKey($pair[0])) { continue }
            if ($pair[0] -eq 'DR' -and $VaultMode -ne 'PrimaryDR') { continue }
            # A package inside the bundle is found by the backend's own bundle resolution.
            if (-not (Get-PASMediaItemValue $Media[$pair[0]] 'Entry')) { $c.media[$pair[1]] = Get-PASMediaItemValue $Media[$pair[0]] 'Path' }
        }
        if ($Media.ContainsKey('License')) { $c.media.License = Resolve-PASMediaItemPath $Media.License $DataRoot }
        if ($Media.ContainsKey('RecoveryKey')) { $c.media.PublicRecoveryKey = Resolve-PASMediaItemPath $Media.RecoveryKey $DataRoot }
        $mediaMode = if ($VaultMode -eq 'PrimaryDR') { 'PrimaryAndDR' }else { 'Primary' }
        $known = @{}
        foreach ($k in @($c.media.Keys)) { $known[$k] = [string]$c.media[$k] }
        $c.mediaRoot = Select-PASVaultMediaRoot -Start $vaultStart -Limit $vaultLimit -Mode $mediaMode -Overrides $known
        if ($lab) { $overrides['Vault.AllowRDP'] = $true }
    }
    $envSafe = Get-PASSafeName $Environment 40
    $sshDir = Join-Path (Join-Path $DataRoot 'ssh') $envSafe
    $byAddress = @{}
    $usedIds = @{}
    foreach ($r in $script:PASReservedIds) { $usedIds[$r] = $true }
    $firstPvwa = ''
    $cpmCount = 0
    $count = @{}
    foreach ($inst in @($Instances | Where-Object { $_ })) {
        $type = [string](Get-PASMediaItemValue $inst 'Type')
        if ($type -notin $script:PASComponentTypes) { throw "Unknown component type: $type" }
        $count[$type] = 1 + [int]$count[$type]
        $name = ([string](Get-PASMediaItemValue $inst 'Name')).Trim()
        if (-not $name) { $name = ('{0}{1:00}' -f $type, $count[$type]) }
        $addr = ([string](Get-PASMediaItemValue $inst 'Address')).Trim()
        $os = if ($type -in $script:PASLinuxTypes) { 'Linux' }else { 'Windows' }
        $user = ([string](Get-PASMediaItemValue $inst 'Username')).Trim()
        if (-not $user) { $user = if ($os -eq 'Linux') { $LinuxUsername }else { $Username } }
        $id = Get-PASSafeName $name 40
        $base = $id
        $n = 2
        while ($usedIds.ContainsKey($id)) {
            $id = ('{0}-{1}' -f $base.Substring(0, [Math]::Min($base.Length, 36)), $n)
            $n++
        }
        $usedIds[$id] = $true
        $addrKey = $addr.ToLowerInvariant()
        if ($addr -and $byAddress.ContainsKey($addrKey)) { $hostId = $byAddress[$addrKey] }
        else {
            $hostId = $id
            $h = [ordered]@{address = $addr; os = $os; user = $user; credentialRef = $hostId }
            if ($os -eq 'Linux') {
                $identity = [string](Get-PASMediaItemValue $inst 'IdentityFile')
                $known = [string](Get-PASMediaItemValue $inst 'KnownHostsFile')
                $h.identityFile = $(if ($identity) { $identity }else { Join-Path $sshDir 'id_ed25519' })
                $h.knownHostsFile = $(if ($known) { $known }else { Join-Path $sshDir 'known_hosts' })
            } else { $anyWindows = $true }
            $c.hosts[$hostId] = $h
            if ($addr) { $byAddress[$addrKey] = $hostId }
        }
        $mediaPath = ''
        $mediaSource = $null
        if ($Media.ContainsKey($type)) {
            $mediaPath = Resolve-PASMediaItemPath $Media[$type] $DataRoot
            # PSMP packages are per distribution: remember where this one came from, so the controller can use the
            # package that matches the server once it can read the server's OS (after the SSH bootstrap).
            if ($type -eq 'PSMP') {
                $srcPath = [string](Get-PASMediaItemValue $Media[$type] 'Path')
                if (-not $srcPath) { $srcPath = [string]$Media[$type] }
                $mediaSource = [ordered]@{path = $srcPath; entry = [string](Get-PASMediaItemValue $Media[$type] 'Entry') }
            }
        }
        $options = [ordered]@{}
        switch ($type) {
            'PVWA' {
                $options.pvwaUrl = 'https://' + $name + '/PasswordVault'
                if ($lab) { $options.createLabCertificate = $true }
                if (-not $firstPvwa) { $firstPvwa = $id }
            }
            'CPM' {
                # Every CPM needs its own Vault user: the first is PasswordManager, the next PasswordManager2, ...
                $cpmCount++
                if ($cpmCount -gt 1) { $options.cpmUser = "PasswordManager$cpmCount" }
            }
            'PSMP' { if ($AcceptEula) { $options.acceptEula = $true } }
            'HTML5GW' { if ($AcceptEula) { $options.acceptEula = $true } }
        }
        $entry = [ordered]@{
            id = $id
            name = $name
            type = $type
            host = $hostId
            variant = 'Standard'
            media = $mediaPath
            options = $options
        }
        if ($mediaSource) { $entry.mediaSource = $mediaSource }
        if ($user -ne [string]$c.hosts[$hostId].user) { $entry.user = $user }
        [void]$components.Add($entry)
    }
    # CPM pins the self-signed certificate of the first PVWA installed in this deployment; the
    # installer reads it from that PVWA over the authenticated management channel at install time.
    if ($lab -and $firstPvwa) {
        foreach ($e in @($components | Where-Object { $_.type -in @('CPM', 'HTML5GW') })) { $e.options.pvwaTrustFrom = $firstPvwa }
        if (@($components | Where-Object { $_.type -eq 'CPM' }).Count) { $overrides['CPM.AllowPinnedLeafTrust'] = $true }
    }
    if ($lab -and $anyWindows) {
        $overrides['WinRM.SkipCACheck'] = $true
        $overrides['WinRM.SkipCNCheck'] = $true
    }
    # Active Directory. New: the server at -DomainControllerAddress becomes the first domain controller of a new
    # forest. Existing: that address is a DNS server of the domain. Either way the Windows servers of PVWA, CPM
    # and PSM are joined before anything is installed on them. Vault servers are never joined.
    if ($DomainMode -ne 'None') {
        $domain = $DomainName.Trim()
        $netbios = $domain.Split('.')[0].ToUpperInvariant()
        $account = $DomainUsername.Trim()
        if (-not $account) {
            $account = $Username
        }
        $account = $account.Split([char]92)[-1]
        $c.activeDirectory.domain = $domain
        $c.activeDirectory.joinUser = $netbios + '\' + $account
        $c.activeDirectory.join = @($components | Where-Object { $_.type -in @('PVWA', 'CPM', 'PSM') } | ForEach-Object { [string]$_.host } | Select-Object -Unique)
        if ($DomainMode -eq 'New') {
            $c.activeDirectory.mode = 'Create'
            $c.hosts['dc01'] = [ordered]@{address = $DomainControllerAddress.Trim(); os = 'Windows'; user = $account; credentialRef = 'dc01' }
            [void]$components.Add([ordered]@{id = 'ad'; name = 'Domain controller'; type = 'AD'; host = 'dc01'; variant = 'NewForest' })
            $anyWindows = $true
            if ($lab) {
                $overrides['WinRM.SkipCACheck'] = $true
                $overrides['WinRM.SkipCNCheck'] = $true
            }
        } else {
            $c.activeDirectory.mode = 'Existing'
            $c.activeDirectory.dnsServers = @($DomainControllerAddress.Trim())
        }
    }
    # An HTML5 Gateway is entered into the PVWA configuration with PACLI, run on a PVWA server of the lab.
    if (@($components | Where-Object { $_.type -eq 'HTML5GW' }).Count -and $Media.ContainsKey('PACLI')) {
        $c.options.pacliPackage = Resolve-PASMediaItemPath $Media.PACLI $DataRoot
    }
    $c.components = @($components.ToArray())
    # A new Vault needs the VC++ runtimes, which CyberArk ships inside the CPM, PVWA and PSM packages. When they
    # are not files in the media folder and this lab installs none of those components, take them from such a
    # package of the media selection (a package inside a bundle is extracted to the media cache once).
    $bringsRuntimes = @($components | Where-Object { $_.type -in @('CPM', 'PVWA', 'PSM') }).Count
    if ($c.mediaRoot -and -not $bringsRuntimes) {
        $runtimeMode = 'Primary'
        if ($VaultMode -eq 'PrimaryDR') {
            $runtimeMode = 'PrimaryAndDR'
        }
        $given = @{}
        foreach ($key in @($c.media.Keys)) {
            $given[$key] = [string]$c.media[$key]
        }
        $missing = @(Find-PASMedia -Path $c.mediaRoot -Mode $runtimeMode -Overrides $given | Where-Object { $_.Key -in @('VCx86', 'VCx64') -and $_.Status -eq 'Missing' })
        $package = @('CPM', 'PVWA', 'PSM' | Where-Object { $Media.ContainsKey($_) }) | Select-Object -First 1
        if ($missing.Count -and $package) {
            $c.options.vcRuntimePackage = Resolve-PASMediaItemPath $Media[$package] $DataRoot
        }
    }
    return $c
}

function Add-PASPlanDetail {
    <# Display fields the desktop needs (instance name, address, OS, installer file). The order and the
       dependencies of the items already come from Get-PASDeploymentPlan. #>
    param($Plan, $Configuration)
    foreach ($item in @($Plan.Items)) {
        $e = @($Configuration.components | Where-Object { $_.id -eq $item.Id })[0]
        $h = $Configuration.hosts[[string]$item.Host]
        $name = if ($e -is [System.Collections.IDictionary] -and $e.Contains('name') -and $e.name) { [string]$e.name }else { [string]$item.Id }
        $media = ''
        if ($item.Type -in @('Vault', 'DRVault')) {
            $key = if ($item.Type -eq 'Vault') { 'ServerZip' }else { 'DisasterRecoveryZip' }
            if ($Configuration.media -and
                $Configuration.media.Contains($key)) { $media = [IO.Path]::GetFileName([string]$Configuration.media[$key]) }
            elseif ($Configuration.mediaRoot) { $media = 'from ' + [IO.Path]::GetFileName(([string]$Configuration.mediaRoot).TrimEnd('\', '/')) }
        } elseif ($e -and $e.Contains('media') -and $e.media) { $media = [IO.Path]::GetFileName([string]$e.media) }
        $item | Add-Member -NotePropertyName Name -NotePropertyValue $name -Force
        $item | Add-Member -NotePropertyName Address -NotePropertyValue ([string]$h.address) -Force
        $item | Add-Member -NotePropertyName Os -NotePropertyValue ([string]$h.os) -Force
        $item | Add-Member -NotePropertyName Media -NotePropertyValue $media -Force
    }
    $existing = if ($Configuration.vault.existing) { [string]$Configuration.vault.address }else { '' }
    $Plan | Add-Member -NotePropertyName ExistingVault -NotePropertyValue $existing -Force
    return $Plan
}
