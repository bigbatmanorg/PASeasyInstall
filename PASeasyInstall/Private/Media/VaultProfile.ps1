function New-PASProfile {
    [CmdletBinding()]
    param([ValidateSet('Primary', 'PrimaryAndDR')][string]$Mode = 'PrimaryAndDR',
        [Parameter(Mandatory)][string]$PrimaryIP, [string]$DRIP = '',
        [Parameter(Mandatory)][string]$ControllerIP,
        [string]$PrimaryUser = 'Administrator', [string]$DRUser = 'Administrator',
        [string]$MediaPath = '', [hashtable]$MediaOverrides = @{},
        [string]$DataDrive = 'C:', [string]$PackagesRoot = 'C:\Cyberark\packages',
        [string]$AutomationRoot = 'C:\Cyberark\Automation',
        [string]$KeysDir = 'C:\Keys', [string]$InstallRoot = 'C:\Program Files (x86)\PrivateArk')
    return [ordered]@{ SchemaVersion = 1
        Mode = $Mode
        PrimaryIP = $PrimaryIP.Trim()
        DRIP = $DRIP.Trim()
        ControllerIP = $ControllerIP.Trim()
        PrimaryUser = $PrimaryUser
        DRUser = $DRUser
        MediaPath = $MediaPath
        MediaOverrides = $MediaOverrides
        DataDrive = $DataDrive
        PackagesRoot = $PackagesRoot
        AutomationRoot = $AutomationRoot
        KeysDir = $KeysDir
        InstallRoot = $InstallRoot
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Test-PASProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [switch]$CheckMedia, [switch]$ForDeployment)
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Profile.Mode -notin @('Primary', 'PrimaryAndDR')) { $problems.Add('Only Primary and PrimaryAndDR are supported') }
    foreach ($field in @('PrimaryIP', 'ControllerIP')) {
        $addr = $null
        if (-not [Net.IPAddress]::TryParse([string]$Profile[$field], [ref]$addr) -or
            $addr.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            $problems.Add("$field must be a valid IPv4 address")
        }
    }
    if ($Profile.Mode -eq 'PrimaryAndDR') {
        $addr = $null
        if (-not [Net.IPAddress]::TryParse([string]$Profile.DRIP, [ref]$addr) -or
            $addr.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            $problems.Add('DRIP must be a valid IPv4 address')
        }
        if ($Profile.DRIP -eq $Profile.PrimaryIP) { $problems.Add('Primary and DR must not share an IP address') }
    }
    if (-not $Profile.PrimaryUser) { $problems.Add('Primary Windows username required') }
    # Proven restricted management endpoint is configured for a single LOCAL user on each Vault.
    # Both targets currently share Settings.Management.User in the data-only inventory.
    if ($Profile.PrimaryUser -notmatch '^[A-Za-z0-9._-]+$') {
        $problems.Add('Current management endpoint requires an unqualified local Windows account name')
    }
    if ($Profile.Mode -eq 'PrimaryAndDR' -and $Profile.DRUser -ne $Profile.PrimaryUser) {
        $problems.Add('Current Vault workflows require the same local management account name on both targets; passwords may differ')
    }
    if ($Profile.DataDrive -notmatch '^[A-Za-z]:$') { $problems.Add('DataDrive must be a Windows drive such as C:') }
    if ($ForDeployment -and
        $env:OS -ne 'Windows_NT') { $problems.Add('Vault FullInstall needs a Windows PowerShell 5.1 controller; Linux is UI/plan only') }
    $media = @()
    if ($CheckMedia) {
        try {
            $media = @(Find-PASMedia -Path $Profile.MediaPath -Mode $Profile.Mode -Overrides $Profile.MediaOverrides)
            foreach ($item in $media) { if ($item.Status -ne 'Ready') { $problems.Add("Media $($item.Key): $($item.Status)") } }
        } catch { $problems.Add("Media scan: $($_.Exception.Message)") }
    }
    return [pscustomobject]@{Valid = ($problems.Count -eq 0); Issues = @($problems.ToArray()); Media = $media }
}

