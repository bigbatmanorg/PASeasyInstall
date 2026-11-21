# Shared logic of the public commands (Public folder). The public files hold parameters and help;
# what several of them need lives here:
#   - reading and validating the configuration a command was given,
#   - the common path of every Install-* command: validate, confirm, ask for what is missing, start, wait,
#   - composing the configuration of a single component (Install-PASPVWA, -CPM, -PSM, -PSMP),
#   - two small helpers of Test-PASPreflight.

function Resolve-PASConfigurationInput {
    # A command takes its configuration either as a file (-Path) or as an object (-Configuration).
    # Returns the matching arguments for the internal functions: @{ Config = <full path> } or
    # @{ Configuration = <object> }.
    param(
        [string]$Path,
        $Configuration
    )
    if ($Path -and $null -ne $Configuration) {
        throw 'Use either -Path or -Configuration, not both.'
    }
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Configuration file not found: $Path. Check the path, or create a configuration with New-PASLabConfiguration and Export-PASLabConfiguration."
        }
        return @{ Config = (Resolve-Path -LiteralPath $Path).ProviderPath }
    }
    if ($null -eq $Configuration) {
        throw 'No configuration given. Pass -Path <file.json>, or -Configuration with the object returned by New-PASLabConfiguration or Import-PASLabConfiguration.'
    }
    return @{ Configuration = $Configuration }
}

