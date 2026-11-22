function Test-PASPreflight {
    <#
    .SYNOPSIS
    Checks, without changing anything, that this controller and the servers of a configuration are ready for an installation.
    .DESCRIPTION
    Returns one object per check with Server, Address, Check, Passed and Detail. Passed is $true,
    $false, or empty ($null) when a check could not be made (for example no credential was given).

    On this controller:
    - Windows PowerShell 5.1 (the installer needs it);
    - the configuration is valid and the installer file of every component exists;
    - with a new Vault: the Vault media folder exists.

    For every server of the configuration:
    - the name resolves;
    - the management port answers within 5 seconds: WinRM 5986 (HTTPS) or 5985 (HTTP) as the
      configuration says for Windows, SSH port 22 (or the configured port) for Linux.

    For a Windows server, when its account is in -CredentialMap or -LabPassword is given:
    - a WinRM session opens, with the same settings an installation uses;
    - operating system and Windows PowerShell version;
    - at least 20 GB free on the system drive;
    - no restart is pending.

    For a Linux server:
    - sign-in works, the account is root, and the distribution is one PSMP supports. The sign-in uses
      the SSH key named in the configuration when it exists and is authorised already. Otherwise it
      uses the password of the account (-CredentialMap or -LabPassword), as the first installation
      does, so a wrong root password is found here. The check authorises no key.

    This command never asks for a password and changes nothing on any server: it resolves names, opens
    connections and reads. It does not replace the preflight steps of the installation itself.
    .PARAMETER Path
    Configuration file (JSON).
    .PARAMETER Configuration
    Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration.
    .PARAMETER CredentialMap
    Server accounts: @{ <server id> = PSCredential }. Windows servers without an entry get the network
    checks only.
    .PARAMETER LabPassword
    One password for every server account of the configuration. Only for the Lab security profile.
    .PARAMETER ConnectivityOnly
    Only checks that every server answers on its management port (name resolution and TCP connect).
    Takes a few seconds, needs no credentials and signs in nowhere.
    .EXAMPLE
    Test-PASPreflight -Path .\MyLab.json | Format-Table Server, Check, Passed, Detail -AutoSize

    Network checks only: no credential is given.
    .EXAMPLE
    $lab = Read-Host -AsSecureString 'Lab password'
    Test-PASPreflight -Path .\MyLab.json -LabPassword $lab | Where-Object { $_.Passed -eq $false }

    All checks; shows only what failed.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Configuration')]
        $Configuration,

        [hashtable]$CredentialMap = @{},

        [securestring]$LabPassword,

        [switch]$ConnectivityOnly
    )

    $source = Resolve-PASConfigurationInput -Path $Path -Configuration $Configuration
    $controller = [string]$env:COMPUTERNAME

    # ---- This controller -------------------------------------------------------------------------
    $isDesktop51 = ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5)
    $psDetail = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    if (-not $isDesktop51) {
        $psDetail += '. Installations must be started from Windows PowerShell 5.1 (powershell.exe) on Windows.'
    }
    New-PASPreflightResult -Server '(controller)' -Address $controller -Check 'Windows PowerShell 5.1' -Passed $isDesktop51 -Detail $psDetail

    # Structure first. Without a valid structure the servers cannot be listed, so the checks end here.
    $structure = Test-PASConfiguration @source
    if (-not $structure.Valid) {
        foreach ($issue in @($structure.Issues)) {
            New-PASPreflightResult -Server '(controller)' -Address $controller -Check 'Configuration' -Passed $false -Detail $issue
        }
        return
    }
    New-PASPreflightResult -Server '(controller)' -Address $controller -Check 'Configuration' -Passed $true -Detail 'The configuration is valid'
    $configuration = $structure.Configuration

    # Installer files: the issues that only appear when the media is checked too.
    $withMedia = Test-PASConfiguration -Configuration $configuration -CheckMedia
    $mediaIssues = @($withMedia.Issues | Where-Object { $_ -notin @($structure.Issues) })
    foreach ($issue in $mediaIssues) {
        New-PASPreflightResult -Server '(controller)' -Address $controller -Check 'Installer media' -Passed $false -Detail $issue
    }
    $installsVault = @($configuration.components | Where-Object { $_.type -eq 'Vault' }).Count -gt 0
    if ($installsVault) {
        $mediaRoot = [string]$configuration.mediaRoot
        $rootFound = [bool]($mediaRoot -and (Test-Path -LiteralPath $mediaRoot))
        $rootDetail = "Vault media folder: $mediaRoot"
        if (-not $rootFound) {
            $rootDetail = "The Vault media folder does not exist: '$mediaRoot'"
        }
        New-PASPreflightResult -Server '(controller)' -Address $controller -Check 'Installer media' -Passed $rootFound -Detail $rootDetail
    } elseif (-not $mediaIssues.Count) {
        New-PASPreflightResult -Server '(controller)' -Address $controller -Check 'Installer media' -Passed $true -Detail 'The installer file of every component exists'
    }

    # ---- Credentials: only what was given; nothing is asked ---------------------------------------
    Assert-PASLabPassword $configuration $LabPassword
    $credentials = @{}
    foreach ($key in @($CredentialMap.Keys)) {
        $credentials[$key] = $CredentialMap[$key]
    }
    if ($LabPassword) {
        foreach ($requirement in @(Get-PASInstallRequirement -Configuration $configuration | Where-Object { $_.Kind -eq 'Credential' -and $_.HostId })) {
            if (-not $credentials.ContainsKey($requirement.Key) -and -not $credentials.ContainsKey($requirement.HostId)) {
                $credentials[$requirement.HostId] = [pscredential]::new($requirement.User, $LabPassword.Copy())
            }
        }
    }
    # 'Administrator' becomes '.\Administrator' for WinRM, exactly as for an installation.
    $credentials = ConvertTo-PASControllerCredentialMap $configuration $credentials

    # ---- Every server ----------------------------------------------------------------------------
    foreach ($serverId in @(Get-PASDeploymentHostIds $configuration)) {
        $server = $configuration.hosts[$serverId]
        $address = [string]$server.address
        $isLinux = ([string]$server.os -eq 'Linux')

        # 1. Name resolution (an IP address always "resolves").
        $resolved = $false
        $resolveDetail = ''
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($address))
            $resolved = ($addresses.Count -gt 0)
            $resolveDetail = (@($addresses | ForEach-Object { $_.ToString() }) -join ', ')
        } catch {
            $resolveDetail = "Cannot resolve '$address': $($_.Exception.Message)"
        }
        New-PASPreflightResult -Server $serverId -Address $address -Check 'Name resolves' -Passed $resolved -Detail $resolveDetail
        if (-not $resolved) {
            continue
        }

        # 2. Management port.
        $endpoint = Get-PASManagementEndpoint -Configuration $configuration -ServerId $serverId
        $port = $endpoint.Port
        $portName = $endpoint.Name
        $portOpen = Test-PASTcpPort -ComputerName $address -Port $port -TimeoutSeconds 4
        $portDetail = "$portName port $port answers"
        if (-not $portOpen) {
            $portDetail = "$portName port $port did not answer within 4 seconds. Check that the server is running, the service is enabled and no firewall blocks the port."
        }
        New-PASPreflightResult -Server $serverId -Address $address -Check "TCP port $port" -Passed $portOpen -Detail $portDetail
        if (-not $portOpen -or $ConnectivityOnly) {
            continue
        }

        if ($isLinux) {
            # 3a. Linux: sign in with the controller key if it exists already, otherwise with the password
            # of the account, as the first installation does. Reads only: no key is authorised here.
            $keyFile = [string](Get-PASValue $server 'identityFile' '')
            $knownHosts = [string](Get-PASValue $server 'knownHostsFile' '')
            $keyReady = [bool]($keyFile -and
                $knownHosts -and
                (Test-Path -LiteralPath $keyFile -PathType Leaf) -and
                (Test-Path -LiteralPath $knownHosts -PathType Leaf))
            $ssh = $null
            if ($keyReady) {
                $sshArguments = @(
                    '-i', $keyFile,
                    '-o', 'BatchMode=yes',
                    '-o', 'IdentitiesOnly=yes',
                    '-o', 'StrictHostKeyChecking=yes',
                    '-o', ('UserKnownHostsFile=' + $knownHosts),
                    '-o', 'ConnectTimeout=15',
                    '-n'
                )
                if ($server.Contains('port') -and $server.port) {
                    $sshArguments += @('-p', [string][int]$server.port)
                }
                $sshArguments += @(([string]$server.user + '@' + $address), 'id -u; cat /etc/os-release')
                try {
                    $ssh = Invoke-PASNativeQuiet 'ssh.exe' $sshArguments 60
                } catch {
                    $ssh = @{ ExitCode = 1; Output = [string]$_.Exception.Message }
                }
            }
            if ($ssh -and $ssh.ExitCode -eq 0) {
                New-PASPreflightResult -Server $serverId -Address $address -Check 'SSH key sign-in' -Passed $true -Detail "Signed in as $($server.user) with $keyFile"
            } else {
                # The key does not exist or is not authorised yet. The installation then needs the password.
                $credential = Get-PASHostCredential $configuration $credentials $serverId
                if (-not $credential -or $credential.Password.Length -eq 0) {
                    if ($keyReady) {
                        New-PASPreflightResult -Server $serverId -Address $address -Check 'SSH key sign-in' -Passed $false -Detail ("Key sign-in as $($server.user) failed and no password was given for '$serverId': " + ([string]$ssh.Output).Trim())
                    } else {
                        New-PASPreflightResult -Server $serverId -Address $address -Check 'SSH password sign-in' -Passed $null -Detail "Not checked: the SSH key of the configuration does not exist yet and no account for '$serverId' is in -CredentialMap. The first installation authorises the key with the password."
                    }
                    continue
                }
                try {
                    $ssh = Test-PASSshPasswordSignIn -HostRecord $server -Credential $credential -Lab ([string]$configuration.security.profile -eq 'Lab')
                } catch {
                    $ssh = @{ Checked = $true; ExitCode = 1; Output = [string]$_.Exception.Message }
                }
                if (-not $ssh.Checked) {
                    New-PASPreflightResult -Server $serverId -Address $address -Check 'SSH password sign-in' -Passed $null -Detail $ssh.Detail
                    continue
                }
                if ($ssh.ExitCode -ne 0) {
                    $reason = (@(([string]$ssh.Output) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1)
                    New-PASPreflightResult -Server $serverId -Address $address -Check 'SSH password sign-in' -Passed $false -Detail "Password sign-in as $($server.user) failed. Check the password, and that the server lets $($server.user) sign in with a password over SSH. ($reason)"
                    continue
                }
                New-PASPreflightResult -Server $serverId -Address $address -Check 'SSH password sign-in' -Passed $true -Detail "Signed in as $($server.user) with the password. The installation authorises the controller key."
            }

            # First output line: the numeric user id. The rest: /etc/os-release.
            $lines = @(([string]$ssh.Output) -split "`r?`n")
            $userId = $lines[0].Trim()
            New-PASPreflightResult -Server $serverId -Address $address -Check 'Root account' -Passed ($userId -eq '0') -Detail "User id $userId (PSMP is installed as root, user id 0)"

            $osRelease = ConvertFrom-PASOsRelease (@($lines | Select-Object -Skip 1) -join "`n")
            $osName = [string]$osRelease['PRETTY_NAME']
            if (-not $osName) {
                $osName = ([string]$osRelease['ID'] + ' ' + [string]$osRelease['VERSION_ID']).Trim()
            }
            $variant = Get-PASPsmpVariantForOs ([string]$osRelease['ID']) ([string]$osRelease['VERSION_ID']) ([string]$osRelease['ID_LIKE'])
            $osDetail = $osName
            if ($variant) {
                $osDetail += " (PSMP package variant $variant)"
            } else {
                $osDetail += ' (no PSMP package variant is known for this distribution)'
            }
            New-PASPreflightResult -Server $serverId -Address $address -Check 'Operating system' -Passed ([bool]$variant) -Detail $osDetail
            continue
        }

        # 3b. Windows: open a WinRM session and read a few facts. Needs the account of the server.
        $credential = Get-PASHostCredential $configuration $credentials $serverId
        if (-not $credential) {
            New-PASPreflightResult -Server $serverId -Address $address -Check 'WinRM session' -Passed $null -Detail "Not checked: no account for '$serverId' in -CredentialMap."
            continue
        }
        $session = $null
        try {
            $session = New-PASManagementSession -Configuration $configuration -HostId $serverId -Credential $credential
        } catch {
            New-PASPreflightResult -Server $serverId -Address $address -Check 'WinRM session' -Passed $false -Detail ([string]$_.Exception.Message)
            continue
        }
        try {
            New-PASPreflightResult -Server $serverId -Address $address -Check 'WinRM session' -Passed $true -Detail "Session opened as $($credential.UserName)"

            # Everything in this script block only reads.
            $facts = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem
                $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $env:SystemDrive + "'")
                $pending = @()
                if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
                    $pending += 'Component Based Servicing'
                }
                if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                    $pending += 'Windows Update'
                }
                $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
                if ($sessionManager -and
                    $sessionManager.PSObject.Properties['PendingFileRenameOperations'] -and
                    $sessionManager.PendingFileRenameOperations) {
                    $pending += 'pending file rename operations'
                }
                @{
                    Caption = [string]$os.Caption
                    Version = [string]$os.Version
                    SystemDrive = [string]$env:SystemDrive
                    FreeBytes = [long]$disk.FreeSpace
                    PendingReboot = ($pending -join ', ')
                    PSVersion = $PSVersionTable.PSVersion.ToString()
                    PSMajor = [int]$PSVersionTable.PSVersion.Major
                    PSMinor = [int]$PSVersionTable.PSVersion.Minor
                }
            }

            New-PASPreflightResult -Server $serverId -Address $address -Check 'Operating system' -Passed $true -Detail "$($facts.Caption) ($($facts.Version))"

            $psOk = ($facts.PSMajor -gt 5 -or ($facts.PSMajor -eq 5 -and $facts.PSMinor -ge 1))
            New-PASPreflightResult -Server $serverId -Address $address -Check 'PowerShell version' -Passed $psOk -Detail "Windows PowerShell $($facts.PSVersion) (5.1 is needed)"

            $freeGB = [Math]::Round($facts.FreeBytes / 1GB, 1)
            $spaceDetail = "$freeGB GB free on $($facts.SystemDrive)"
            if ($freeGB -lt 20) {
                $spaceDetail += '. Less than 20 GB: free some space before installing.'
            }
            New-PASPreflightResult -Server $serverId -Address $address -Check 'Free disk space' -Passed ($freeGB -ge 20) -Detail $spaceDetail

            $rebootDetail = 'No restart is pending'
            if ($facts.PendingReboot) {
                $rebootDetail = "A restart is pending ($($facts.PendingReboot)). Restart the server before installing."
            }
            New-PASPreflightResult -Server $serverId -Address $address -Check 'Pending restart' -Passed (-not $facts.PendingReboot) -Detail $rebootDetail
        } catch {
            New-PASPreflightResult -Server $serverId -Address $address -Check 'Server facts' -Passed $false -Detail "The session opened, but reading the server failed: $($_.Exception.Message)"
        } finally {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}
