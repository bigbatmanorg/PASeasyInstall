# Waits for a PADR replication cycle (PADR0010I) and ongoing metadata replication (PADR0099I) that are
# both NEWER than this step's start. With -Restart, PADR is restarted first to force an immediate cycle.
param(
    [Parameter(Mandatory = $true)][hashtable]$Settings,
    [switch]$Restart,
    [int]$Minutes = 30,
    [string]$RunId = '',
    [switch]$TestSafe,
    [string]$PAExecAttemptDirectory = ''
)
$SafeName = ''
if ($TestSafe) {
    if (-not $RunId) { throw 'TestSafe requires RunId' }
    $SafeName = 'PAExecRepl' + $RunId.Substring(0, [Math]::Min(12, $RunId.Length))
}
$ErrorActionPreference = 'Stop'
# PAEASY_INCLUDE_VAULT_PADR
Assert-PASeasyPadrManualStandby $Settings
$log = Join-Path $Settings.InstallRoot 'PADR\Logs\padr.log'
$svc = Get-Service -DisplayName 'CyberArk Vault Disaster Recovery' -ErrorAction Stop
$since = (Get-Date).AddSeconds(-2)
if ($Restart -or
    $svc.Status -ne 'Running') { if ($svc.Status -eq 'Running') { Restart-Service -Name $svc.Name -Force }else { Start-Service -Name $svc.Name } }
function Get-Stamp([string]$line) {
    $m = [regex]::Match($line, '^\[(\d\d/\d\d/\d{4})\s+(\d\d:\d\d:\d\d)')
    if (-not $m.Success) { return $null }
    return [datetime]::ParseExact($m.Groups[1].Value + ' ' + $m.Groups[2].Value, 'dd/MM/yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}
$deadline = (Get-Date).AddMinutes($Minutes)
$seenError = ''
$started = Get-Date
$lastPhase = ''
function Write-PASReplicationProgress([string]$Phase) {
    if (-not $PAExecAttemptDirectory) { return }
    # The runner supplies a protected attempt folder, not a caller-provided path.
    if (-not $env:PAEASY_DETACHED_ATTEMPT -or
        (Split-Path -Path $PAExecAttemptDirectory -Leaf) -cne $env:PAEASY_DETACHED_ATTEMPT) { return }
    if (-not (Test-Path -LiteralPath $PAExecAttemptDirectory -PathType Container)) { return }
    $report = @{
        schemaVersion = 1
        kind = 'DRReplication'
        phase = $Phase
        elapsedSeconds = [Math]::Max(0, [int]((Get-Date) - $started).TotalSeconds)
        maxSeconds = [int]($Minutes * 60)
    }
    $target = Join-Path $PAExecAttemptDirectory 'progress.json'
    $tmp = Join-Path $PAExecAttemptDirectory ('progress-' + $PID + '.tmp')
    try {
        [IO.File]::WriteAllText($tmp, ($report | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($tmp, $target, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $target) }
    } catch {
        # Progress is advisory; never turn successful replication into failure.
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
Write-PASReplicationProgress 'WaitingForCycle'
while ((Get-Date) -lt $deadline) {
    Assert-PASeasyPadrManualStandby $Settings
    if (Test-Path -LiteralPath $log) {
        $recent = @(Get-Content -LiteralPath $log -Tail 2000 | Where-Object {
                $s = Get-Stamp $_
                $s -and $s -ge $since
            })
        # Transient errors (e.g. PADR starting before the network is ready after a reboot) are tolerated only
        # when a complete cycle AND metadata replication follow the last error.
        $lastError = -1
        for ($i = 0; $i -lt $recent.Count; $i++) { if ($recent[$i] -match '\b(?:PADR\d+[ES]|ITADB\d+[ES]|PAREP\d+[ES])\b') { $lastError = $i } }
        if ($lastError -ge 0) { $seenError = $recent[$lastError].Trim() }
        $after = @()
        if ($lastError + 1 -lt $recent.Count) { $after = @($recent[($lastError + 1)..($recent.Count - 1)]) }
        $cycle = @($after | Where-Object { $_ -match 'PADR0010I' })
        $meta = @($after | Where-Object { $_ -match 'PADR0099I' })
        $safeOk = $true
        if ($SafeName) {
            $idx = -1
            for ($i = 0; $i -lt $recent.Count; $i++) {
                if ($recent[$i] -match 'PAREP0213I' -and
                    $recent[$i].Contains('[' + $SafeName + '(') -and
                    $recent[$i] -match 'Replicated \[[1-9]') { $idx = $i }
            }
            $safeOk = ($idx -ge 0 -and @($recent[($idx + 1)..($recent.Count - 1)] | Where-Object { $_ -match 'PADR0010I' }).Count -gt 0)
        }
        $phase = if (-not $cycle.Count) { 'WaitingForCycle' }
            elseif (-not $meta.Count) { 'WaitingForMetadata' }
            elseif (-not $safeOk) { 'WaitingForTestSafe' }
            else { 'Complete' }
        Write-PASReplicationProgress $phase
        if ($cycle.Count -and $meta.Count -and $safeOk) {
            $msg = "replication cycle and metadata replication observed after $($since.ToString('s'))"
            if ($seenError) { $msg += " (recovered from: $seenError)" }
            if ($SafeName) { $msg += "; Safe $SafeName replicated" }
            [pscustomobject]@{
                Changed = [bool]$Restart
                Message = $msg
                Data = @{
                    Cycle = $cycle[-1].Trim()
                    Metadata = $meta[-1].Trim()
                }
            }
            return
        }
    }
    if (-not (Test-Path -LiteralPath $log)) { Write-PASReplicationProgress 'WaitingForLog' }
    Start-Sleep -Seconds 15
}
Write-PASReplicationProgress 'TimedOut'
throw "No fresh PADR cycle$(if($SafeName){" including Safe $SafeName"}) within $Minutes minutes$(if($seenError){"; last error: $seenError"})"