function Get-PASValidatedConfiguration {
    # Validates a configuration and returns its normalized form (nested hashtables).
    # An invalid configuration is an error that lists every issue. Warnings are shown with -ShowWarnings.
    param(
        [string]$Path,
        $Configuration,
        [switch]$CheckMedia,
        [switch]$ShowWarnings
    )
    $source = Resolve-PASConfigurationInput -Path $Path -Configuration $Configuration
    $result = Test-PASConfiguration @source -CheckMedia:$CheckMedia
    if ($ShowWarnings) {
        foreach ($warning in @($result.Warnings)) {
            Write-Warning $warning
        }
    }
    if (-not $result.Valid) {
        $list = (@($result.Issues) | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine
        throw ("The configuration is not ready:" + [Environment]::NewLine + $list + [Environment]::NewLine +
            'Correct these points and run the command again. Test-PASLabConfiguration shows the same list without starting anything.')
    }
    return $result.Configuration
}

function Invoke-PASInstallCommand {
    # The common path of Install-PASLab, Install-PASVault, Install-PASDomainController and the
    # component commands:
    #   1. validate the configuration (and the installer media, unless -PlanOnly),
    #   2. -PlanOnly: return the plan and stop,
    #   3. ask for confirmation (ShouldProcess of the calling command; -WhatIf ends here),
    #   4. only now ask for the credentials and secrets that were not supplied,
    #   5. start the detached run and return its run id, or with -Wait follow it and return the final run.
    param(
        [Parameter(Mandatory)]$Configuration,
        # $PSCmdlet of the public command, so that -WhatIf and -Confirm are answered in its name.
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        # What will be installed, for the confirmation prompt, e.g. 'Install the Primary Vault'.
        [Parameter(Mandatory)][string]$Action,
        # Where, for the confirmation prompt, e.g. '192.0.2.11'. Default: the environment name.
        [string]$Target = '',
        [hashtable]$CredentialMap = @{},
        [hashtable]$SecretMap = @{},
        [securestring]$LabPassword,
        [switch]$PlanOnly,
        [switch]$Wait,
        [int]$PollSeconds = 15
    )
    $ready = Get-PASValidatedConfiguration -Configuration $Configuration -CheckMedia:(-not $PlanOnly) -ShowWarnings
    if ($PlanOnly) {
        $plan = Get-PASDeploymentPlan -Configuration $ready
        return (Add-PASPlanDetail -Plan $plan -Configuration $ready)
    }
    Assert-PASLabPassword $ready $LabPassword

    if (-not $Target) {
        $Target = [string]$ready.name
    }
    if (-not $Cmdlet.ShouldProcess($Target, $Action)) {
        return
    }
    Assert-PASWindowsController

    # Nothing was asked so far. Missing credentials and secrets are prompted for here.
    $auth = Resolve-PASInstallCredential -Configuration $ready -CredentialMap $CredentialMap -SecretMap $SecretMap -LabPassword $LabPassword
    $runId = Start-PASDeployment -Configuration $ready -CredentialMap $auth.Credentials -SecretMap $auth.Secrets -Confirm:$false
    $auth = $null

    if ($Wait) {
        return (Wait-PASRun -RunId $runId -PollSeconds $PollSeconds)
    }
    Write-Verbose "Run $runId started. Follow it with: Wait-PASRun -RunId $runId   or   Get-PASRun -RunId $runId"
    return $runId
}

function New-PASComposedConfiguration {
    # Calls the configuration composer (New-PASDeploymentConfiguration) for an Install-* command.
    # The composer may copy an installer out of a ZIP bundle into the media cache of this controller.
    # That is local preparation, not a change to a server, so it also happens with -WhatIf: without it
    # there would be no configuration to validate or to describe.
    param([Parameter(Mandatory)][hashtable]$Arguments)
    $WhatIfPreference = $false
    return (New-PASDeploymentConfiguration @Arguments)
}

function Get-PASAccountName {
    # The plain account name of a credential for a host record: '.\Administrator' becomes 'Administrator'.
    # Without a credential the default name is returned.
    param(
        [pscredential]$Credential,
        [string]$Default
    )
    if (-not $Credential) {
        return $Default
    }
    $name = ([string]$Credential.UserName).Trim()
    if ($name.StartsWith('.\')) {
        $name = $name.Substring(2)
    }
    if (-not $name) {
        return $Default
    }
    return $name
}

function Get-PASControllerAddressFor {
    # The IPv4 address of this controller that faces a server. The Vault firewall is opened for it.
    # Connecting a UDP socket only asks the routing table which local address would be used:
    # no packet is sent to the server.
    param([Parameter(Mandatory)][string]$ComputerName)
    $socket = New-Object System.Net.Sockets.Socket -ArgumentList @(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp
    )
    try {
        $socket.Connect($ComputerName, 9)
        return $socket.LocalEndPoint.Address.ToString()
    } catch {
        throw "Cannot work out which address of this controller reaches $ComputerName ($($_.Exception.Message)). Pass it with -ControllerAddress."
    } finally {
        $socket.Close()
    }
}

function Select-PASComponentMedia {
    # -MediaPath of a component command is the installer ZIP itself, or a folder or CyberArk bundle ZIP
    # that contains it. Returns what the composer accepts: a media inventory item, or the plain path.
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$MediaPath
    )
    if (-not (Test-Path -LiteralPath $MediaPath)) {
        throw "Media not found: $MediaPath. -MediaPath is the $Type installer ZIP, or a folder or CyberArk bundle ZIP that contains it."
    }
    $full = (Resolve-Path -LiteralPath $MediaPath).ProviderPath
    $inventory = @(Get-PASMediaInventory -Path $full)
    $matching = @($inventory | Where-Object { $_.Component -eq $Type })
    if ($matching.Count) {
        # Several versions or variants: the same choice Get-PASMediaSelection makes everywhere.
        return (Get-PASMediaSelection -Inventory $matching)[$Type]
    }
    $recognised = @($inventory | Where-Object { $_.Component -notin @('Unknown', 'Missing') })
    if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not $recognised.Count) {
        # A single file with a name the inventory does not know (for example a renamed ZIP): trust the caller.
        Write-Warning "$full is not recognised as a $Type installer by its name. It is used as the $Type installer as it is."
        return $full
    }
    $found = (@($recognised | ForEach-Object { $_.Component } | Sort-Object -Unique) -join ', ')
    if (-not $found) {
        $found = 'no CyberArk installer'
    }
    throw "No $Type installer was found in $full (found: $found). Point -MediaPath to the $Type installer ZIP or to the folder that contains it. Get-PASMediaInventory -Path <folder> shows what is recognised."
}

