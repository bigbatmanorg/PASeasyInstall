# Desired-state configuration. Pure data; no executable strings or plaintext secrets.
function Read-PASConfiguration {
    param([string]$Path, $Configuration)
    if ($Path -and $null -ne $Configuration) { throw 'Supply -Config OR -Configuration, not both' }
    if ($Path) {
        if (-not(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
        $Configuration = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    if ($null -eq $Configuration) { throw 'Deployment configuration required' }
    $result = ConvertTo-PASHashtable $Configuration
    if ($result -isnot [System.Collections.IDictionary]) { throw 'Configuration root must be an object' }
    return $result
}
function Get-PASDeploymentHostIds {
    param([hashtable]$Configuration)
    return @(@($Configuration.components | ForEach-Object { [string]$_.host }) + @($Configuration.activeDirectory.join) | Where-Object { $_ } | Sort-Object -Unique)
}
function New-PASConfigurationTemplate {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([ValidateSet('Vault', 'VaultDR', 'FullLab', 'ADOnly', 'ExistingVault', 'DomainJoin')][string]$Template = 'FullLab',
        [Parameter(Mandatory)][string]$Path, [switch]$Force)
    $hosts = @{
        'vault01' = @{address = '192.0.2.11'; os = 'Windows'; user = 'Administrator'; credentialRef = 'vault01' }
        'dr01' = @{address = '192.0.2.12'; os = 'Windows'; user = 'Administrator'; credentialRef = 'dr01' }
        'pam01' = @{address = '192.0.2.13'; os = 'Windows'; user = 'Administrator'; credentialRef = 'pam01' }
        'psm01' = @{address = '192.0.2.14'; os = 'Windows'; user = 'Administrator'; credentialRef = 'psm01' }
        'psmp01' = @{address = '192.0.2.15'; os = 'Linux'; user = 'root'; credentialRef = 'psmp01' }
        'dc01' = @{address = '192.0.2.10'; os = 'Windows'; user = 'Administrator'; credentialRef = 'dc01' }
    }
    $comps = @()
    if ($Template -in @('Vault', 'VaultDR', 'FullLab')) {
        $comps += @{
            id = 'vault'
            type = 'Vault'
            host = 'vault01'
            variant = 'Standalone'
        }
    }
    if ($Template -in @('VaultDR', 'FullLab')) { $comps += @{id = 'dr'; type = 'DRVault'; host = 'dr01'; variant = 'StandardDR' } }
    if ($Template -eq 'FullLab') {
        $comps += @{id = 'pvwa'; type = 'PVWA'; host = 'pam01'; variant = 'Standard'; options = @{} }
        $comps += @{id = 'cpm'; type = 'CPM'; host = 'pam01'; variant = 'Standard'; options = @{} }
        $comps += @{id = 'psm'; type = 'PSM'; host = 'psm01'; variant = 'Standard'; options = @{} }
        $comps += @{id = 'psmp'; type = 'PSMP'; host = 'psmp01'; variant = 'Standard'; options = @{} }
    }
    if ($Template -eq 'ADOnly') { $comps += @{id = 'ad'; type = 'AD'; host = 'dc01'; variant = 'NewForest' } }
    if ($Template -eq 'ExistingVault') { $comps += @{id = 'pvwa'; type = 'PVWA'; host = 'pam01'; variant = 'Standard'; options = @{} } }
    $config = [ordered]@{
        schemaVersion = 2; name = 'PASeasyLab'; mediaRoot = 'F:\CyberArk\InstallMedia'; controllerAddress = '192.0.2.2'
        security = @{profile = 'Secure'; overrides = @{} }
        vault = @{
            address = '192.0.2.11'
            adminUser = 'Administrator'
            secretRef = 'VaultAdmin'
            masterSecretRef = 'VaultMaster'
            drSecretRef = 'DRPassword'
            existing = ($Template -eq 'ExistingVault')
        }
        activeDirectory = @{
            mode = $(if ($Template -eq 'ADOnly') { 'Create' }else { 'None' })
            host = 'dc01'
            domain = 'pam.lab'
            join = @()
            joinUser = 'PAM\Administrator'
            createTestAccounts = $false
        }
        hosts = $hosts; components = $comps; media = @{}; options = @{}
    }
    if ($Template -eq 'ADOnly') {
        $config.vault.existing = $true
        $config.activeDirectory.join = @()
    }
    if ($Template -eq 'DomainJoin') {
        $config.vault.existing = $true
        $config.activeDirectory.mode = 'Existing'
        $config.activeDirectory.join = @('pam01')
        $config.activeDirectory.dnsServers = @('192.0.2.10')
    }
    if ((Test-Path -LiteralPath $Path) -and -not $Force) { throw "Configuration exists: $Path (use -Force to overwrite)" }
    if ($PSCmdlet.ShouldProcess($Path, 'Create sample deployment configuration')) {
        Write-PASJsonAtomic -Path $Path -Data $config
    }
    return $config
}
function Test-PASConfiguration {
    # The one validation of a deployment configuration: structure, topology and composition rules and,
    # with -CheckMedia, the installer files. Accepts hand-written and composed (New-PASDeploymentConfiguration)
    # configurations alike. Contacts no server. Returns Valid, Issues, Warnings and the normalized Configuration.
    [CmdletBinding()]param([string]$Config, $Configuration, [switch]$CheckMedia, [switch]$Strict)
    $c = Read-PASConfiguration -Path $Config -Configuration $Configuration
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if ([int]$c.schemaVersion -ne 2) { $issues.Add('schemaVersion must be 2') }
    if ([string]$c.name -notmatch '^[A-Za-z0-9_.-]{1,64}$') { $issues.Add('name must be 1-64 safe characters') }
    if ($c.hosts -isnot [System.Collections.IDictionary]) { $issues.Add('hosts must be an object') }
    $ids = @{}
    $windows = @('Vault', 'DRVault', 'PVWA', 'CPM', 'PSM', 'AD')
    $linux = @('PSMP')
    if ($c.vault -is [System.Collections.IDictionary]) {
        foreach ($field in @('secretRef', 'masterSecretRef', 'drSecretRef')) {
            if ($c.vault.Contains($field) -and
                ($c.vault[$field] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($c.vault[$field]))) { $issues.Add("Vault $field must be a nonempty string") }
        }
    }
    foreach ($entry in @($c.components)) {
        if ($null -eq $entry) { continue }
        $id = [string]$entry.id
        $type = [string]$entry.type
        $host = [string]$entry.host
        if ($id -notmatch '^[a-z][a-z0-9_-]{0,39}$' -or
            $ids.ContainsKey($id)) { $issues.Add("Invalid or duplicate component id '$id'") }else { $ids[$id] = $true }
        if ($type -notin @($windows + $linux)) { $issues.Add("Unsupported component type: $type") }
        if (-not $c.hosts -or -not $c.hosts.Contains($host)) {
            $issues.Add("Component $id references unknown host $host")
            continue
        }
        $target = $c.hosts[$host]
        $entryOptions = Get-PASValue $entry 'options' $null
        $label = [string](Get-PASValue $entry 'name' '')
        if (-not $label) { $label = $id }
        if ($type -eq 'PSMP' -and -not [bool](Get-PASValue $entryOptions 'acceptEula' $false)) {
            $issues.Add("Accept the CyberArk license agreement (EULA) for the PSMP installer ($label): options.acceptEula = true")
        }
        # pvwaTrustFrom: this CPM pins the HTTPS certificate of a PVWA of the same deployment. The run
        # controller reads that certificate from the PVWA server right before the CPM is installed.
        $trustFrom = [string](Get-PASValue $entryOptions 'pvwaTrustFrom' '')
        if ($trustFrom) {
            if ($type -ne 'CPM') { $issues.Add("${label}: options.pvwaTrustFrom is only valid for a CPM") }
            if (@($c.components | Where-Object { $_ -and [string]$_.id -eq $trustFrom -and $_.type -eq 'PVWA' }).Count -ne 1) {
                $issues.Add("$label trusts PVWA '$trustFrom', which is not part of this deployment")
            }
            if (Get-PASValue $entryOptions 'pvwaTrustCertificateFile' '') { $issues.Add("${label}: use either options.pvwaTrustFrom or options.pvwaTrustCertificateFile, not both") }
        }
        $entryUser = [string](Get-PASValue $entry 'user' '')
        if ($entryUser -and [string]$target.user -ne $entryUser) {
            $issues.Add("$label shares server $host with another component but uses account '$entryUser' instead of '$($target.user)'")
        }
        if ($type -in $windows -and $target.os -ne 'Windows') { $issues.Add("$type requires Windows ($host)") }
        if ($type -in $linux -and $target.os -ne 'Linux') { $issues.Add("$type requires Linux ($host)") }
        if ($type -in @('Vault', 'DRVault', 'AD') -and
            @($c.components | Where-Object { $_ -and $_.host -eq $host }).Count -gt 1) { $issues.Add("$type must have its own dedicated host ($host)") }
        if ($type -in @('Vault', 'DRVault') -and
            @($c.activeDirectory.join) -contains $host) { $issues.Add("Vault host $host must not be domain joined") }
        if ($type -eq 'AD' -and $c.activeDirectory.mode -eq 'None') { $issues.Add('AD selected but activeDirectory.mode=None') }
        if ($type -eq 'PSM') { $warnings.Add('PSM restricts untrusted creation at the Windows Temp root to protect the native TLS backup; existing child permissions are preserved. Connector compatibility requires functional qualification.') }
        if ($type -eq 'CPM') {
            $options = Get-PASValue $entry 'options' @{}
            $trustFile = [string](Get-PASValue $options 'pvwaTrustCertificateFile' '')
            $trustHash = [string](Get-PASValue $options 'pvwaTrustCertificateSHA256' '')
            if (($trustFile -or
                    $trustHash) -and
                (-not $trustFile -or
                $trustHash -notmatch '^[A-Fa-f0-9]{64}$')) { $issues.Add('CPM public trust certificate requires options.pvwaTrustCertificateFile and pvwaTrustCertificateSHA256') }
            if ($CheckMedia -and
                $trustFile -and
                -not(Test-Path -LiteralPath $trustFile -PathType Leaf)) { $issues.Add('CPM public trust certificate file is missing') }
            if ((Get-PASValue $options 'allowPinnedLeafTrust' $null) -ne $null) { $issues.Add('CPM leaf trust exception must use audited Lab security override CPM.AllowPinnedLeafTrust') }
        }
        if ($type -eq 'PSMP') { $warnings.Add("$type Linux installation requires qualification on the selected target distribution and supplied media") }
        if ($CheckMedia -and $type -notin @('Vault', 'DRVault', 'AD')) {
            $mediaPath = [string](Get-PASValue $entry 'media' '')
            if (-not $mediaPath -or
                -not(Test-Path -LiteralPath $mediaPath -PathType Leaf)) { $issues.Add("Media ZIP missing for component '$id' ($mediaPath)") }
        }
    }
    if ($CheckMedia -and $issues.Count -eq 0) {
        # The Vault needs more than its installer ZIPs. Report every missing file here, before a run is started.
        try {
            foreach ($row in @(Get-PASVaultMediaStatus -Configuration $c)) {
                if ($row.Status -eq 'Ready') {
                    continue
                }
                $hint = ''
                if ($row.Key -in @('PAKeyGenExe', 'PAKeyGenDll1', 'PAKeyGenDll2', 'VaultTemplate', 'DRTemplate', 'VC2013x86')) {
                    $hint = ' (it comes from the "Vault Ansible Role" ZIP of the CyberArk media; put that ZIP into the media folder)'
                }
                if ($row.Key -in @('VCx86', 'VCx64')) {
                    $hint = ' (put the CPM, PVWA or PSM ZIP into the media folder: it contains the runtime. Or download VC_redist.x86.exe and VC_redist.x64.exe from Microsoft and put them there)'
                }
                $issues.Add("Vault media file '$($row.Label)' is $($row.Status)$hint")
            }
        } catch {
            $issues.Add("Vault media could not be checked: $($_.Exception.Message)")
        }
    }
    # A public join-only run has no CyberArk media or Vault authentication dependency.
    # Keep empty deployments invalid unless they explicitly join eligible Windows hosts.
    $joinOnly = $c.activeDirectory.mode -eq 'Existing' -and @($c.activeDirectory.join).Count -gt 0
    if ($joinOnly) {
        foreach ($joinId in @($c.activeDirectory.join)) {
            if (-not $c.hosts.Contains([string]$joinId) -or $c.hosts[[string]$joinId].os -ne 'Windows') { $joinOnly = $false }
        }
    }
    if (@($c.components).Count -eq 0 -and
        -not $joinOnly) { $issues.Add('At least one component or an explicit Existing AD Windows domain join is required') }
    foreach ($limited in @('PVWA', 'CPM', 'PSM', 'PSMP')) {
        if (@($c.components | Where-Object { $_ -and $_.type -eq $limited }).Count -gt 4) { $issues.Add("At most 4 $limited server(s) are supported") }
    }
    # 'execution' is written by New-PASDeploymentConfiguration. A run always installs one component after
    # the other; the key is accepted so that saved configurations keep loading.
    $execution = Get-PASValue $c 'execution' $null
    if ($null -ne $execution) {
        $executionMode = [string](Get-PASValue $execution 'mode' 'Sequential')
        if ($executionMode -notin @('Sequential', 'Parallel')) { $issues.Add('execution.mode must be Sequential or Parallel') }
        elseif ($executionMode -eq 'Parallel') { $warnings.Add('execution.mode Parallel is no longer supported; the components are installed one after the other') }
    }

    if ($c.activeDirectory.mode -notin @('None', 'Create', 'Existing')) { $issues.Add('activeDirectory.mode must be None, Create or Existing') }
    if ($c.activeDirectory.mode -eq 'Create' -and
        @($c.components | Where-Object { $_.type -eq 'AD' }).Count -ne 1) { $issues.Add('AD mode Create requires one AD component') }
    if ($c.activeDirectory.mode -eq 'Existing' -and
        @($c.components | Where-Object { $_.type -eq 'AD' }).Count) { $issues.Add('AD component is only for creating a new domain') }
    if (@($c.activeDirectory.join).Count -gt 0 -and $c.activeDirectory.mode -ne 'None') {
        foreach ($hName in @($c.activeDirectory.join)) {
            if (-not $c.hosts.Contains([string]$hName)) {
                $issues.Add("Domain join host does not exist: $hName")
                continue
            }
            if ($c.hosts[[string]$hName].os -ne 'Windows') { $issues.Add("Linux domain joins are not implemented: $hName") }
            if (@($c.components | Where-Object { $_.host -eq $hName -and $_.type -in @('Vault', 'DRVault', 'AD') }).Count) { $issues.Add("Vault/DC cannot be joined by deployment: $hName") }
        }
    }
    # Multiple host IDs for one literal endpoint bypass dedicated-role and join guards.
    # Co-location must use one host record so every policy sees the same identity.
    $usedHosts = @(Get-PASDeploymentHostIds $c)
    $reservedCredentialAliases = @()
    if (@($c.components | Where-Object { $_.type -eq 'Vault' }).Count) { $reservedCredentialAliases += @('PrimaryAdmin', 'DRAdmin') }
    $reservedCredentialAliases += @($c.components | Where-Object { $_.type -eq 'AD' } | ForEach-Object { ([string]$_.id) + '-domain' })
    foreach ($entry in @($c.components)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.id -in $usedHosts -and
            [string]$entry.id -ne [string]$entry.host) { $issues.Add("Component '$($entry.id)' collides with a different host's credential key; use distinct IDs") }
        if ([string]$entry.id -in $reservedCredentialAliases) { $issues.Add("Component '$($entry.id)' collides with a reserved runtime credential alias") }
    }
    foreach ($hostId in $usedHosts) {
        if ($hostId -in $reservedCredentialAliases) { $issues.Add("Host '$hostId' collides with a reserved runtime credential alias") }
    }
    $seenAddresses = @{}
    foreach ($hostId in $usedHosts) {
        if (-not $c.hosts.Contains($hostId)) { continue }
        $hostRecord = $c.hosts[$hostId]
        if ($hostRecord.Contains('credentialRef') -and
            ($hostRecord.credentialRef -isnot [string] -or
            [string]::IsNullOrWhiteSpace($hostRecord.credentialRef))) { $issues.Add("Host '$hostId' credentialRef must be a nonempty string") }
        $address = ([string]$c.hosts[$hostId].address).TrimEnd('.').ToLowerInvariant()
        $ip = $null
        if ([Net.IPAddress]::TryParse($address, [ref]$ip)) {
            if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
            $address = $ip.ToString()
        }
        if ($seenAddresses.ContainsKey($address)) { $issues.Add("Host aliases $($seenAddresses[$address]) and $hostId use the same endpoint; use one host record for co-location") }
        else { $seenAddresses[$address] = $hostId }
    }
    $shared = @($c.components | Where-Object { $_.type -in @('PVWA', 'CPM', 'PSM') } | Group-Object -Property { [string]$_.host } | Where-Object { $_.Count -gt 1 })
    foreach ($group in $shared) { $warnings.Add("Co-located components on $($group.Name) require lab qualification; vendor Orchestrator does not qualify the combination") }
    if ($c.activeDirectory.mode -ne 'None' -and
        [string]$c.activeDirectory.domain -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{2,252}$') { $issues.Add('Invalid AD DNS domain name') }
    if ($c.activeDirectory.mode -eq 'Create' -and
        $c.vault.existing -and
        @($c.components | Where-Object { $_.type -notin @('AD') }).Count -gt 0) { $warnings.Add('Existing Vault configured; no new primary Vault will be installed') }
    if ($ids.ContainsKey('dr') -and -not $ids.ContainsKey('vault')) { $issues.Add('DR requires Primary Vault in the same new deployment') }
    if (@($c.components | Where-Object { $_.type -eq 'DRVault' }).Count -gt 0 -and
        (@($c.components | Where-Object { $_.type -eq 'Vault' }).Count -ne 1 -or
        [bool]$c.vault.existing)) { $issues.Add('DR is only supported with a new Primary Vault in the same deployment; attaching DR to an existing Vault is not supported') }
    if (@($c.components | Where-Object { $_.type -eq 'Vault' }).Count -gt 1) { $issues.Add('Only one new primary Vault is qualified in v2') }
    if (@($c.components | Where-Object { $_.type -eq 'DRVault' }).Count -gt 1) { $issues.Add('Only one DR Vault is qualified in v2') }
    if ($c.security.profile -notin @('Secure', 'Lab')) { $issues.Add('security.profile must be Secure or Lab') }
    if ($c.security.profile -eq 'Secure' -and
        $c.security.overrides -and
        $c.security.overrides.Count -gt 0) { $issues.Add('Security overrides require profile Lab') }
    if ($c.security.overrides) {
        foreach ($name in $c.security.overrides.Keys) {
            if ($c.security.overrides[$name] -isnot [bool]) { $issues.Add("Security override $name must be a JSON boolean") }
            if ($name -notin @('Vault.AllowRDP', 'PVWA.ValidateTLS', 'CPM.ValidatePVWA', 'CPM.AllowPinnedLeafTrust', 'WinRM.RequireHTTPS', 'WinRM.SkipCACheck', 'WinRM.SkipCNCheck', 'PVWA.ApplyHardening', 'CPM.ApplyHardening', 'PSM.ApplyHardening', 'PSMP.ApplyHardening')) {
                $issues.Add("Unknown/unsupported lab override '$name'")
            } else { $warnings.Add("SECURITY DEVIATION: $name = $($c.security.overrides[$name])") }
        }
    }
    foreach ($key in @($c.hosts.Keys)) {
        if ($key -notmatch '^[a-z][a-z0-9_-]{0,39}$') { $issues.Add("Invalid host id '$key'") }
        $h = $c.hosts[$key]
        if (-not $h.address -or [string]$h.address -match '[\s;`"\x00-\x1f]') { $issues.Add("Unsafe/empty address for $key") }
        if ($h.os -notin @('Windows', 'Linux')) { $issues.Add("Invalid OS for $key") }
        if ($h.os -eq 'Linux' -and -not $h.user) { $issues.Add("SSH user required for $key") }
        if ($h.os -eq 'Windows' -and $c.security.profile -eq 'Secure' -and $h.Contains('useSsl') -and -not [bool]$h.useSsl) {
            $issues.Add("Secure policy requires WinRM HTTPS on Windows host $key. Use Lab with explicit override to allow HTTP")
        }
    }
    # Do not silently persist conventional secret property names in the config.
    $raw = ($c | ConvertTo-Json -Depth 60)
    if ($raw -match '"(?:password|vaultAdminPassword|masterPassword|secretValue)"\s*:') { $issues.Add('Configuration appears to contain a plaintext password field: use credential/secret references') }
    if ($Strict -and $warnings.Count) { foreach ($w in $warnings) { $issues.Add($w) } }
    return [pscustomobject]@{
        Valid = ($issues.Count -eq 0)
        Issues = @($issues.ToArray())
        Warnings = @($warnings.ToArray())
        Configuration = $c
    }
}
