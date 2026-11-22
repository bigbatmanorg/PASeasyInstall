# The CyberArk hardening GPOs of a lab that creates its own domain (activeDirectory.mode = Create).
# After the components are installed, the domain controller imports the vendor's "In Domain" GPO backup for the
# role of each joined server, links it to an organisational unit and moves the server there; then each server
# refreshes its policy. The recipe is Recipes/ActiveDirectory/Gpo-Task.ps1.
# An existing domain is not touched: its administrators import the GPOs themselves.

function Get-PASHardeningGpoRole {
    # Which vendor GPO fits a server, from the component types installed on it. $null: no vendor GPO for this
    # combination. Key (letters only), Title (name of the organisational unit and of the GPO), MediaType (the
    # component whose package holds the backup) and Pattern (the ZIP entry inside that package).
    param([string[]]$Types)
    $set = (@($Types | Where-Object { $_ -in @('PVWA', 'CPM', 'PSM') } | Sort-Object -Unique) -join '+')
    switch ($set) {
        'PVWA' { return @{ Key = 'PVWA'; Title = 'PVWA'; MediaType = 'PVWA'; Pattern = '^Hardening/CyberArk Hardening - .*In Domain - Standalone - PVWA[^/]*\.zip$' } }
        'CPM' { return @{ Key = 'CPM'; Title = 'CPM'; MediaType = 'CPM'; Pattern = '^Hardening/CyberArk Hardening - .*In Domain - Standalone - CPM[^/]*\.zip$' } }
        'CPM+PVWA' { return @{ Key = 'PVWACPM'; Title = 'PVWA and CPM'; MediaType = 'CPM'; Pattern = '^Hardening/CyberArk Hardening - .*In Domain - Shared - CPM PVWA[^/]*\.zip$' } }
        'PSM' { return @{ Key = 'PSM'; Title = 'PSM'; MediaType = 'PSM'; Pattern = '^Hardening/CyberArk Hardening - In Domain - PSM[^/]*\.zip$' } }
    }
    return $null
}

function Get-PASDomainPolicyPlan {
    # The joined servers that get a vendor GPO: one object per server with HostId, Address and Role.
    # Empty unless the lab creates its own domain.
    param([hashtable]$Config)
    $servers = @()
    if ([string]$Config.activeDirectory.mode -ne 'Create') {
        return $servers
    }
    foreach ($hostId in @($Config.activeDirectory.join)) {
        $types = @($Config.components | Where-Object { $_ -and [string]$_.host -eq [string]$hostId } | ForEach-Object { [string]$_.type })
        # A server whose components are installed without hardening (-SkipHardening) gets no hardening GPO either.
        $overrides = Get-PASValue (Get-PASValue $Config 'security' $null) 'overrides' $null
        $unhardened = @($types | Where-Object { $overrides -and $overrides.Contains($_ + '.ApplyHardening') -and -not [bool]$overrides[$_ + '.ApplyHardening'] })
        if ($unhardened.Count) {
            continue
        }
        $role = Get-PASHardeningGpoRole -Types $types
        if ($role) {
            $servers += [pscustomobject]@{ HostId = [string]$hostId; Address = [string]$Config.hosts[[string]$hostId].address; Role = $role }
        }
    }
    return $servers
}

function Export-PASHardeningGpoArchive {
    # Copies the GPO backup ZIP of one role out of its vendor package (a ZIP on this controller) into the run
    # folder and returns the path. Read-only on the package.
    param([hashtable]$Config, [hashtable]$Role, [string]$Directory)
    $package = @($Config.components | Where-Object { $_ -and [string]$_.type -eq $Role.MediaType } | ForEach-Object { [string](Get-PASValue $_ 'media' '') } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $package -or -not (Test-Path -LiteralPath $package -PathType Leaf)) {
        throw "The $($Role.MediaType) package with the hardening GPO for '$($Role.Title)' was not found on this controller"
    }
    $target = Join-Path $Directory ($Role.Key + '.zip')
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        return $target
    }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [IO.Compression.ZipFile]::OpenRead($package)
    try {
        $entries = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -match $Role.Pattern })
        if ($entries.Count -ne 1) {
            throw "Expected one hardening GPO for '$($Role.Title)' in $([IO.Path]::GetFileName($package)); found $($entries.Count)"
        }
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force |
                Out-Null
        }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $target, $false)
    } finally {
        $zip.Dispose()
    }
    return $target
}