function Invoke-PASComponentInstall {
    # Body of Install-PASPVWA, Install-PASCPM, Install-PASPSM and Install-PASPSMP: one component on one
    # server, registered with a Vault that already exists.
    param(
        [Parameter(Mandatory)][ValidateSet('PVWA', 'CPM', 'PSM', 'PSMP')][string]$Type,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$VaultAddress,
        [Parameter(Mandatory)][string]$MediaPath,
        [string]$Name = 'MyPAM',
        [pscredential]$Credential,
        [securestring]$VaultAdminPassword,
        [securestring]$LabPassword,
        [string]$SecurityProfile = 'Secure',
        # Recipe options of the component (configuration key components[].options). They win over defaults.
        [hashtable]$Options = @{},
        # Lab deviations to add to security.overrides, e.g. @{ 'CPM.AllowPinnedLeafTrust' = $true }.
        [hashtable]$SecurityOverride = @{},
        [switch]$AcceptEula,
        [switch]$Wait,
        [switch]$PlanOnly
    )
    $address = $ComputerName.Trim()
    $defaultUser = 'Administrator'
    if ($Type -eq 'PSMP') {
        $defaultUser = 'root'
    }

    # The component is named after its type: its id (and its server id) is pvwa, cpm, psm or psmp.
    $instance = @{
        Type = $Type
        Name = $Type
        Address = $address
        Username = (Get-PASAccountName -Credential $Credential -Default $defaultUser)
    }
    $configuration = New-PASComposedConfiguration @{
        Environment = $Name
        VaultMode = 'Existing'
        ExistingVaultAddress = $VaultAddress.Trim()
        Instances = @($instance)
        Media = @{ $Type = (Select-PASComponentMedia -Type $Type -MediaPath $MediaPath) }
        SecurityProfile = $SecurityProfile
        AcceptEula = [bool]$AcceptEula
    }
    $component = $configuration.components[0]

    if ($Type -eq 'PVWA') {
        # The composer derives the PVWA URL from the instance name, which here is only 'PVWA'.
        # A DNS name given as -ComputerName is the better URL. For an IP address the option is left
        # out: the recipe then uses the server's own computer name.
        $component.options.Remove('pvwaUrl')
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($address, [ref]$ip)) {
            $component.options['pvwaUrl'] = 'https://' + $address + '/PasswordVault'
        }
    }
    foreach ($key in @($Options.Keys)) {
        $component.options[[string]$key] = $Options[$key]
    }
    foreach ($key in @($SecurityOverride.Keys)) {
        $configuration.security.overrides[[string]$key] = $SecurityOverride[$key]
    }

    $credentialMap = @{}
    if ($Credential) {
        $credentialMap[[string]$component.host] = $Credential
    }
    $secretMap = @{}
    if ($VaultAdminPassword) {
        $secretMap['VaultAdmin'] = $VaultAdminPassword
    }
    $install = @{
        Configuration = $configuration
        Cmdlet = $Cmdlet
        Action = "Install CyberArk $Type (environment '$Name', Vault $($VaultAddress.Trim()))"
        Target = $address
        CredentialMap = $credentialMap
        SecretMap = $secretMap
        LabPassword = $LabPassword
        PlanOnly = $PlanOnly
        Wait = $Wait
    }
    return (Invoke-PASInstallCommand @install)
}

function New-PASPreflightResult {
    # One line of Test-PASPreflight. Passed is $true, $false, or $null when the check was not possible.
    param(
        [string]$Server,
        [string]$Address,
        [string]$Check,
        $Passed,
        [string]$Detail
    )
    return [pscustomobject]@{
        Server = $Server
        Address = $Address
        Check = $Check
        Passed = $Passed
        Detail = $Detail
    }
}

function Test-PASTcpPort {
    # Can a TCP connection be opened? Waits at most -TimeoutSeconds. Nothing is sent after the handshake.
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 5
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
            return $false
        }
        $client.EndConnect($pending)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}
