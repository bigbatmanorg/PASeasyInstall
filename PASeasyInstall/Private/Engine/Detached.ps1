function Get-PASAttemptRoot {
    param([hashtable]$Target, [string]$AttemptId)
    $stage = [string](Get-PASValue $Target 'StageRoot' 'C:\ProgramData\PAExec')
    if ($AttemptId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid attempt ID' }
    return ($stage.TrimEnd('\') + '\attempts\' + $AttemptId)
}
function Get-PASAttemptFolder {
    # Where an attempt keeps its status and its output on the target (Windows or Linux).
    param([hashtable]$Target, [string]$AttemptId)
    if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') { return (Get-PASLinuxAttemptRoot $AttemptId) }
    return (Get-PASAttemptRoot $Target $AttemptId)
}
function Select-PASLastLines {
    # Keeps as many whole lines from the end of a text as fit into MaxCharacters. Lines are never cut,
    # so a secret is never split into a part that redaction no longer recognises.
    param([string]$Text, [int]$MaxCharacters = 3500)
    $kept = New-Object System.Collections.ArrayList
    $length = 0
    $lines = @(([string]$Text) -split "`r?`n")
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $length += $lines[$index].Length + 1
        if ($length -gt $MaxCharacters) { break }
        [void]$kept.Insert(0, $lines[$index])
    }
    return ($kept.ToArray() -join "`n").Trim()
}
function Get-PASDetachedOutputTail {
    <# The last lines of a finished attempt's output, for the failure report. Read-only and bounded.
       Windows: attempts\<id>\stdout.log under the stage root (the task's whole output).
       Linux:   stdout.log.tail and stderr.log.tail under /opt/paeasyinstall/attempts/<id>.
       Returns '' when nothing can be read: fetching the output must never hide the real failure.
       The text is NOT redacted here; the caller redacts it before it is stored or shown. #>
    param([hashtable]$Target, [hashtable]$Credentials, [string]$AttemptId, [int]$Lines = 40)
    try {
        if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') {
            $dir = Get-PASLinuxAttemptRoot $AttemptId
            # The .tail files are at most 256 KiB each (written by the runner).
            $command = 'for name in stdout stderr; do f=' + $dir + '/$name.log.tail; if [ -s "$f" ]; then echo "--- $name"; tail -n ' + $Lines + ' -- "$f"; fi; done; true'
            return [string](Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId -ExistingOnly) + $command))
        }
        $file = (Get-PASAttemptRoot $Target $AttemptId) + '\stdout.log'
        $session = Get-PASConnection $Target $Credentials
        $text = Invoke-Command -Session $session -ArgumentList $file, $Lines -ErrorAction Stop -ScriptBlock {
            param($path, $count)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
            if ((Get-Item -LiteralPath $path).Length -gt 64MB) { return '(stdout.log is larger than 64 MB; read it on the server)' }
            $last = @(Get-Content -LiteralPath $path -Tail $count -ErrorAction Stop)
            # Whole lines only, at most about 64 KiB over the wire.
            while ($last.Count -gt 1 -and
                (($last | Measure-Object -Property Length -Sum).Sum -gt 65536)) { $last = @($last | Select-Object -Skip 1) }
            if ($last.Count -eq 1 -and
                $last[0].Length -gt 65536) { return '(the last output line is longer than 64 KiB; read stdout.log on the server)' }
            $last -join "`n"
        }
        return [string]$text
    } catch {
        Write-Verbose ('Attempt output could not be read: ' + $_.Exception.Message)
        return ''
    }
}
function Assert-PASDetachedSupported {
    param([hashtable]$Target)
    if ($Target.Protocol -ne 'WinRM') { throw 'Windows detached executor requires WinRM transport' }
    if (-not (Test-PASWindows)) { throw 'Windows detached executor requires the native Windows PowerShell controller' }
    if ([string](Get-PASValue $Target 'Runtime' 'WindowsPowerShell') -notin @('WindowsPowerShell', 'PowerShell')) { throw 'Windows detached executor requires a PowerShell runtime' }
}
# Task principal credentials are a separate in-memory channel; never serialize them in Inputs.
function Resolve-PASDetachedPrincipalCredential {
    param([hashtable]$Credentials, [string]$Reference = '')
    if (-not $Reference) { return $null }
    if ($Reference -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') { throw 'Invalid detached task principal credential reference' }
    if (-not $Credentials.ContainsKey($Reference) -or
        $Credentials[$Reference] -isnot [pscredential]) { throw "Detached task requires PSCredential '$Reference'" }
    $credential = $Credentials[$Reference]
    if ($credential.UserName -notmatch '^[^\\@\s]+\\[^\\@\s]+$|^[^\\@\s]+@[^\\@\s]+$' -or
        $credential.UserName -match '^\.\\|^localhost\\|^NT AUTHORITY\\') {
        throw 'Domain task identity must be an explicit DOMAIN\user or user@domain credential'
    }
    return $credential
}
function New-PASDetachedLaunchArguments {
    param(
        [string]$Directory,
        [hashtable]$ExpectedHashes,
        [ValidateSet('runner.ps1', 'recovery.ps1')][string]$Entry = 'runner.ps1'
    )
    if (-not $ExpectedHashes.Count -or -not $ExpectedHashes.ContainsKey($Entry)) { throw 'Detached launch lacks reviewed executable hashes' }
    foreach ($name in $ExpectedHashes.Keys) {
        if ($name -notmatch '^[a-z][a-z0-9.-]+$' -or
            [string]$ExpectedHashes[$name] -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid detached executable hash contract' }
    }
    # Only public paths/hashes appear in this command. Keep the attempt directory
    # visible for independent PID/command-line reconciliation. No shell is used.
    $pairs = @(foreach ($name in @($ExpectedHashes.Keys | Sort-Object)) { (ConvertTo-PASSingleQuoted $name) + '=' + (ConvertTo-PASSingleQuoted ([string]$ExpectedHashes[$name])) })
    $code = '$ErrorActionPreference=''Stop'';$directory=' + (ConvertTo-PASSingleQuoted $Directory) + ';$expected=@{' + ($pairs -join ';') + '};'
    $code += 'foreach($name in $expected.Keys){$path=Join-Path $directory $name;if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected[$name]){throw ''Detached executable hash changed; reconcile the original attempt''}};'
    $code += '$global:LASTEXITCODE=0;& (Join-Path $directory ' + (ConvertTo-PASSingleQuoted $Entry) + ')'
    if ($Entry -eq 'runner.ps1') { $code += ' -Directory $directory -ExpectedHashes $expected' }
    $code += ';exit $LASTEXITCODE'
    if ($code.Contains('"')) { throw 'Detached launch path contains an unsupported quote' }
    return ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $code + '"')
}
function Initialize-PASDetached {
    param(
        [hashtable]$Target,
        [hashtable]$Credentials,
        [string]$ScriptPath,
        [hashtable]$Parameters,
        [string]$AttemptId,
        [string]$RecoveryScript = '',
        [int]$TimeoutSeconds = 3600,
        [string]$Contract = 'Object',
        [string]$TaskPrincipalCredentialRef = ''
    )
    if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') {
        if ($RecoveryScript) { throw 'Linux RecoveryScript is not supported' }
        if ($TaskPrincipalCredentialRef) { throw 'Windows task principal cannot be used for Linux attempts' }
        return Initialize-PASLinuxDetached $Target $ScriptPath $Parameters $AttemptId $TimeoutSeconds $Contract
    }
    $taskCredential = Resolve-PASDetachedPrincipalCredential -Credentials $Credentials -Reference $TaskPrincipalCredentialRef
    Assert-PASDetachedSupported $Target
    Initialize-PASWindowsStageRoot $Target $Credentials
    $session = Get-PASConnection $Target $Credentials
    if ($taskCredential) {
        # Check the delegated identity BEFORE staging any installer secrets. Nested
        # group delegation needs separate qualification; direct membership is explicit.
        [void](Invoke-Command -Session $session -ArgumentList $taskCredential.UserName -ErrorAction Stop -ScriptBlock {
                param($user)
                $computer = Get-CimInstance Win32_ComputerSystem
                if (-not $computer.PartOfDomain -or
                    [int]$computer.DomainRole -ge 4) { throw 'Domain task identity requires a domain-joined member' }
                $sid = ([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value
                $locals = @(Get-LocalUser -ErrorAction Stop | Where-Object { [string]$_.SID -match '-500$' })
                if ($locals.Count -ne 1 -or
                    $sid.StartsWith((([string]$locals[0].SID) -replace '-[0-9]+$', '') + '-')) { throw 'Task principal must resolve to a domain identity' }
                $members = @(Get-LocalGroupMember -SID ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) -ErrorAction Stop | ForEach-Object { [string]$_.SID })
                if ($sid -notin $members) { throw 'Domain task principal must be a direct local Administrators member before secret staging' }
            })
    }
    $directory = Get-PASAttemptRoot $Target $AttemptId
    $taskName = 'PAExec-' + $AttemptId
    $reserved = Select-PASDeclaredInputs $ScriptPath @{PAExecAttemptDirectory = $directory }
    if ($reserved.ContainsKey('PAExecAttemptDirectory')) {
        if ($Parameters.ContainsKey('PAExecAttemptDirectory')) { throw 'Attempt directory is reserved execution metadata' }
        $Parameters = $Parameters.Clone()
        $Parameters.PAExecAttemptDirectory = $directory
    }
    [void](Invoke-Command -Session $session -ArgumentList $directory -ErrorAction Stop -ScriptBlock {
            param($dir)
            $ErrorActionPreference = 'Stop'
            if (Test-Path -LiteralPath $dir) { throw 'Attempt directory exists; refusing to overwrite' }
            $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Detached staging requires an elevated administrator' }
            $parent = Split-Path -Parent $dir
            $root = Split-Path -Parent $parent
            $trustedOwners = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            try { $trustedOwners += ([Security.Principal.NTAccount]::new('NT SERVICE', 'TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value }catch {}
            $ancestor = $root
            while ($ancestor) {
                if (Test-Path -LiteralPath $ancestor) {
                    $item = Get-Item -LiteralPath $ancestor -Force
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Detached stage has a reparse ancestor' }
                    $ancestorOwner = (Get-Acl -LiteralPath $ancestor).GetOwner([Security.Principal.SecurityIdentifier]).Value
                    if ($ancestorOwner -notin $trustedOwners) { throw 'Detached stage has an untrusted ancestor owner' }
                }
                $next = Split-Path -Parent $ancestor
                if ($next -eq $ancestor) { break }
                $ancestor = $next
            }
            foreach ($base in @($root, $parent)) {
                if (-not(Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -ErrorAction Stop | Out-Null }
                $acl = Get-Acl -LiteralPath $base
                $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
                $caller = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                if ($owner -notin @('S-1-5-18', 'S-1-5-32-544', $caller)) { throw 'Detached stage root has an untrusted owner' }
                # Replace the DACL: grant:r does not remove other explicit write ACEs.
                $acl = [Security.AccessControl.DirectorySecurity]::new()
                $acl.SetAccessRuleProtection($true, $false)
                $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
                foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                    $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
                    $acl.AddAccessRule($rule)
                }
                $scope = [PASeasyInstall.Native.RestorePrivilegeScopeV1]::Enable()
                try { ([IO.DirectoryInfo]::new($base)).SetAccessControl($acl) }finally { $scope.Dispose() }
            }
            $scope = [PASeasyInstall.Native.RestorePrivilegeScopeV1]::Enable()
            try { [void][IO.Directory]::CreateDirectory($dir, $acl) }finally { $scope.Dispose() }
            if ((Get-Acl -LiteralPath $dir).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'New attempt directory does not have stable administrator ownership' }
            $aclOutput = & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Cannot protect attempt directory: $aclOutput" }
            'staged'
        })
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('paeasy-stage-' + $AttemptId)
    New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
    try {
        Protect-PASDirectory $tmp
        [IO.File]::WriteAllText((Join-Path $tmp 'contract.txt'), $Contract, (Get-PASUtf8NoBom))
        [IO.File]::WriteAllText((Join-Path $tmp 'task.ps1'), (Get-PASRecipePayload $ScriptPath).Text, (Get-PASUtf8NoBom))
        $copies = @(
            @{From = (Join-Path $tmp 'task.ps1'); To = 'task.ps1' },
            @{From = (Join-Path $tmp 'contract.txt'); To = 'contract.txt' },
            @{From = (Join-Path $script:PASEngineRoot 'Assets/TaskHost.ps1'); To = 'host.ps1' },
            @{From = (Join-Path $script:PASEngineRoot 'Assets/WindowsDetachedRunner.ps1'); To = 'runner.ps1' }
            @{From = (Join-Path $script:PASRoot 'Recipes/WindowsComponent/Ownership.ps1'); To = 'ownership.ps1' }
        )
        if ($RecoveryScript) {
            [IO.File]::WriteAllText((Join-Path $tmp 'recovery.ps1'), (Get-PASRecipePayload $RecoveryScript).Text, (Get-PASUtf8NoBom))
            $copies += @{From = (Join-Path $tmp 'recovery.ps1'); To = 'recovery.ps1' }
        }
        $expectedHashes = @{}
        foreach ($c in $copies) {
            $expectedHashes[$c.To] = (Get-FileHash -LiteralPath $c.From -Algorithm SHA256).Hash
            Copy-Item -ToSession $session -LiteralPath $c.From -Destination ($directory + '\' + $c.To) -ErrorAction Stop
        }
        # SecureString traverses PSRP's encrypted credential channel. Serialize only
        # in memory, then persist machine-bound ciphertext on the protected target.
        $secureInputs = ConvertTo-SecureString ($Parameters | ConvertTo-Json -Depth 30 -Compress) -AsPlainText -Force
        try {
            [void](Invoke-Command -Session $session -ArgumentList $directory, $secureInputs -ErrorAction Stop -ScriptBlock {
                    param($dir, [Security.SecureString]$payload)
                    $ErrorActionPreference = 'Stop'
                    Add-Type -AssemblyName System.Security
                    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($payload)
                    $bytes = $null
                    try {
                        $bytes = [Text.Encoding]::UTF8.GetBytes([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr))
                        $entropy = [Text.Encoding]::UTF8.GetBytes((Split-Path $dir -Leaf))
                        $cipher = [Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
                        $file = [IO.File]::Open((Join-Path $dir 'inputs.dpapi'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        try { $file.Write($cipher, 0, $cipher.Length) }finally { $file.Dispose() }
                    } finally {
                        if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
                    }
                })
        } finally {
            $secureInputs.Dispose()
            $secureInputs = $null
        }
        # status.json is written last: its presence means the attempt is completely staged.
        $stagedBootUtc = [string](Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') })
        [IO.File]::WriteAllText((Join-Path $tmp 'status.json'), (@{
                    schemaVersion = 2
                    state = 'Dispatched'
                    attemptId = $AttemptId
                    stagedBootUtc = $stagedBootUtc
                } | ConvertTo-Json -Compress), (Get-PASUtf8NoBom))
        Copy-Item -ToSession $session -LiteralPath (Join-Path $tmp 'status.json') -Destination ($directory + '\status.json') -ErrorAction Stop
        [void](Invoke-Command -Session $session -ArgumentList $directory -ErrorAction Stop -ScriptBlock {
                param($dir)
                $caller = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $files = @(Get-ChildItem -LiteralPath $dir -Force)
                foreach ($file in $files) {
                    if ($file.PSIsContainer -or
                        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected attempt staging entry' }
                    if ((Get-Acl -LiteralPath $file.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @($caller, 'S-1-5-18', 'S-1-5-32-544')) { throw 'Unexpected attempt staging file owner' }
                }
                foreach ($file in $files) {
                    $ownerAcl = [Security.AccessControl.FileSecurity]::new()
                    $ownerAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
                    $scope = [PASeasyInstall.Native.RestorePrivilegeScopeV1]::Enable()
                    try { $file.SetAccessControl($ownerAcl) }finally { $scope.Dispose() }
                }
            })
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $launchArguments = New-PASDetachedLaunchArguments -Directory $directory -ExpectedHashes $expectedHashes
    $recoveryArguments = if ($RecoveryScript) { New-PASDetachedLaunchArguments -Directory $directory -ExpectedHashes $expectedHashes -Entry 'recovery.ps1' }else { '' }
    try {
        [void](Invoke-Command -Session $session -ArgumentList $directory, $taskName, $TimeoutSeconds, ([bool]$RecoveryScript), $taskCredential, $expectedHashes, $launchArguments, $recoveryArguments -ErrorAction Stop -ScriptBlock {
                param($dir, $name, $timeout, $hasRecovery, $runCredential, $expectedHashes, $launchArguments, $recoveryArguments)
                $ErrorActionPreference = 'Stop'
                $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                foreach ($file in $expectedHashes.Keys) { if ((Get-FileHash -LiteralPath (Join-Path $dir $file) -Algorithm SHA256).Hash -ine $expectedHashes[$file]) { throw 'Detached staged executable differs from controller source' } }
                $action = New-ScheduledTaskAction -Execute $exe -Argument $launchArguments -WorkingDirectory $dir
                $systemPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
                $principalSid = 'S-1-5-18'
                $principalUser = 'SYSTEM'
                if ($runCredential) {
                    $computer = Get-CimInstance Win32_ComputerSystem
                    if (-not $computer.PartOfDomain -or
                        [int]$computer.DomainRole -ge 4) { throw 'A domain task principal requires a domain-joined member target' }
                    $principalSid = ([Security.Principal.NTAccount]::new($runCredential.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
                    $localAdmins = @(Get-LocalUser -ErrorAction Stop | Where-Object { [string]$_.SID -match '-500$' })
                    if ($localAdmins.Count -ne 1) { throw 'Cannot identify the target local account SID prefix' }
                    $localPrefix = ([string]$localAdmins[0].SID) -replace '-[0-9]+$', ''
                    if ($principalSid -notmatch '^S-1-5-21-' -or
                        $principalSid.StartsWith($localPrefix + '-')) { throw 'Detached domain task principal resolves to a local or unsupported identity' }
                    $principalUser = $runCredential.UserName
                    $aclOutput = & icacls.exe $dir /grant:r "*${principalSid}:(OI)(CI)M" 2>&1
                    if ($LASTEXITCODE -ne 0) { throw 'Cannot grant the selected task identity access to its protected attempt' }
                }
                # Identity metadata contains no password and pins the principal for the entire attempt.
                $identity = @{schemaVersion = 1; sid = $principalSid; user = $principalUser; requireAdministrator = [bool]$runCredential }
                [IO.File]::WriteAllText((Join-Path $dir 'principal.json'), ($identity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
                $ownerAcl = [Security.AccessControl.FileSecurity]::new()
                $ownerAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
                $scope = [PASeasyInstall.Native.RestorePrivilegeScopeV1]::Enable()
                try { ([IO.FileInfo]::new((Join-Path $dir 'principal.json'))).SetAccessControl($ownerAcl) }finally { $scope.Dispose() }
                $publication = Get-Content -LiteralPath (Join-Path $dir 'status.json') -Raw | ConvertFrom-Json
                if ([string]$publication.stagedBootUtc -cne (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')) { throw 'Target rebooted during staging; reconcile the original attempt' }
                # Persist the complete publication before Task Scheduler can launch a body.
                foreach ($file in @(Get-ChildItem -LiteralPath $dir -File)) {
                    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
                    try { $stream.Flush($true) }finally { $stream.Dispose() }
                }
                $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromSeconds($timeout)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
                if ($runCredential) {
                    # The password crosses only the authenticated WSMan channel as PSCredential and is
                    # supplied to Task Scheduler in memory. Windows stores the task logon credential.
                    $plain = $null
                    try {
                        $plain = $runCredential.GetNetworkCredential().Password
                        Register-ScheduledTask -TaskName $name -TaskPath '\PAExec\' -Action $action -User $principalUser -Password $plain -RunLevel Highest -Settings $settings -Force |
                            Out-Null
                    } finally {
                        $plain = $null
                        $runCredential = $null
                    }
                } else {
                    Register-ScheduledTask -TaskName $name -TaskPath '\PAExec\' -Action $action -Principal $systemPrincipal -Settings $settings -Force |
                        Out-Null
                }
                if ($hasRecovery) {
                    $ra = New-ScheduledTaskAction -Execute $exe -Argument $recoveryArguments -WorkingDirectory $dir
                    $rt = New-ScheduledTaskTrigger -AtStartup
                    $rs = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(30)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                    Register-ScheduledTask -TaskName ($name + '-Recovery') -TaskPath '\PAExec\' -Action $ra -Trigger $rt -Principal $systemPrincipal -Settings $rs -Force |
                        Out-Null
                }
                Start-ScheduledTask -TaskName $name -TaskPath '\PAExec\'
                'started'
            })
    } catch {
        $registrationFailure = $_
        # Delete staged secret inputs only when there is proof no task/runner can consume them.
        # On transport loss or an existing task, preserve the attempt for normal reconciliation.
        try {
            [void](Invoke-Command -Session $session -ArgumentList $directory, $taskName -ErrorAction Stop -ScriptBlock {
                    param($dir, $name)
                    $task = Get-ScheduledTask -TaskName $name -TaskPath '\PAExec\' -ErrorAction SilentlyContinue
                    if (-not $task -and -not(Test-Path -LiteralPath (Join-Path $dir 'claimed'))) {
                        Remove-Item -LiteralPath (Join-Path $dir 'inputs.json') -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath (Join-Path $dir 'inputs.dpapi') -Force -ErrorAction SilentlyContinue
                    }
                })
        } catch { Write-Verbose 'Unconfirmed registration cleanup; reconcile the protected remote attempt' }
        throw $registrationFailure
    }
    return [pscustomobject]@{ AttemptId = $AttemptId; Directory = $directory; ScheduledTask = $taskName }
}
function Get-PASDetachedStatus {
    param([hashtable]$Target, [hashtable]$Credentials, [string]$AttemptId)
    if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') { return Get-PASLinuxDetachedStatus $Target $AttemptId }
    $dir = Get-PASAttemptRoot $Target $AttemptId
    $task = 'PAExec-' + $AttemptId
    $result = Invoke-Command -Session (Get-PASConnection $Target $Credentials) -ArgumentList $dir, $task -ErrorAction Stop -ScriptBlock {
        param($dir, $task)
        $status = Join-Path $dir 'status.json'
        $st = Get-ScheduledTask -TaskName $task -TaskPath '\PAExec\' -ErrorAction SilentlyContinue
        $taskState = ''
        if ($st) { $taskState = [string]$st.State }
        $identityPath = Join-Path $dir 'principal.json'
        if ($st -and
            -not(Test-Path -LiteralPath $identityPath)) {
            return (@{
                    state = 'Interrupted'
                    taskState = $taskState
                    reason = 'scheduled task principal metadata missing'
                } | ConvertTo-Json -Compress)
        }
        if ($st -and (Test-Path -LiteralPath $identityPath)) {
            try { $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json -ErrorAction Stop }
            catch {
                return (@{
                        state = 'Interrupted'
                        taskState = $taskState
                        reason = 'scheduled task principal metadata is corrupt'
                    } | ConvertTo-Json -Compress)
            }
            try {
                if ($identity.schemaVersion -ne 1 -or -not $identity.sid) { throw 'Unsupported principal metadata' }
                # The task definition holds the SID of its account. The task object only gives the bare name, and a
                # name such as Administrator would be resolved to the local account instead of the domain account.
                $registered = [string]([xml](Export-ScheduledTask -TaskName $task -TaskPath '\PAExec\' -ErrorAction Stop)).Task.Principals.Principal.UserId
                if ($registered -notmatch '^S-1-') { $registered = ([Security.Principal.NTAccount]::new($registered)).Translate([Security.Principal.SecurityIdentifier]).Value }
                if ($registered -ne [string]$identity.sid) {
                    return (@{
                            state = 'Interrupted'
                            taskState = $taskState
                            reason = 'scheduled task principal changed'
                        } | ConvertTo-Json -Compress)
                }
            } catch {
                return (@{
                        state = 'Interrupted'
                        taskState = $taskState
                        reason = 'scheduled task principal cannot be verified'
                    } | ConvertTo-Json -Compress)
            }
        }
        if (-not(Test-Path -LiteralPath $status)) {
            # Missing files after power loss or rollback cannot prove no prior side effects.
            if (Test-Path -LiteralPath $dir) {
                return (@{
                        state = 'Interrupted'
                        taskState = $taskState
                        reason = 'staging evidence incomplete; prior execution cannot be excluded'
                    } | ConvertTo-Json -Compress)
            }
            return (@{state = 'Missing'; taskState = $taskState } | ConvertTo-Json -Compress)
        }
        try { $data = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch {
            return (@{
                    state = 'Interrupted'
                    taskState = $taskState
                    reason = 'durable attempt status metadata is corrupt'
                } | ConvertTo-Json -Compress)
        }
        if ($data.state -in @('Running', 'Succeeded', 'Failed')) {
            $stamp = [datetime]::MinValue
            if ($data.schemaVersion -ne 2 -or
                [string]$data.attemptId -cne (Split-Path $dir -Leaf) -or
                [string]$data.pid -notmatch '^[1-9][0-9]{0,9}$' -or
                -not [datetime]::TryParse([string]$data.bootUtc, [ref]$stamp)) {
                return (@{
                        state = 'Interrupted'
                        taskState = $taskState
                        reason = 'durable worker identity is missing or inconsistent'
                    } | ConvertTo-Json -Compress)
            }
        }
        if ($data.state -eq 'Dispatched') {
            $staged = $data.PSObject.Properties['stagedBootUtc']
            if ($data.schemaVersion -ne 2 -or
                [string]$data.attemptId -cne (Split-Path $dir -Leaf) -or
                -not $staged -or
                [string]$staged.Value -cne (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')) {
                return (@{
                        state = 'Interrupted'
                        taskState = $taskState
                        reason = 'staged boot changed or is unrecorded; prior execution cannot be excluded'
                    } | ConvertTo-Json -Compress)
            }
            if ((Test-Path -LiteralPath (Join-Path $dir 'claimed')) -and $taskState -ne 'Running') {
                return (@{
                        state = 'Interrupted'
                        taskState = $taskState
                        reason = 'attempt claimed before terminal evidence'
                    } | ConvertTo-Json -Compress)
            }
        }
        if ($data.state -eq 'Dispatched' -and -not $st) {
            # A disconnected initializer may still register this attempt later.
            # Never create another attempt while that callback is unconfirmed.
            $data | Add-Member -NotePropertyName state -NotePropertyValue 'Interrupted' -Force
            $data |
                Add-Member -NotePropertyName reason -NotePropertyValue 'scheduled task publication is unresolved; initializer exit unconfirmed' -Force
        }
        if ($data.state -eq 'Running') {
            # Reconcile a stale Running marker: killed by timeout, crash or reboot.
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            $alive = $false
            if ($data.bootUtc -eq $boot) {
                $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$data.pid) -ErrorAction SilentlyContinue
                if ($p -and $p.CommandLine -like ('*' + (Split-Path $dir -Leaf) + '*')) { $alive = $true }
            }
            if (-not $alive) {
                # The worker writes its final status and then ends. When it ended between the first read of the
                # status file and the look at the process, the file holds the final status now: read it again
                # before calling the attempt interrupted (lab 2026-11-24: a PSM step that had succeeded was
                # reported Unknown this way).
                $final = $null
                try { $final = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $final = $null }
                if ($final -and
                    [string]$final.state -in @('Succeeded', 'Failed') -and
                    $final.schemaVersion -eq 2 -and
                    [string]$final.attemptId -ceq (Split-Path $dir -Leaf) -and
                    [string]$final.pid -eq [string]$data.pid -and
                    [string]$final.bootUtc -eq [string]$data.bootUtc) {
                    $data = $final
                } else {
                    $data | Add-Member -NotePropertyName state -NotePropertyValue 'Interrupted' -Force
                }
            }
        }
        $data | Add-Member -NotePropertyName taskState -NotePropertyValue $taskState -Force
        $workerActive = $false
        if ($data.pid -and $data.bootUtc -eq (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')) {
            $worker = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$data.pid) -ErrorAction Stop
            $workerActive = ($null -ne $worker -and [string]$worker.CommandLine -like ('*' + (Split-Path $dir -Leaf) + '*'))
        }
        $data | Add-Member -NotePropertyName workerActive -NotePropertyValue ([bool]$workerActive) -Force
        $progressPath = Join-Path $dir 'progress.json'
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            try {
                $progressFile = Get-Item -LiteralPath $progressPath -ErrorAction Stop
                if ($progressFile.Length -gt 0 -and $progressFile.Length -le 4096) {
                    $progress = Get-Content -LiteralPath $progressPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $allowed = @('WaitingForCycle','WaitingForMetadata','WaitingForTestSafe','WaitingForLog','Complete','TimedOut')
                    if ($progress.schemaVersion -eq 1 -and $progress.kind -eq 'DRReplication' -and
                        [string]$progress.phase -cin $allowed -and
                        [int]$progress.elapsedSeconds -ge 0 -and [int]$progress.maxSeconds -gt 0) {
                        $data | Add-Member -NotePropertyName progress -NotePropertyValue @{
                            kind = 'DRReplication'
                            phase = [string]$progress.phase
                            elapsedSeconds = [int]$progress.elapsedSeconds
                            maxSeconds = [int]$progress.maxSeconds
                        } -Force
                    }
                }
            } catch { } # Sideband is advisory; terminal state remains authoritative.
        }
        return ($data | ConvertTo-Json -Compress -Depth 10)
    }
    return ConvertTo-PASHashtable (ConvertFrom-Json -InputObject ([string]$result))
}
function Wait-PASDetachedSessionQuiescence {
    param([hashtable]$Target, [hashtable]$Credentials, [string]$AttemptId, [int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $remote = Get-PASDetachedStatus $Target $Credentials $AttemptId
        if ($remote.state -ne 'Succeeded') { throw 'PAExecUnknown: authenticated attempt no longer has its successful terminal record' }
        $active = Get-PASValue $remote 'workerActive' $null
        if ($active -is [bool] -and -not $active) { return }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'PAExecUnknown: the worker that used the Vault session has not exited yet; inspect the attempt on the target before resuming' }
        Start-Sleep -Milliseconds 500
    }while ($true)
}
function Wait-PASDetached {
    param(
        [hashtable]$Target,
        [hashtable]$Credentials,
        [string]$AttemptId,
        [int]$TimeoutSeconds = 3600,
        [hashtable]$Context = $null,
        [string]$TaskId = '',
        [switch]$AllowStart
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds + 120)
    $lastError = ''
    $lastState = ''
    $lastProgressPhase = ''
    $lastProgressEventUtc = [DateTime]::MinValue
    $failures = 0
    $kicked = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $status = Get-PASDetachedStatus $Target $Credentials $AttemptId
            $failures = 0
            if ($status.state -ne $lastState -and
                $Context) {
                Add-PASEvent $Context 'DetachedStatus' $TaskId ("remote attempt $AttemptId is $($status.state)")
                $lastState = $status.state
            }
            $progress = Get-PASValue $status 'progress' $null
            if ($Context -and $progress -and [string](Get-PASValue $progress 'kind' '') -eq 'DRReplication') {
                $phase = [string](Get-PASValue $progress 'phase' '')
                if ($phase -ne $lastProgressPhase -or
                    [DateTime]::UtcNow - $lastProgressEventUtc -ge [timespan]::FromSeconds(60)) {
                    $lastProgressPhase = $phase
                    $lastProgressEventUtc = [DateTime]::UtcNow
                    $elapsed = [int](Get-PASValue $progress 'elapsedSeconds' 0)
                    $limit = [int](Get-PASValue $progress 'maxSeconds' 0)
                    Add-PASEvent $Context 'DetachedProgress' $TaskId ("DR replication: $phase ($elapsed / $limit seconds)")
                }
            }
            if ($status.state -in @('Succeeded', 'Failed', 'Interrupted', 'NotStarted', 'Missing')) { return $status }
            if ($AllowStart -and $status.state -eq 'Dispatched' -and (Get-PASValue $status 'taskState' '') -eq 'Ready' -and -not $kicked) {
                # Registered but never launched (controller died before Start-ScheduledTask). The runner
                # executes only from the Dispatched state, so starting the SAME attempt cannot duplicate it.
                $kicked = $true
                $name = 'PAExec-' + $AttemptId
                if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') { Start-PASLinuxDetached $Target $AttemptId }else {
                    [void](Invoke-Command -Session (Get-PASConnection $Target $Credentials) -ArgumentList $name -ErrorAction Stop -ScriptBlock { param($n) Start-ScheduledTask -TaskName $n -TaskPath '\PAExec\' })
                }
                if ($Context) { Add-PASEvent $Context 'DetachedStarted' $TaskId "started staged attempt $AttemptId" }
            }
        } catch {
            $failures++
            $lastError = $_.Exception.Message
            if ($Context -and
                ($failures -eq 1 -or
                $failures % 6 -eq 0)) { Add-PASEvent $Context 'DetachedPollError' $TaskId ("status poll failed ($failures): " + (Limit-PASText $lastError 300)) 'Warning' }
            Clear-PASConnections
        }
        Start-Sleep -Seconds 10
    }
    throw "PAExecUnknown: Detached task status unconfirmed before timeout: $lastError"
}
function Finish-PASDetached {
    param([hashtable]$Target, [hashtable]$Credentials, [string]$AttemptId)
    if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') {
        Finish-PASLinuxDetached $Target $AttemptId
        return
    }
    $taskName = 'PAExec-' + $AttemptId
    # Keep status.json/stdout.log as remote attempt evidence. Only the main scheduled task is removed.
    [void](Invoke-Command -Session (Get-PASConnection $Target $Credentials) -ArgumentList $taskName -ErrorAction Stop -ScriptBlock {
            param($name)
            Unregister-ScheduledTask -TaskName $name -TaskPath '\PAExec\' -Confirm:$false -ErrorAction SilentlyContinue
        })
}
function Get-PASBootIdentifier {
    param([hashtable]$Target, [hashtable]$Credentials)
    if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') {
        $boot = ([string](Invoke-PASLinuxControl $Target 'cat /proc/sys/kernel/random/boot_id')).Trim()
        if ($boot -notmatch '^[a-f0-9-]{36}$') { throw 'Cannot read Linux boot identifier' }
        return $boot
    }
    $r = Invoke-PASAdapterCommand $Target $Credentials '[pscustomobject]@{Message=''boot'';Boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString(''o'')}' 'Object' 120
    $boot = [string](Get-PASValue $r.Terminal 'Boot' '')
    if ([string]::IsNullOrWhiteSpace($boot)) { throw 'Cannot read boot identifier' }
    return $boot
}
function Invoke-PASReboot {
    # -BootBefore: identifier recorded before the reboot. -AlreadyRequested: resume mode (wait only, never re-issue).
    param(
        [hashtable]$Target,
        [hashtable]$Credentials,
        [int]$TimeoutSeconds = 900,
        [hashtable]$Context = $null,
        [string]$TaskId = '',
        [string]$BootBefore = '',
        [switch]$AlreadyRequested
    )
    if ($Target.Protocol -eq 'SSH' -and $Target.Runtime -eq 'Bash') {
        $boot = $BootBefore
        if (-not $boot) {
            if ($AlreadyRequested) { throw 'Resuming Linux reboot requires recorded boot identifier' }
            $boot = Get-PASBootIdentifier $Target $Credentials
        }
        if (-not $AlreadyRequested) {
            if ($Context) { Add-PASEvent $Context 'RebootRequested' $TaskId "Linux boot before reboot: $boot" }
            $unit = 'paeasy-reboot-' + [guid]::NewGuid().ToString('N')
            # A short root-owned systemd timer survives the SSH observer exiting.
            try { [void](Invoke-PASLinuxControl $Target ('systemd-run --quiet --unit=' + $unit + ' --on-active=5s /usr/bin/systemctl reboot')) }catch { Write-Verbose 'Linux reboot dispatch uncertain; observe boot identity without repeating' }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 10
            try {
                $now = Get-PASBootIdentifier $Target $Credentials
                if ($now -ne $boot) {
                    if ($Context) { Add-PASEvent $Context 'RebootConfirmed' $TaskId "Linux boot after reboot: $now" }
                    return $now
                }
            } catch { Write-Verbose 'Waiting for Linux reboot transport' }
        }
        throw 'PAExecUnknown: Linux reboot not confirmed by changed boot identifier'
    }
    if ($Target.Protocol -ne 'WinRM' -and
        -not ($Target.Protocol -eq 'SSH' -and
            $Target.Runtime -ne 'Bash')) { throw 'Reboot requires a Windows PowerShell target (WinRM or SSH)' }
    $boot = $BootBefore
    if (-not $boot) {
        if ($AlreadyRequested) { throw 'Resuming a reboot requires the recorded boot identifier' }
        $boot = Get-PASBootIdentifier $Target $Credentials
    }
    if (-not $AlreadyRequested) {
        if ($Context) { Add-PASEvent $Context 'RebootRequested' $TaskId "boot before reboot: $boot" }
        try { [void](Invoke-PASAdapterCommand $Target $Credentials '& shutdown.exe /r /t 5 /d p:4:1 /c "PAExec workflow reboot"; if($LASTEXITCODE -ne 0){throw "shutdown.exe $LASTEXITCODE"}; [pscustomobject]@{Message=''scheduled''}' 'Object' 60) }
        catch {
            if ($_.Exception.Message -notmatch '^PAExecUnknown:') { throw }
            Clear-PASConnections
        }
    }
    Clear-PASConnections
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 10
        try {
            $now = Get-PASBootIdentifier $Target $Credentials
            if ($now -and
                $now -ne $boot) {
                if ($Context) { Add-PASEvent $Context 'RebootConfirmed' $TaskId "boot after reboot: $now" }
                return $now
            }
        } catch { Clear-PASConnections }
    }
    throw 'PAExecUnknown: Reboot not confirmed by changed boot identifier'
}
function Clear-PASRecoveryTasks {
    param($Plan, [hashtable]$Credentials, [hashtable]$Steps)
    if ($Plan.Target.Protocol -ne 'WinRM') { return }
    foreach ($step in $Plan.Steps) {
        if ((Get-PASValue $step 'Mode' 'Direct') -ne 'Detached' -or -not $step.Contains('RecoveryScript')) { continue }
        $attempt = Get-PASValue $Steps ([string]$step.Id)
        if (-not $attempt) { continue }
        foreach ($id in @(@(Get-PASValue $attempt 'attemptId' '') + @(Get-PASValue $attempt 'previousAttempts' @()))) {
            if (-not $id) { continue }
            $name = 'PAExec-' + [string]$id + '-Recovery'
            [void](Invoke-PASAdapterCommand $Plan.Target $Credentials ("Unregister-ScheduledTask -TaskName '$name' -TaskPath '\PAExec\' -Confirm:`$false -ErrorAction SilentlyContinue"))
        }
    }
}