function New-PASDomainPolicyWorkflow {
    # Writes the workflows and inventories of the GPO phase into the run folder: first the one for the domain
    # controller ('policy-domain'), then one per joined server ('policy-<server>'). Returns them in run order
    # as @{ Target; Workflow; Inventory }, with the GPO archives in Archives (to be approved for upload).
    param([hashtable]$Config, [string]$RunDirectory)
    $servers = @(Get-PASDomainPolicyPlan -Config $Config)
    if (-not $servers.Count) {
        return @{ Items = @(); Archives = @() }
    }
    $ad = @($Config.components | Where-Object { $_ -and $_.type -eq 'AD' })[0]
    $archiveDirectory = Join-Path $RunDirectory 'gpo'
    $roles = @{}
    foreach ($server in $servers) {
        if (-not $roles.ContainsKey($server.Role.Key)) {
            $roles[$server.Role.Key] = @{ Role = $server.Role; Local = (Export-PASHardeningGpoArchive -Config $Config -Role $server.Role -Directory $archiveDirectory) }
        }
    }
    $items = @()
    $recipes = Join-Path (Get-PASModuleRoot) 'Recipes/ActiveDirectory'

    # Every joined server first: keep the installer's management port open before a GPO turns the firewall on.
    foreach ($server in $servers) {
        $items += New-PASDomainPolicyMemberWorkflow -Config $Config -Server $server -RunDirectory $RunDirectory -Stage 'Prepare'
    }

    # The domain controller: upload one archive per role, then import, link and move.
    $id = 'policy-domain'
    $base = Join-Path (Join-Path $RunDirectory 'Payloads') $id
    $workflowDirectory = Join-Path $base 'Workflows'
    New-Item -ItemType Directory -Path $workflowDirectory -Force |
        Out-Null
    foreach ($name in @('Gpo-Task.ps1', 'Gpo-Verify.ps1')) {
        Copy-Item -LiteralPath (Join-Path $recipes $name) -Destination (Join-Path $base $name) -Force
    }
    $steps = @()
    $roleSettings = @()
    foreach ($key in @($roles.Keys | Sort-Object)) {
        $remote = 'C:\ProgramData\PASeasyInstall\gpo\' + $key + '.zip'
        $steps += @{ Id = ('gpo-upload-' + $key.ToLowerInvariant()); Kind = 'Transfer'; Source = [string]$roles[$key].Local; Destination = $remote; TimeoutSeconds = 600 }
        $roleSettings += ($key + '|' + $roles[$key].Role.Title + '|' + $remote)
    }
    $steps += @{
        Id = 'gpo-import'
        Script = 'Gpo-Task.ps1'
        Mode = 'Detached'
        Inputs = @{ Stage = 'Domain'; Settings = @{ ConfigRef = ('Values.Components.' + $id) } }
        Verify = 'Gpo-Verify.ps1'
        TimeoutSeconds = 900
    }
    $inventory = New-PASRuntimeInventory -Config $Config -RunDirectory $RunDirectory -SkipMediaHash -ComponentId ([string]$ad.id)
    $target = $inventory.Targets[[string]$ad.id]
    $inventory = @{ SchemaVersion = 1; Targets = @{ $id = $target }; Values = @{ Components = @{ $id = @{
                    Domain = [string]$Config.activeDirectory.domain
                    Roles = @($roleSettings)
                    Servers = @($servers | ForEach-Object { $_.Address + '=' + $_.Role.Key })
                } } } }
    $items += Write-PASDomainPolicyFiles -Id $id -Name 'CyberArk hardening GPOs' -Steps $steps -Inventory $inventory -RunDirectory $RunDirectory -WorkflowDirectory $workflowDirectory

    # Every joined server: refresh the policy and check that the GPO was applied.
    foreach ($server in $servers) {
        $items += New-PASDomainPolicyMemberWorkflow -Config $Config -Server $server -RunDirectory $RunDirectory -Stage 'Member'
    }
    return @{ Items = @($items); Archives = @($roles.Values | ForEach-Object { [string]$_.Local }) }
}