function ConvertTo-PASLiteral {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 25) { throw 'Inventory contains deeply nested data' }
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [string]) { return ("'" + $Value.Replace("'", "''") + "'") }
    if ($Value -is [int] -or $Value -is [long]) { return ([string]$Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = @()
        foreach ($key in $Value.Keys) {
            if ([string]$key -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') { throw "Unsafe inventory key: $key" }
            # A schema-valid key such as join-member is not a bare PowerShell
            # data-file token. Quote every key, including generated target IDs.
            $parts += ("'{0}'={1}" -f $key, (ConvertTo-PASLiteral $Value[$key] ($Depth + 1)))
        }
        return ('@{' + ($parts -join '; ') + '}')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @(foreach ($i in $Value) { ConvertTo-PASLiteral $i ($Depth + 1) })
        return ('@(' + ($parts -join ', ') + ')')
    }
    throw "Unsupported inventory type $($Value.GetType().FullName)"
}

function Export-PASInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Path, [switch]$AllowIncompleteMedia)
    $assessment = Test-PASProfile -Profile $Profile
    if (-not $assessment.Valid) { throw ($assessment.Issues -join '; ') }
    $media = @(Find-PASMedia -Path $Profile.MediaPath -Mode $Profile.Mode -Overrides $Profile.MediaOverrides)
    if (-not $AllowIncompleteMedia) {
        $invalid = @($media | Where-Object { $_.Status -ne 'Ready' })
        if ($invalid.Count) { throw "Media is incomplete or ambiguous: $(@($invalid | ForEach-Object { $_.Key + '=' + $_.Status }) -join ', ')" }
    }
    $values = [ordered]@{}
    foreach ($r in $media) { if ($r.Path) { $values[$r.Key] = $r.Path } }
    # The proven primary preflight parses DRIP unconditionally. Use the primary IP when no DR exists;
    # the inventory contains no DR target in Primary mode and no DR operation is scheduled.
    $drIP = if ($Profile.Mode -eq 'PrimaryAndDR') { [string]$Profile.DRIP } else { [string]$Profile.PrimaryIP }
    $targets = [ordered]@{
        primary = [ordered]@{ComputerName = [string]$Profile.PrimaryIP; Protocol = 'WinRM'; Runtime = 'WindowsPowerShell';
            CredentialRef = 'PrimaryAdmin'; StageRoot = 'C:\ProgramData\PAExec';
            ConfigurationName = @('PAExec.Management', 'Microsoft.PowerShell')
        }
    }
    if ($Profile.Mode -eq 'PrimaryAndDR') {
        $targets['dr'] = [ordered]@{ComputerName = [string]$Profile.DRIP; Protocol = 'WinRM'; Runtime = 'WindowsPowerShell';
            CredentialRef = 'DRAdmin'; StageRoot = 'C:\ProgramData\PAExec'; ConfigurationName = @('PAExec.Management', 'Microsoft.PowerShell')
        }
    }
    $settings = [ordered]@{PackagesRoot = [string]$Profile.PackagesRoot; AutomationRoot = [string]$Profile.AutomationRoot;
        KeysDir = [string]$Profile.KeysDir; InstallRoot = [string]$Profile.InstallRoot; DataDrive = [string]$Profile.DataDrive;
        PrimaryIP = [string]$Profile.PrimaryIP; DRIP = $drIP;
        Hardening = [ordered]@{Architecture = 'StandardVault'; AllowRDP = $false };
        Management = [ordered]@{
            ControllerAddress = [string]$Profile.ControllerIP
            User = [string]$Profile.PrimaryUser
            Endpoint = 'PAExec.Management'
            WinRMPort = 5985
        }
    }
    $data = [ordered]@{SchemaVersion = 1; Targets = $targets; Values = [ordered]@{Settings = $settings; Media = $values } }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -Force -ItemType Directory -Path $directory | Out-Null }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), ((ConvertTo-PASLiteral $data) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    return [IO.Path]::GetFullPath($Path)
}
