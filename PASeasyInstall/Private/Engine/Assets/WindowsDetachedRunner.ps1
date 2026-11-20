# Executes as LOCAL SYSTEM from a Scheduled Task, independently of the controller connection.
param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][hashtable]$ExpectedHashes)
$ErrorActionPreference = 'Stop'
function Assert-ExecutableHash([string]$Name) {
    if (-not $ExpectedHashes.ContainsKey($Name) -or
        [string]$ExpectedHashes[$Name] -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Detached executable hash contract is missing' }
    if ((Get-FileHash -LiteralPath (Join-Path $Directory $Name) -Algorithm SHA256).Hash -ine $ExpectedHashes[$Name]) { throw 'Detached executable hash changed; reconcile the original attempt' }
}
foreach ($executable in $ExpectedHashes.Keys) { Assert-ExecutableHash ([string]$executable) }
. (Join-Path $Directory 'ownership.ps1')
function Save-Status([hashtable]$Value) {
    $dest = Join-Path $Directory 'status.json'
    $tmp = "$dest.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 20 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $ownerAcl = [Security.AccessControl.FileSecurity]::new()
    $ownerAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Invoke-PASeasyWithRestorePrivilege { ([IO.FileInfo]::new($tmp)).SetAccessControl($ownerAcl) }
    $stream = [IO.File]::Open($tmp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $stream.Flush($true) }finally { $stream.Dispose() }
    if ([IO.File]::Exists($dest)) { [IO.File]::Replace($tmp, $dest, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $dest) }
}
$attemptId = Split-Path $Directory -Leaf
$started = [DateTime]::UtcNow.ToString('o')
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$statusFile = Join-Path $Directory 'status.json'
# Atomically claim the attempt. A second launch (task retry, reconciler start, manual run) must never
# execute the body twice: CreateNew fails if any earlier launch already claimed it.
try {
    $claim = [IO.File]::Open((Join-Path $Directory 'claimed'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $claim.Flush($true)
    $claim.Dispose()
    $ownerAcl = [Security.AccessControl.FileSecurity]::new()
    $ownerAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Invoke-PASeasyWithRestorePrivilege { ([IO.FileInfo]::new((Join-Path $Directory 'claimed'))).SetAccessControl($ownerAcl) }
} catch { exit 3 }
$previous = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
if ($previous.state -ne 'Dispatched') { exit 3 }
if ($previous.schemaVersion -ne 2 -or
    [string]$previous.attemptId -cne $attemptId -or
    -not $previous.PSObject.Properties['stagedBootUtc'] -or
    [string]$previous.stagedBootUtc -cne $boot) { exit 4 }
$common = @{ schemaVersion = 2; attemptId = $attemptId; startedUtc = $started; pid = $PID; bootUtc = $boot; host = $env:COMPUTERNAME }
$running = $common.Clone()
$running.state = 'Running'
Save-Status $running
$final = $common.Clone()
$final.state = 'Failed'
$final.endedUtc = ''
$final.message = ''
$final.changed = $null
$final.exitCode = 0
$workerMarkersSet = $false
try {
    $identityPath = Join-Path $Directory 'principal.json'
    if (-not(Test-Path -LiteralPath $identityPath)) { throw 'Detached runner principal metadata is missing' }
    $expected = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    if ($expected.schemaVersion -ne 1) { throw 'Detached runner principal metadata schema is unsupported' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -ne [string]$expected.sid) { throw 'Detached runner identity differs from its recorded principal' }
    if ($expected.requireAdministrator) {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Selected domain task identity is not an elevated local administrator' }
    }
    $hostScript = Join-Path $Directory 'host.ps1'
    $previousAttemptMarker = [Environment]::GetEnvironmentVariable('PAEASY_DETACHED_ATTEMPT', 'Process')
    $previousProcessMarker = [Environment]::GetEnvironmentVariable('PAEASY_DETACHED_PROCESS_ID', 'Process')
    [Environment]::SetEnvironmentVariable('PAEASY_DETACHED_ATTEMPT', $attemptId, 'Process')
    [Environment]::SetEnvironmentVariable('PAEASY_DETACHED_PROCESS_ID', [string]$PID, 'Process')
    $workerMarkersSet = $true
    $result = & $hostScript -Directory $Directory -DeleteInputs -RequireProtectedInputs
    $output = [string]$result.Output
    [IO.File]::WriteAllText((Join-Path $Directory 'stdout.log'), $output, (New-Object System.Text.UTF8Encoding($false)))
    $ownerAcl = [Security.AccessControl.FileSecurity]::new()
    $ownerAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Invoke-PASeasyWithRestorePrivilege { ([IO.FileInfo]::new((Join-Path $Directory 'stdout.log'))).SetAccessControl($ownerAcl) }
    $final.exitCode = [int]$result.ExitCode
    if ($result.Ok) {
        $final.state = 'Succeeded'
        if ($result.Terminal) {
            $final.message = [string]$result.Terminal['Message']
            $final.changed = $result.Terminal['Changed']
            $final.data = $result.Terminal['Data']
        }
        if ($result.PSObject.Properties['Check']) { $final.check = $result.Check }
        if (-not $final.message) { $final.message = 'Detached script finished' }
    } else {
        $final.state = 'Failed'
        $final.message = [string]$result.Error
    }
} catch {
    $final.state = 'Failed'
    $final.message = [string]$_.Exception.Message
} finally {
    if ($workerMarkersSet) {
        [Environment]::SetEnvironmentVariable('PAEASY_DETACHED_ATTEMPT', $previousAttemptMarker, 'Process')
        [Environment]::SetEnvironmentVariable('PAEASY_DETACHED_PROCESS_ID', $previousProcessMarker, 'Process')
    }
    Remove-Item -LiteralPath (Join-Path $Directory 'inputs.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Directory 'inputs.dpapi') -Force -ErrorAction SilentlyContinue
    $recovery = Join-Path $Directory 'recovery.ps1'
    if (Test-Path -LiteralPath $recovery) {
        try {
            Assert-ExecutableHash 'recovery.ps1'
            $r = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $recovery 2>&1
            [IO.File]::WriteAllText((Join-Path $Directory 'recovery.log'), ((@($r) | ForEach-Object { [string]$_ }) -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
            if ($LASTEXITCODE -ne 0) { throw "recovery exit code $LASTEXITCODE" }
            $final.recovery = 'Succeeded'
        } catch {
            $final.recovery = 'Failed'
            $final.state = 'Failed'
            $final.message += '; management recovery failed: ' + [string]$_.Exception.Message
        }
    }
    $final.endedUtc = [DateTime]::UtcNow.ToString('o')
    try { Save-Status $final } catch { exit 2 }
}
if ($final.state -eq 'Succeeded') { exit 0 }else { exit 1 }