function New-PASDomainPolicyMemberWorkflow {
    # One step on a joined server: stage Prepare (target 'policy-prepare-<server>') or Member ('policy-<server>').
    param([hashtable]$Config, $Server, [string]$RunDirectory, [ValidateSet('Prepare', 'Member')][string]$Stage)
    $id = 'policy-' + $Server.HostId
    $stepId = 'gpo-apply'
    if ($Stage -eq 'Prepare') {
        $id = 'policy-prepare-' + $Server.HostId
        $stepId = 'gpo-firewall'
    }
    $base = Join-Path (Join-Path $RunDirectory 'Payloads') $id
    $workflowDirectory = Join-Path $base 'Workflows'
    New-Item -ItemType Directory -Path $workflowDirectory -Force |
        Out-Null
    foreach ($name in @('Gpo-Task.ps1', 'Gpo-Verify.ps1')) {
        Copy-Item -LiteralPath (Join-Path (Join-Path (Get-PASModuleRoot) 'Recipes/ActiveDirectory') $name) -Destination (Join-Path $base $name) -Force
    }
    $steps = @(@{
            Id = $stepId
            Script = 'Gpo-Task.ps1'
            Mode = 'Detached'
            Inputs = @{ Stage = $Stage; Settings = @{ ConfigRef = ('Values.Components.' + $id) } }
            Verify = 'Gpo-Verify.ps1'
            TimeoutSeconds = 900
        })
    # Same connection as the domain join of this server, which this run wrote before.
    $join = Import-PowerShellDataFile -LiteralPath (Join-Path $RunDirectory ('join-' + $Server.HostId + '-inventory.psd1'))
    $inventory = @{ SchemaVersion = 1; Targets = @{ $id = $join.Targets[('join-' + $Server.HostId)] }; Values = @{ Components = @{ $id = @{
                    GpoName = ('CyberArk Hardening - ' + $Server.Role.Title)
                    ManagementPort = [int](Get-PASManagementEndpoint -Configuration $Config -ServerId $Server.HostId).Port
                } } } }
    return (Write-PASDomainPolicyFiles -Id $id -Name ("CyberArk hardening GPO on $($Server.HostId): $Stage") -Steps $steps -Inventory $inventory -RunDirectory $RunDirectory -WorkflowDirectory $workflowDirectory)
}

function Write-PASDomainPolicyFiles {
    param([string]$Id, [string]$Name, [object[]]$Steps, [hashtable]$Inventory, [string]$RunDirectory, [string]$WorkflowDirectory)
    # Written once: on a resume the files of the first start are used again, because the engine pins them.
    $workflowPath = Join-Path $WorkflowDirectory ($Id + '.psd1')
    $inventoryPath = Join-Path $RunDirectory ($Id + '-inventory.psd1')
    if (-not (Test-Path -LiteralPath $workflowPath) -or -not (Test-Path -LiteralPath $inventoryPath)) {
        $workflow = @{ SchemaVersion = 1; Name = $Name; Target = $Id; Root = '..'; Steps = @($Steps) }
        [IO.File]::WriteAllText($workflowPath, (ConvertTo-PASLiteral $workflow), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($inventoryPath, (ConvertTo-PASLiteral $Inventory), [Text.UTF8Encoding]::new($false))
    }
    return @{ Target = $Id; Workflow = $workflowPath; Inventory = $inventoryPath }
}
