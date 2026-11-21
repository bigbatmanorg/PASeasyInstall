# Installer files approved by the plan of the running deployment: full path -> SHA-256.
# $null outside a run. The run controller fills it; the Transfer step and the inventory read it.
$script:PASFrozenMedia = $null

function Get-PASHostCredential {
    param([hashtable]$Config, [hashtable]$CredentialMap, [string]$HostId, [string]$ComponentId = '')
    $hostRecord = $Config.hosts[$HostId]
    $keys = @()
    $dedicated = @($Config.components | Where-Object { $_.host -eq $HostId -and $_.type -in @('Vault', 'DRVault') })
    if ($dedicated.Count -eq 1) {
        $keys += @($(if ($dedicated[0].type -eq 'Vault') { 'PrimaryAdmin' }else { 'DRAdmin' }))
        if (-not $ComponentId) { $ComponentId = [string]$dedicated[0].id }
    }
    if ($ComponentId) { $keys += @($ComponentId) }
    $keys += @($HostId)
    if ($hostRecord.Contains('credentialRef')) {
        $reference = $hostRecord.credentialRef
        if ($reference -isnot [string] -or
            [string]::IsNullOrWhiteSpace($reference)) { throw "Host '$HostId' credentialRef must be a nonempty string" }
        $keys += @($reference)
    }
    foreach ($key in @($keys | Select-Object -Unique)) {
        if ($CredentialMap.ContainsKey($key)) {
            if ($CredentialMap[$key] -isnot [pscredential]) { throw "CredentialMap[$key] must be a PSCredential" }
            return $CredentialMap[$key]
        }
    }
    return $null
}
function Resolve-PASCredentialMap {
    param([hashtable]$Config, [hashtable]$CredentialMap)
    # Keep durable inventory references stable and never add aliases to the caller's map.
    $resolved = $CredentialMap.Clone()
    foreach ($hostId in @(Get-PASDeploymentHostIds $Config)) {
        if ($Config.hosts[$hostId].os -ne 'Windows') { continue }
        $credential = Get-PASHostCredential $Config $CredentialMap $hostId
        if ($credential -and -not $resolved.ContainsKey($hostId)) { $resolved[$hostId] = $credential }
    }
    foreach ($component in @($Config.components)) {
        $hostId = [string]$component.host
        $id = [string]$component.id
        if ($Config.hosts[$hostId].os -ne 'Windows') { continue }
        $credential = Get-PASHostCredential $Config $CredentialMap $hostId $id
        if ($credential -and -not $resolved.ContainsKey($id)) { $resolved[$id] = $credential }
    }
    # A Vault is dedicated: its native role, management host and diagnostic
    # component must use the same selected identity, including explicit overrides.
    foreach ($component in @($Config.components | Where-Object { $_.type -in @('Vault', 'DRVault') })) {
        $hostId = [string]$component.host
        $id = [string]$component.id
        $credential = Get-PASHostCredential $Config $CredentialMap $hostId $id
        if ($credential) {
            $role = if ($component.type -eq 'Vault') { 'PrimaryAdmin' }else { 'DRAdmin' }
            $resolved[$role] = $credential
            $resolved[$hostId] = $credential
            $resolved[$id] = $credential
        }
    }
    return $resolved
}
function ConvertTo-PASControllerCredentialMap {
    <# WinRM from a workgroup controller needs an explicit local account: 'Administrator' becomes
       '.\Administrator' (the target's own account), as the management endpoint expects.
       Applied once, when a deployment is started or resumed. Linux and non-host credentials
       (for example PSMDomainInstaller) pass through unchanged. #>
    param($Configuration, [hashtable]$CredentialMap)
    $out = @{}
    foreach ($key in @($CredentialMap.Keys)) {
        $cred = $CredentialMap[$key]
        if ($cred -isnot [pscredential]) { throw "CredentialMap[$key] must be a PSCredential" }
        $hostRecord = $null
        if ($Configuration.hosts.Contains([string]$key)) {
            $hostRecord = $Configuration.hosts[[string]$key]
        } else {
            $component = @($Configuration.components | Where-Object { $_.id -eq $key })
            if ($component.Count) { $hostRecord = $Configuration.hosts[[string]$component[0].host] }
        }
        $user = [string]$cred.UserName
        if ($hostRecord -and $hostRecord.os -eq 'Windows' -and $user -and $user -notmatch '[\\@]') {
            $cred = [pscredential]::new('.\' + $user, $cred.Password)
        }
        $out[$key] = $cred
    }
    return $out
}
function Resolve-PASSecretMap {
    param([hashtable]$Config, [hashtable]$SecretMap)
    $resolved = $SecretMap.Clone()
    $vault = Get-PASValue $Config 'vault' @{}
    if ($null -eq $vault) { $vault = @{} }
    foreach ($pair in @(@('secretRef', 'VaultAdmin'), @('masterSecretRef', 'VaultMaster'), @('drSecretRef', 'DRPassword'))) {
        $reference = $pair[1]
        if ($vault.Contains($pair[0])) {
            $reference = $vault[$pair[0]]
            if ($reference -isnot [string] -or [string]::IsNullOrWhiteSpace($reference)) { throw "Vault $($pair[0]) must be a nonempty string" }
        }
        if ($SecretMap.ContainsKey($reference)) {
            if ($SecretMap[$reference] -isnot [securestring]) { throw "$reference SecureString is required (SecretMap[$reference])" }
            $resolved[$pair[1]] = $SecretMap[$reference]
        } elseif ($SecretMap.ContainsKey($pair[1]) -and
            $SecretMap[$pair[1]] -isnot [securestring]) { throw "$($pair[1]) SecureString is required (SecretMap[$($pair[1])])" }
    }
    return $resolved
}
function Get-PASDeploymentPlan {
    [CmdletBinding()]param([string]$Config, $Configuration, [switch]$ResolveMedia)
    $validated = Test-PASConfiguration -Config $Config -Configuration $Configuration
    if (-not $validated.Valid) { throw ('Configuration invalid: ' + ($validated.Issues -join '; ')) }
    $c = $validated.Configuration
    $items = New-Object System.Collections.ArrayList
    $components = @($c.components | Where-Object { $null -ne $_ })
    # Order of a run: AD, domain joins, Vault (+DR), then PVWA, CPM, PSM, PSMP.
    # PVWA registration creates the PVWA environment in the Vault (PVWAConfig safe, PVWAGWAccounts group)
    # that CPM, PSM and PSMP registration need, so they all wait for the first PVWA of the deployment.
    $priority = @{AD = 0; Vault = 10; DRVault = 20; PVWA = 30; CPM = 40; PSM = 50; PSMP = 60 }
    $ordered = @($components | Sort-Object -Property @{Expression = { [int]$priority[[string]$_.type] } }, id)
    $ids = @($ordered | ForEach-Object { [string]$_.id })
    $hasVault = (@($ordered | Where-Object { $_.type -eq 'Vault' }).Count -gt 0)
    $firstPvwa = @($ordered | Where-Object { $_.type -eq 'PVWA' } | Select-Object -First 1)
    if ($c.activeDirectory.mode -eq 'Create' -and
        @($ordered | Where-Object { $_.type -eq 'AD' }).Count -eq 0) { throw 'Create AD requires an AD component in components[]' }
    foreach ($entry in $ordered) {
        $deps = @()
        $type = [string]$entry.type
        if ($type -ne 'AD' -and
            $c.activeDirectory.mode -eq 'Create') { $deps += @($ordered | Where-Object { $_.type -eq 'AD' } | ForEach-Object { $_.id }) }
        if ($type -notin @('AD', 'Vault') -and $hasVault) { $deps += @($ordered | Where-Object { $_.type -eq 'Vault' } | ForEach-Object { $_.id }) }
        if ($type -in @('CPM', 'PSM', 'PSMP') -and $firstPvwa.Count) { $deps += @([string]$firstPvwa[0].id) }
        # A CPM that pins the PVWA certificates of this deployment needs every PVWA installed first.
        $trustFrom = [string](Get-PASValue (Get-PASValue $entry 'options' $null) 'pvwaTrustFrom' '')
        if ($trustFrom) { $deps += @($ordered | Where-Object { $_.type -eq 'PVWA' } | ForEach-Object { [string]$_.id }) }
        $deployable = if ($type -eq 'AD') { 'ImplementationReadyForQualification' }elseif ($type -in @('Vault', 'DRVault')) { 'MigratedNeedsRequalification' }else { 'RecipePreparedNeedsVendorMediaQualification' }
        [void]$items.Add([pscustomobject]@{
                Id = [string]$entry.id
                Type = $type
                Host = [string]$entry.host
                Variant = [string](Get-PASValue $entry 'variant' 'Standard')
                DependsOn = @($deps | Sort-Object -Unique)
                Readiness = $deployable
            })
    }
    $media = @()
    if ($ResolveMedia) { $media = @(Get-PASFrozenMedia $c) }
    $mediaDigest = Get-PASTextDigest (($media | ConvertTo-Json -Depth 8 -Compress) -join '')
    $fingerprint = Get-PASTextDigest ((ConvertTo-PASCanonical $c) | ConvertTo-Json -Depth 60 -Compress)
    $joins = @(foreach ($hostId in @($c.activeDirectory.join)) {
            [pscustomobject]@{
                Id = ('join-' + [string]$hostId)
                Host = [string]$hostId
                Domain = [string]$c.activeDirectory.domain
                Stages = @('DNS', 'Join', 'Reboot', 'SecureChannelAndSRV')
                DependsOn = @($ordered | Where-Object { $_.type -eq 'AD' } | ForEach-Object { $_.id })
            }
        })
    return [pscustomobject]@{
        Name = [string]$c.name
        ConfigDigest = $fingerprint
        MediaResolved = [bool]$ResolveMedia
        Media = $media
        MediaDigest = $mediaDigest
        Items = @($items.ToArray())
        DomainJoins = $joins
        Warnings = $validated.Warnings
        ExecutionMode = 'Sequential'
        SchemaVersion = 2
    }
}
# Canonical object order is required: the detached controller is a separate process and
# Hashtable/JSON property order must not invalidate an unchanged deployment plan.
function ConvertTo-PASCanonical {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        [string[]]$keys = @($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $ordered[$key] = ConvertTo-PASCanonical $Value[$key] }
        return $ordered
    }
    if ($Value -is [pscustomobject]) {
        $ordered = [ordered]@{}
        [string[]]$names = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        foreach ($name in $names) { $ordered[$name] = ConvertTo-PASCanonical $Value.PSObject.Properties[$name].Value }
        return $ordered
    }
    if ($Value -is [array]) {
        $list = @(foreach ($item in $Value) { , (ConvertTo-PASCanonical $item) })
        return , $list
    }
    return $Value
}
function Get-PASTextDigest {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}
function Get-PASComponentStageNames {
    # The installation stages of one component type, in order. The single source for the workflow
    # generator below and for Get-PASStageCatalog.
    #   PVWA, CPM, PSM, PSMP: stage names of the component recipe (Task.ps1 / Task.sh). The step id of a
    #                         stage is its lower-case name.
    #   AD:                   the step ids of the fixed Active Directory workflow written below.
    param([Parameter(Mandatory)][string]$Type)
    switch ($Type) {
        'AD' { return @('ad-prerequisites', 'ad-install', 'ad-reboot', 'ad-verify') }
        'PVWA' { return @('Extract', 'Prerequisites', 'Install', 'ConfigureTLS', 'Register', 'Harden', 'Verify') }
        'CPM' { return @('Extract', 'Prerequisites', 'Install', 'ConfigureTLS', 'Register', 'Harden', 'Verify') }
        'PSM' { return @('Extract', 'Prerequisites', 'Install', 'Register', 'Harden', 'PostInstall', 'Verify') }
        default { return @('Extract', 'Prerequisites', 'Install', 'Register', 'Harden', 'Verify') }
    }
}
function New-PASComponentWorkflow {
    param([hashtable]$Component, [hashtable]$Configuration, [string]$RunDirectory)
    $id = [string]$Component.id
    $type = [string]$Component.type
    $basedir = Join-Path (Join-Path $RunDirectory 'Payloads') $id
    $workflowDir = Join-Path $basedir 'Workflows'
    New-Item -Path $workflowDir -ItemType Directory -Force | Out-Null
    $mode = 'WindowsComponent'
    if ($type -eq 'PSMP') { $mode = 'LinuxComponent' }
    $source = Join-Path $script:PASRoot ('Recipes/' + $mode)
    foreach ($file in @(Get-ChildItem -LiteralPath $source -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $basedir $file.Name) -Force
    }
    # The executor sends one reviewed task, not a source-tree directory. Inline only
    # these static recipe helpers so Direct and Detached run the identical payload.
    if ($mode -eq 'WindowsComponent') {
        foreach ($taskName in @('Task.ps1', 'Verify.ps1', 'PrepareTransfer.ps1')) {
            $taskPath = Join-Path $basedir $taskName
            $task = [IO.File]::ReadAllText($taskPath)
            foreach ($helper in @('Vendor.ps1', 'Psm.ps1', 'Archive.ps1', 'Workspace.ps1', 'Ownership.ps1', 'PvwaTls.ps1', 'CpmTls.ps1')) {
                $include = ". (Join-Path `$PSScriptRoot '$helper')"
                if ($task.Contains($include)) {
                    # Generic dispatcher mentions other CyberArk types, but the packaged task must
                    # require ONLY the active component module. Inactive branch includes are removed
                    # at packaging time and can never run for this target's fixed Settings.Type.
                    $owner = switch ($helper) { 'PvwaTls.ps1' { 'PVWA' }'CpmTls.ps1' { 'CPM' }'Psm.ps1' { 'PSM' }default { '' } }
                    if ($owner -and $owner -ne $type) {
                        $task = $task.Replace($include, '# Inactive component helper removed from frozen payload')
                    } else {
                        $helperPath = Get-PASRecipePath ('Recipes/' + $mode + '/' + $helper)
                        if (-not(Test-Path -LiteralPath $helperPath)) { throw "Missing reviewed recipe helper: $helper" }
                        $task = $task.Replace($include, [IO.File]::ReadAllText($helperPath))
                    }
                }
            }
            [IO.File]::WriteAllText($taskPath, $task, [Text.UTF8Encoding]::new($false))
        }
    }
    $steps = @()
    if ($type -eq 'AD') {
        $source = Join-Path (Get-PASModuleRoot) 'Recipes/ActiveDirectory'
        foreach ($file in @(Get-ChildItem -LiteralPath $source -File)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $basedir $file.Name) -Force
        }
        $steps = @(
            @{
                Id = 'ad-prerequisites'
                Script = 'AD-Task.ps1'
                Mode = 'Detached'
                Inputs = @{
                    Stage = 'Preflight'
                    Settings = @{ConfigRef = ('Values.Components.' + $id) }
                }
                Verify = 'AD-Verify.ps1'
                TimeoutSeconds = 600
            }
            @{
                Id = 'ad-install'
                Script = 'AD-Task.ps1'
                Mode = 'Detached'
                Inputs = @{
                    Stage = 'Install'
                    Settings = @{ConfigRef = ('Values.Components.' + $id) }
                    SafeModePassword = @{SecretRef = 'ADSafeMode' }
                }
                Verify = 'AD-Verify.ps1'
                TimeoutSeconds = 2400
                Critical = $true
            }
            @{
                Id = 'ad-reboot'
                Kind = 'Reboot'
                RebootFromAttempt = 'ad-install'
                RebootRequiredFrom = 'ad-install'
                TimeoutSeconds = 1800
            }
            @{
                Id = 'ad-verify'
                Script = 'AD-Task.ps1'
                Inputs = @{
                    Stage = 'Verify'
                    Settings = @{ConfigRef = ('Values.Components.' + $id) }
                }
                Verify = 'AD-Verify.ps1'
                TimeoutSeconds = 600
                Critical = $true
            }
        )
    } else {
        $scriptPath = 'Task.ps1'
        $verifyPath = 'Verify.ps1'
        if ($mode -eq 'LinuxComponent') {
            $scriptPath = 'Task.sh'
            $verifyPath = 'Verify.sh'
        }
        $steps = @()
        if ($mode -eq 'WindowsComponent') {
            $steps += @{
                Id = 'management'
                Script = 'PrepareManagement.ps1'
                Mode = 'Detached'
                Critical = $true
                Inputs = @{Settings = @{ConfigRef = ('Values.Components.' + $id) } }
                Verify = 'VerifyManagement.ps1'
                TimeoutSeconds = 600
            }
        }
        if ($Component.media) {
            $dst = if ($mode -eq 'WindowsComponent') { 'C:\ProgramData\PASeasyInstall\media\' + $id + '\installer.zip' }else { '/opt/paeasyinstall/media/' + $id + '/installer.zip' }
            $transfer = @{
                Id = 'media-upload'
                Kind = 'Transfer'
                Source = @{ConfigRef = ('Values.Components.' + $id + '.MediaZip') }
                Destination = $dst
                TimeoutSeconds = 3600
            }
            if ($mode -eq 'WindowsComponent') {
                $transfer.BeforeTransfer = 'PrepareTransfer.ps1'
                $transfer.Inputs = @{Settings = @{ConfigRef = ('Values.Components.' + $id) } }
            }
            $steps += $transfer
        } else { throw "Component $id requires media ZIP" }
        if ($type -eq 'CPM' -and (Get-PASValue $Component.options 'pvwaTrustCertificateFile' '')) {
            $steps += @{
                Id = 'pvwa-trust-certificate'
                Kind = 'Transfer'
                Source = @{ConfigRef = ('Values.Components.' + $id + '.PVWATrustCertificateFile') }
                Destination = ('C:\ProgramData\PASeasyInstall\media\' + $id + '\pvwa-trust.cer')
                TimeoutSeconds = 600
            }
        }
        $steps += @{
            Id = 'preflight'
            Script = $scriptPath
            Inputs = @{
                Stage = 'Preflight'
                Settings = @{ConfigRef = ('Values.Components.' + $id) }
            }
            Verify = $verifyPath
            TimeoutSeconds = 600
        }
        $stages = @(Get-PASComponentStageNames $type)
        foreach ($stage in $stages) {
            $step = @{
                Id = $stage.ToLowerInvariant()
                Script = $scriptPath
                Inputs = @{
                    Stage = $stage
                    Settings = @{ConfigRef = ('Values.Components.' + $id) }
                }
                Verify = $verifyPath
                TimeoutSeconds = 3600
            }
            if ($stage -eq 'Verify') {
                $step.Remove('Script')
                $step.Kind = 'Verify'
            }
            if ($stage -in @('Install', 'ConfigureTLS', 'Register', 'Harden')) { $step['Critical'] = $true }
            if ($stage -in @('Extract', 'Prerequisites', 'Install', 'ConfigureTLS', 'Register', 'Harden', 'PostInstall') -and
                $mode -in @('WindowsComponent', 'LinuxComponent')) { $step['Mode'] = 'Detached' }
            if ($stage -eq 'Register') {
                $step.Inputs['VaultPassword'] = @{SecretRef = 'VaultAdmin' }
                $step.RequiresVaultSession = $true
            }
            if ($type -eq 'PSM' -and $stage -in @('Prerequisites', 'Install', 'Register', 'Harden', 'PostInstall')) {
                $principalRef = ''
                $psmOptions = Get-PASValue $Component 'options' $null
                if ($psmOptions -and
                    (Get-PASValue $psmOptions 'taskPrincipalCredentialRef' '')) { $principalRef = [string](Get-PASValue $psmOptions 'taskPrincipalCredentialRef' '') }
                elseif ($Configuration.activeDirectory.mode -ne 'None' -and
                    @($Configuration.activeDirectory.join) -contains [string]$Component.host) { $principalRef = 'PSMDomainInstaller' }
                if ($principalRef) { $step.TaskPrincipalCredentialRef = $principalRef }
            }
            if ($type -eq 'PSM' -and $stage -in @('Prerequisites', 'Install', 'Register', 'Harden', 'PostInstall')) {
                # Vendor delayedrestart stages may stop before MSI work and require the SAME
                # stage after reboot. Each continuation has its own durable engine attempt.
                foreach ($pass in 1..3) {
                    $node = $step.Clone()
                    if ($pass -gt 1) { $node.Id = ($step.Id + '-pass' + $pass) }
                    $steps += $node
                    $steps += @{Id = ($node.Id + '-reboot'); Kind = 'Reboot'; RebootRequiredFrom = $node.Id; TimeoutSeconds = 1800 }
                }
            } else {
                $steps += $step
            }
        }
    }
    # Scripts and their workflow live in an immutable per-run payload; run resume pins the digest.
    $wf = @{SchemaVersion = 1; Name = ($type + ' ' + $id); Target = $id; Root = '..'; Steps = $steps }
    $wfPath = Join-Path $workflowDir ($id + '.psd1')
    [IO.File]::WriteAllText($wfPath, (ConvertTo-PASLiteral $wf), [Text.UTF8Encoding]::new($false))
    return $wfPath
}
function New-PASRuntimeInventory {
    # -ComponentId limits the inventory to one component (its target and its values). The run controller
    # writes one inventory per component, right before that component runs.
    param(
        [hashtable]$Config,
        [string]$RunDirectory,
        [switch]$SkipMediaHash,
        [hashtable]$CredentialMap = @{},
        [string]$ComponentId = ''
    )
    $targets = @{}
    $values = @{}
    foreach ($entry in @($Config.components)) {
        if ($ComponentId -and [string]$entry.id -ne $ComponentId) { continue }
        $id = [string]$entry.id
        $hostId = [string]$entry.host
        $host = $Config.hosts[$hostId]
        $linux = ($host.os -eq 'Linux')
        $targets[$id] = @{ComputerName = [string]$host.address; Protocol = $(if ($linux) { 'SSH' }else { 'WinRM' });
            Runtime = $(if ($linux) { 'Bash' }else { 'WindowsPowerShell' }); CredentialRef = $id;
            LockKey = $hostId; StageRoot = 'C:\ProgramData\PASeasyInstall';
            ConfigurationName = @('PASeasyInstall.Management', 'PAExec.Management', 'Microsoft.PowerShell')
        }
        if ($entry.type -eq 'AD') { $targets[$id]['TransitionCredentialRef'] = ($id + '-domain') }
        if ($linux) {
            $targets[$id].Remove('StageRoot')
            $targets[$id].Remove('ConfigurationName')
            $targets[$id]['User'] = [string]$host.user
            if ($host.Contains('identityFile')) { $targets[$id]['IdentityFile'] = [string]$host.identityFile }
            if ($host.Contains('knownHostsFile')) { $targets[$id]['KnownHostsFile'] = [string]$host.knownHostsFile }
        }
        $requiresTls = $true
        if ($Config.security.profile -eq 'Lab' -and
            $Config.security.overrides.Contains('WinRM.RequireHTTPS')) { $requiresTls = [bool]$Config.security.overrides['WinRM.RequireHTTPS'] }
        if ($host.Contains('useSsl')) { $requiresTls = [bool]$host.useSsl }
        if (-not $linux) { $targets[$id]['UseSSL'] = $requiresTls }
        if ($Config.security.profile -eq 'Lab') {
            foreach ($flag in @('WinRM.SkipCACheck', 'WinRM.SkipCNCheck')) {
                if ($Config.security.overrides.Contains($flag)) { $targets[$id][$flag.Replace('WinRM.', '')] = [bool]$Config.security.overrides[$flag] }
            }
        }
        if ($host.Contains('port')) { $targets[$id]['Port'] = [int]$host.port }
        $componentSettings = @{Id = $id; Type = [string]$entry.type; MediaZip = [string](Get-PASValue $entry 'media' '');
            MediaTarget = $(if ($linux) { ('/opt/paeasyinstall/media/' + $id + '/installer.zip') }else { ('C:\ProgramData\PASeasyInstall\media\' + $id + '\installer.zip') });
            StageRoot = $(if ($linux) { ('/opt/paeasyinstall/components/' + $id) }else { ('C:\ProgramData\PASeasyInstall\components\' + $id) });
            Address = [string]$host.address;
            VaultAddress = [string]$Config.vault.address; VaultUser = [string]$Config.vault.adminUser;
            Domain = [string](Get-PASValue $Config.activeDirectory 'domain' ''); SecurityProfile = [string]$Config.security.profile;
            ApplyHardening = $true; ValidateTLS = $true; Options = @{}
        }
        $componentSettings.MediaSHA256 = ''
        if (-not $linux) {
            $managementCredential = Get-PASHostCredential $Config $CredentialMap $hostId $id
            $componentSettings.ManagementUser = if ($managementCredential -is [pscredential]) { $managementCredential.UserName }else { [string]$host.user }
            $componentSettings.ManagementEndpoint = 'PASeasyInstall.Management'
        }
        if (-not $SkipMediaHash -and $componentSettings.MediaZip -and (Test-Path -LiteralPath $componentSettings.MediaZip -PathType Leaf)) {
            $mediaPath = [IO.Path]::GetFullPath($componentSettings.MediaZip)
            if ($null -ne $script:PASFrozenMedia -and
                $script:PASFrozenMedia.ContainsKey($mediaPath)) { $componentSettings.MediaSHA256 = [string]$script:PASFrozenMedia[$mediaPath] }
            else { $componentSettings.MediaSHA256 = (Get-FileHash -LiteralPath $mediaPath -Algorithm SHA256).Hash }
        }
        if ($entry.Contains('options') -and $entry.options) {
            # Copy: the inventory must not share (and later change) the configuration's own options.
            foreach ($optionName in @($entry.options.Keys)) { $componentSettings.Options[[string]$optionName] = $entry.options[$optionName] }
        }
        if ($entry.type -eq 'CPM') {
            $componentSettings.PVWATrustCertificateFile = [string](Get-PASValue $componentSettings.Options 'pvwaTrustCertificateFile' '')
            $componentSettings.PVWATrustCertificateSHA256 = [string](Get-PASValue $componentSettings.Options 'pvwaTrustCertificateSHA256' '')
            $componentSettings.PVWATrustCertificateTarget = if ($componentSettings.PVWATrustCertificateFile) { 'C:\ProgramData\PASeasyInstall\media\' + $id + '\pvwa-trust.cer' }else { '' }
            $componentSettings.AllowPinnedLeafTrust = $false
            if ($Config.security.profile -eq 'Lab' -and
                $Config.security.overrides.Contains('CPM.AllowPinnedLeafTrust')) { $componentSettings.AllowPinnedLeafTrust = [bool]$Config.security.overrides['CPM.AllowPinnedLeafTrust'] }
        }
        if ($Config.security.profile -eq 'Lab' -and $Config.security.overrides) {
            $ck = ([string]$entry.type + '.ApplyHardening')
            if ($Config.security.overrides.Contains($ck)) { $componentSettings.ApplyHardening = [bool]$Config.security.overrides[$ck] }
            $vk = if ($entry.type -eq 'CPM') { 'CPM.ValidatePVWA' }else { [string]$entry.type + '.ValidateTLS' }
            if ($Config.security.overrides.Contains($vk)) { $componentSettings.ValidateTLS = [bool]$Config.security.overrides[$vk] }
        }
        $values[$id] = $componentSettings
    }
    return @{SchemaVersion = 1; Targets = $targets; Values = @{Components = $values } }
}

# Domain joins are separate durable host workflows, not implicit side effects of other recipes.
function New-PASDomainJoinWorkflow {
    param([hashtable]$Config, [string]$HostId, [string]$RunDirectory)
    $id = 'join-' + $HostId
    $hostObj = $Config.hosts[$HostId]
    if (-not $hostObj -or $hostObj.os -ne 'Windows') { throw "Domain join supports Windows hosts only: $HostId" }
    $base = Join-Path (Join-Path $RunDirectory 'Payloads') $id
    $wfdir = Join-Path $base 'Workflows'
    New-Item -ItemType Directory -Path $wfdir -Force | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path (Get-PASModuleRoot) 'Recipes/ActiveDirectory') -File)) {
        Copy-Item $file.FullName -Destination (Join-Path $base $file.Name) -Force
    }
    foreach ($taskName in @('Join-Task.ps1', 'Join-Verify.ps1')) {
        $path = Join-Path $base $taskName
        $text = [IO.File]::ReadAllText($path)
        $text = $text.Replace(". (Join-Path `$PSScriptRoot 'Join-State.ps1')", [IO.File]::ReadAllText((Join-Path $base 'Join-State.ps1')))
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    }
    $wf = @{SchemaVersion = 1; Name = ('Domain join ' + $HostId); Target = $id; Root = '..'; Steps = @(
            @{
                Id = 'dns'
                Script = 'Join-Task.ps1'
                Inputs = @{
                    Stage = 'Check'
                    Settings = @{ConfigRef = ('Values.Components.' + $id) }
                }
                Verify = 'Join-Verify.ps1'
                TimeoutSeconds = 300
            },
            @{
                Id = 'join'
                Script = 'Join-Task.ps1'
                Mode = 'Detached'
                Inputs = @{
                    Stage = 'Join'
                    Settings = @{ConfigRef = ('Values.Components.' + $id) }
                    DomainPassword = @{SecretRef = 'DomainJoinPassword' }
                }
                Verify = 'Join-Verify.ps1'
                Critical = $true
                TimeoutSeconds = 900
            },
            @{Id = 'reboot'; Kind = 'Reboot'; TimeoutSeconds = 1800 },
            @{
                Id = 'verify'
                Script = 'Join-Task.ps1'
                Inputs = @{
                    Stage = 'Verify'
                    Settings = @{ConfigRef = ('Values.Components.' + $id) }
                }
                Verify = 'Join-Verify.ps1'
                TimeoutSeconds = 600
            }
        )
    }
    $wfpath = Join-Path $wfdir ($id + '.psd1')
    [IO.File]::WriteAllText($wfpath, (ConvertTo-PASLiteral $wf), [Text.UTF8Encoding]::new($false))
    $inv = @{SchemaVersion = 1; Targets = @{}; Values = @{Components = @{} } }
    $inv.Targets[$id] = @{ComputerName = [string]$hostObj.address
        Protocol = 'WinRM'
        Runtime = 'WindowsPowerShell'
        CredentialRef = $HostId
        ConfigurationName = @('PASeasyInstall.Management', 'PAExec.Management', 'Microsoft.PowerShell')
        LockKey = $HostId
        StageRoot = 'C:\ProgramData\PASeasyInstall'
    }
    $joinTls = $true
    if ($Config.security.profile -eq 'Lab' -and
        $Config.security.overrides.Contains('WinRM.RequireHTTPS')) { $joinTls = [bool]$Config.security.overrides['WinRM.RequireHTTPS'] }
    if ($hostObj.Contains('useSsl')) { $joinTls = [bool]$hostObj.useSsl }
    $inv.Targets[$id].UseSSL = $joinTls
    if ($hostObj.Contains('port')) { $inv.Targets[$id].Port = [int]$hostObj.port }
    if ($Config.security.profile -eq 'Lab') {
        foreach ($flag in @('WinRM.SkipCACheck', 'WinRM.SkipCNCheck')) {
            if ($Config.security.overrides.Contains($flag)) { $inv.Targets[$id][$flag.Replace('WinRM.', '')] = [bool]$Config.security.overrides[$flag] }
        }
    }
    $inv.Values.Components[$id] = @{
        Domain = [string]$Config.activeDirectory.domain
        JoinUser = [string]$Config.activeDirectory.joinUser
        StageRoot = ('C:\ProgramData\PASeasyInstall\components\' + $id)
    }
    $dns = @(Get-PASValue $Config.activeDirectory 'dnsServers' @())
    if (-not $dns.Count -and $Config.activeDirectory.mode -eq 'Create') {
        $dc = @($Config.components | Where-Object { $_.type -eq 'AD' })
        if ($dc.Count -eq 1) { $dns = @([string]$Config.hosts[[string]$dc[0].host].address) }
    }
    if (-not $dns.Count) { throw 'Domain join requires activeDirectory.dnsServers (or an unambiguous new forest IPv4 address)' }
    foreach ($server in $dns) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse([string]$server, [ref]$ip) -or
            $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $ip.Equals([Net.IPAddress]::Any) -or
            $ip.Equals([Net.IPAddress]::Broadcast)) { throw 'Domain DNS servers must be valid IPv4 addresses' }
    }
    $inv.Values.Components[$id].DnsServers = @($dns)
    $inv.Values.Components[$id].InterfaceIndex = [int](Get-PASValue $hostObj 'interfaceIndex' 0)
    $invpath = Join-Path $RunDirectory ($id + '-inventory.psd1')
    [IO.File]::WriteAllText($invpath, (ConvertTo-PASLiteral $inv), [Text.UTF8Encoding]::new($false))
    return @{Workflow = $wfpath; Inventory = $invpath; Target = $id }
}

function Get-PASVaultMediaStatus {
    # The files a Vault installation needs besides the installer ZIPs: license, public recovery key, PAKeyGen,
    # the response templates and the VC++ runtimes. Returns one row per file (Key, Label, Status, Path).
    # A row whose Status is not 'Ready' blocks the installation. Returns nothing when no Vault is installed.
    param([hashtable]$Configuration)
    if (-not @($Configuration.components | Where-Object { $_ -and $_.type -eq 'Vault' }).Count) {
        return @()
    }
    $mode = 'Primary'
    if (@($Configuration.components | Where-Object { $_ -and $_.type -eq 'DRVault' }).Count) {
        $mode = 'PrimaryAndDR'
    }
    $profile = New-PASProfile -Mode $mode -PrimaryIP ([string]$Configuration.vault.address) `
        -ControllerIP ([string]$Configuration.controllerAddress) -MediaPath ([string]$Configuration.mediaRoot) `
        -MediaOverrides $Configuration.media
    $profile = Resolve-PASMediaProfile -Profile $profile -ComponentPackages (Get-PASComponentPackagePaths $Configuration)
    return @(Find-PASMedia -Path $profile.MediaPath -Mode $mode -Overrides $profile.MediaOverrides)
}

function Get-PASFrozenMedia {
    param([hashtable]$Configuration)
    $files = @()
    foreach ($component in $Configuration.components) {
        if ($component.type -notin @('Vault', 'DRVault', 'AD')) {
            $path = [string](Get-PASValue $component 'media' '')
            if (-not $path -or -not(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing media for component $($component.id)" }
            $files += [IO.Path]::GetFullPath($path)
            if ($component.type -eq 'CPM') {
                $trust = [string](Get-PASValue $component.options 'pvwaTrustCertificateFile' '')
                if ($trust) {
                    if (-not(Test-Path -LiteralPath $trust -PathType Leaf)) { throw 'CPM public trust certificate source missing' }
                    if ((Get-FileHash -LiteralPath $trust -Algorithm SHA256).Hash -ine [string]$component.options.pvwaTrustCertificateSHA256) { throw 'CPM public trust certificate differs from its configured SHA256' }
                    $files += [IO.Path]::GetFullPath($trust)
                }
            }
        }
    }
    foreach ($entry in @(Get-PASVaultMediaStatus -Configuration $Configuration)) {
        if ($entry.Status -ne 'Ready') {
            throw "Vault media $($entry.Key): $($entry.Status)"
        }
        $files += [IO.Path]::GetFullPath($entry.Path)
    }
    foreach ($path in @($files | Sort-Object -Unique)) {
        $before = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($before.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Media file must not be a reparse point' }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $after = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc) { throw 'Media changed while hashing' }
        [pscustomobject][ordered]@{Path = $path; Length = $after.Length; SHA256 = $hash }
    }
}
