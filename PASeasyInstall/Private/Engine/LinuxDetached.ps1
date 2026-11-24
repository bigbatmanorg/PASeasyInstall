# Durable Bash attempts require root SSH and systemd. No runtime bridge or background SSH shell.
function Get-PASLinuxAttemptRoot {
    param([string]$AttemptId)
    if ($AttemptId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid Linux attempt ID' }
    return ('/opt/paeasyinstall/attempts/' + $AttemptId)
}
function Invoke-PASLinuxControl {
    param([hashtable]$Target, [string]$Command)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command.Replace("`r`n", "`n")))
    $r = Invoke-PASRawSSH $Target ('printf %s ' + $encoded + ' | base64 -d | bash')
    if ($r.ExitCode -ne 0) { throw "PAExecUnknown: Linux attempt control failed ($($r.ExitCode)); inspect target attempt" }
    return $r.Output
}
function Get-PASLinuxDirectoryGuard {
    param([string[]]$Paths, [switch]$ExistingOnly)
    if (-not $Paths.Count) { throw 'Linux directory guard needs explicit paths' }
    foreach ($path in $Paths) {
        if ($path -notmatch '^/[A-Za-z0-9_./-]*$' -or
            $path -match '/\.\.?(/|$)|//') { throw 'Unsafe Linux directory guard path' }
    }
    $code = 'set -eu; for p in ' + ($Paths -join ' ') + '; do '
    if ($ExistingOnly) { $code += 'if [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi; ' }
    return ($code + 'test -d "$p"; test ! -L "$p"; test "$(stat -c %u -- "$p")" = 0; mode=$(stat -c %a -- "$p"); test "$((8#$mode & 022))" = 0; done; ')
}
function Get-PASLinuxInfrastructureGuard {
    # These are OS-owned ancestors, never application directories to adopt/chmod.
    Get-PASLinuxDirectoryGuard @('/', '/opt', '/run', '/run/systemd', '/run/systemd/system', '/etc', '/etc/systemd', '/etc/systemd/system')
}
function Get-PASLinuxAttemptGuard {
    param([string]$AttemptId, [switch]$ExistingOnly, [switch]$Secrets)
    $dir = Get-PASLinuxAttemptRoot $AttemptId
    $paths = @('/opt/paeasyinstall', '/opt/paeasyinstall/attempts', $dir)
    if ($Secrets) { $paths += @('/run/paeasyinstall', '/run/paeasyinstall/attempts', ('/run/paeasyinstall/attempts/' + $AttemptId)) }
    (Get-PASLinuxInfrastructureGuard) + (Get-PASLinuxDirectoryGuard $paths -ExistingOnly:$ExistingOnly)
}
function Start-PASLinuxDetached {
    param([hashtable]$Target, [string]$AttemptId)
    $dir = Get-PASLinuxAttemptRoot $AttemptId
    # Resume may observe a published record before the original caller completed
    # its flush. Every first/same-attempt start requires the barriers again.
    [void](Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId) + (Get-PASLinuxDirectoryGuard @('/run/paeasyinstall', '/run/paeasyinstall/attempts', ('/run/paeasyinstall/attempts/' + $AttemptId)) -ExistingOnly) + 'set -eu; command -v sync >/dev/null; sync -f ' + $dir + '; sync -f /etc/systemd/system; systemctl daemon-reload; systemctl start --no-block paeasy-' + $AttemptId + '.service'))
}
function Initialize-PASLinuxDetached {
    param(
        [hashtable]$Target,
        [string]$ScriptPath,
        [hashtable]$Parameters,
        [string]$AttemptId,
        [int]$TimeoutSeconds,
        [string]$Contract
    )
    if ([string](Get-PASValue $Target 'User' '') -ne 'root') { throw 'Durable Linux attempts currently require explicitly configured root SSH identity' }
    if ($Contract -notin @('Object', 'ExitCode')) { throw 'Unsupported Linux attempt contract' }
    # Windows OpenSSH needs an independent console for redirected stdin. Probe
    # before staging any secret; never fall back to a plaintext local envelope.
    $probeTarget = @{}
    foreach ($key in $Target.Keys) { $probeTarget[$key] = $Target[$key] }
    $probeTarget.CommandTimeoutSeconds = 20
    # Tried up to three times: right after an installer changed sshd or the SELinux policy (PSMP on RHEL-family),
    # the first sign-in can take longer than the time limit.
    $probe = $null
    foreach ($try in 1..3) {
        try {
            $probe = Invoke-PASRawSSH $probeTarget 'received=$(head -c 9); test "$received" = PAEASY_OK' ([Text.Encoding]::UTF8.GetBytes('PAEASY_OK'))
            if ($probe.ExitCode -eq 0) {
                break
            }
        } catch {
            $probe = $null
        }
        Start-Sleep -Seconds 5
    }
    if (-not $probe) { throw 'Linux secret streaming unavailable; start the controller in its own Windows console. No secret or target attempt was staged.' }
    if ($probe.ExitCode -ne 0) { throw 'Linux secret streaming unavailable; start the controller in its own Windows console' }
    $dir = Get-PASLinuxAttemptRoot $AttemptId
    $secretDir = '/run/paeasyinstall/attempts/' + $AttemptId
    $prepare = 'set -eu; test "$(id -u)" = 0; command -v systemctl >/dev/null; command -v jq >/dev/null; command -v sync >/dev/null; sync -f /opt; test -d /run/systemd/system; umask 077; for p in /opt/paeasyinstall /opt/paeasyinstall/attempts; do if [ -e "$p" ] || [ -L "$p" ]; then test ! -L "$p"; test "$(stat -c %u "$p")" = 0; mode=$(stat -c %a "$p"); test "$((8#$mode & 022))" = 0; chmod 700 "$p"; else mkdir -m 700 "$p"; fi; done; mkdir ' + $dir
    [void](Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId -ExistingOnly -Secrets) + 'test ! -e ' + $dir + '; test ! -L ' + $dir + '; ' + $prepare + '; ' + (Get-PASLinuxDirectoryGuard @('/opt/paeasyinstall', '/opt/paeasyinstall/attempts', $dir))))
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('paeasy-linux-' + $AttemptId)
    New-Item $tmp -ItemType Directory -ErrorAction Stop | Out-Null
    $published = $false
    try {
        if (Test-PASWindows) { Protect-PASDirectory $tmp }else {
            & chmod 700 $tmp
            if ($LASTEXITCODE -ne 0) { throw 'Cannot protect local Linux staging' }
        }
        $inputBytes = [Text.Encoding]::UTF8.GetBytes(($Parameters | ConvertTo-Json -Depth 30 -Compress))
        [IO.File]::WriteAllText((Join-Path $tmp 'contract.txt'), $Contract, (Get-PASUtf8NoBom))
        [IO.File]::WriteAllText((Join-Path $tmp 'task.sh'), ([IO.File]::ReadAllText($ScriptPath).Replace("`r`n", "`n")), (Get-PASUtf8NoBom))
        $runner = Join-Path $script:PASEngineRoot 'Assets/LinuxDetachedRunner.sh'
        [IO.File]::WriteAllText((Join-Path $tmp 'runner.sh'), ([IO.File]::ReadAllText($runner).Replace("`r`n", "`n")), (Get-PASUtf8NoBom))
        $unit = "[Unit]`nDescription=PASeasyInstall attempt $AttemptId`n[Service]`nType=oneshot`nRemainAfterExit=yes`nUser=root`nUMask=0077`nWorkingDirectory=$dir`nExecStart=/bin/bash $dir/runner.sh $dir`nExecStopPost=/bin/bash $dir/runner.sh --cleanup $dir`nTimeoutStartSec=$TimeoutSeconds`nRestart=no`nStandardOutput=null`nStandardError=null`n"
        [IO.File]::WriteAllText((Join-Path $tmp 'unit.service'), $unit, (Get-PASUtf8NoBom))
        foreach ($name in @('contract.txt', 'task.sh', 'runner.sh', 'unit.service')) { Copy-PASRawSSH $Target (Join-Path $tmp $name) ($dir + '/' + $name) }
        $checks = @(foreach ($name in @('contract.txt', 'task.sh', 'runner.sh', 'unit.service')) { ((Get-FileHash (Join-Path $tmp $name) -Algorithm SHA256).Hash.ToLowerInvariant()) + '  ' + $name }) -join "`n"
        # Arm target-side expiry BEFORE receiving secrets. /run also disappears on power loss.
        $stageSecrets = 'set -eu; umask 077; for p in /run/paeasyinstall /run/paeasyinstall/attempts; do if [ -e "$p" ] || [ -L "$p" ]; then test ! -L "$p"; test "$(stat -c %u "$p")" = 0; mode=$(stat -c %a "$p"); test "$((8#$mode & 022))" = 0; else mkdir -m 700 "$p"; fi; done; mkdir ' + $secretDir + '; systemd-run --quiet --collect --unit=paeasy-stage-expiry-' + $AttemptId + ' --on-active=120 /bin/bash ' + $dir + '/runner.sh --expire ' + $dir
        [void](Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId) + $stageSecrets + '; ' + (Get-PASLinuxAttemptGuard $AttemptId -Secrets)))
        try {
            $receive = 'set -eu; umask 077; test -d ' + $secretDir + '; test ! -e ' + $secretDir + '/inputs.json; set -C; head -c ' + $inputBytes.Length + ' > ' + $secretDir + '/inputs.json; test "$(wc -c < ' + $secretDir + '/inputs.json)" = ' + $inputBytes.Length + '; jq -e . ' + $secretDir + '/inputs.json >/dev/null'
            $received = Invoke-PASRawSSH $Target ((Get-PASLinuxAttemptGuard $AttemptId -Secrets) + $receive) $inputBytes
            if ($received.ExitCode -ne 0) { throw 'Linux secret envelope streaming failed' }
        } finally { [Array]::Clear($inputBytes, 0, $inputBytes.Length) }
        # Verify executable/contract bytes before publishing a completely staged attempt.
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($checks + "`n"))
        $publish = 'set -eu; umask 077; test -s ' + $secretDir + '/inputs.json; cd ' + $dir + '; chmod 600 ./*; printf %s ' + $encoded + ' | base64 -d | sha256sum -c - >/dev/null; test ! -e /etc/systemd/system/paeasy-' + $AttemptId + '.service; install -m 600 unit.service /etc/systemd/system/paeasy-' + $AttemptId + '.service; boot=$(cat /proc/sys/kernel/random/boot_id); jq -nc --arg id ' + $AttemptId + ' --arg boot "$boot" ''{schemaVersion:2,state:"Dispatched",attemptId:$id,stagedBootId:$boot}'' >status.tmp; mv status.tmp status.json; sync -f ' + $dir + '; sync -f /etc/systemd/system'
        [void](Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId -Secrets) + $publish))
        $published = $true
        Start-PASLinuxDetached $Target $AttemptId
        return [pscustomobject]@{AttemptId = $AttemptId; Directory = $dir; ScheduledTask = ('paeasy-' + $AttemptId + '.service') }
    } finally {
        if (-not $published) {
            # This controller has not called start. Remove only secret staging; retain diagnostics.
            try { [void](Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId -ExistingOnly -Secrets) + 'if [ ! -d ' + $dir + '/claimed ]; then rm -f ' + $dir + '/inputs.json /run/paeasyinstall/attempts/' + $AttemptId + '/inputs.json /etc/systemd/system/paeasy-' + $AttemptId + '.service; rm -f ' + $dir + '/status.json; fi')) }catch { Write-Verbose 'Linux incomplete staging cleanup needs reconciliation' }
        }
        Remove-Item $tmp -Force -Recurse -ErrorAction SilentlyContinue
    }
}
function Get-PASLinuxDetachedStatus {
    param([hashtable]$Target, [string]$AttemptId)
    $dir = Get-PASLinuxAttemptRoot $AttemptId
    $unit = 'paeasy-' + $AttemptId + '.service'
    $code = @'
set -eu
D=__DIR__; U=__UNIT__; R=/run/paeasyinstall/attempts/${D##*/}
if [ ! -f "$D/status.json" ]; then
 if [ -d "$D" ] || [ -f "/etc/systemd/system/$U" ]; then echo '{"state":"Interrupted","reason":"incomplete durable attempt; dispatch cannot be disproven"}'; else echo '{"state":"Missing"}'; fi
 exit 0
fi
state=$(jq -r .state "$D/status.json")
active=$(systemctl show "$U" -p ActiveState --value 2>/dev/null || true)
if [ "$state" = Running ] || [ "$state" = Succeeded ] || [ "$state" = Failed ]; then
 if ! jq -e --arg id "${D##*/}" '.schemaVersion==2 and .attemptId==$id and (.pid|type=="number" and .>0 and .<=2147483647 and floor==.) and (.bootId|type=="string" and test("^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"))' "$D/status.json" >/dev/null; then
  jq '.state="Interrupted" | .message="Linux durable worker identity is missing or inconsistent"' "$D/status.json"; exit 0
 fi
fi
if [ "$state" = Running ]; then
 pid=$(jq -r .pid "$D/status.json"); boot=$(jq -r .bootId "$D/status.json")
 if [ "$boot" != "$(cat /proc/sys/kernel/random/boot_id)" ] || [ ! -r "/proc/$pid/cmdline" ] || ! tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$D"; then
  # The worker writes its final status, then ends: when it ended after the first read, take that final status.
  again=$(jq -r --arg id "${D##*/}" --argjson pid "$pid" --arg boot "$boot" 'if .schemaVersion==2 and .attemptId==$id and .pid==$pid and .bootId==$boot and (.state=="Succeeded" or .state=="Failed") then .state else "" end' "$D/status.json" 2>/dev/null || true)
  if [ -n "$again" ]; then state=$again; else state=Interrupted; fi
 fi
fi
if [ "$state" = Dispatched ]; then
 if ! jq -e --arg id "${D##*/}" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" '.schemaVersion==2 and .attemptId==$id and .stagedBootId==$boot' "$D/status.json" >/dev/null; then jq '.state="Interrupted" | .reason="staged boot identity missing or changed"' "$D/status.json"; exit 0; fi
 if [ -d "$D/claimed" ]; then
  if [ "$active" = activating ]; then jq '.taskState="Running"' "$D/status.json";else jq '.state="Interrupted" | .reason="claimed worker has no running record"' "$D/status.json";fi
  exit 0
 fi
 if [ ! -f "/etc/systemd/system/$U" ]; then
  # A late initializer may still install/start this unit after this observation.
  # No-unit/no-claim evidence cannot authorize a different attempt ID.
  jq '.state="Interrupted" | .reason="published attempt has no unit; initializer quiescence is unconfirmed"' "$D/status.json"
  exit 0
 fi
 if [ ! -s "$R/inputs.json" ]; then jq '.state="Interrupted" | .reason="staging expired; preserve attempt and reconcile"' "$D/status.json";exit 0;fi
 jq '.taskState="Ready"' "$D/status.json"; exit 0
fi
linux_worker_active() {
    # Query failure or incomplete unit metadata is uncertainty, never proof of exit.
    local properties key value load='' unit_active='' sub='' main='' control='' tasks='' group='' group_seen=false
    if ! properties=$(systemctl show "$U" -p LoadState -p ActiveState -p SubState -p MainPID -p ControlPID -p TasksCurrent -p ControlGroup 2>/dev/null);then return 0;fi
    while IFS='=' read -r key value; do
      case "$key" in LoadState)load=$value;;ActiveState)unit_active=$value;;SubState)sub=$value;;MainPID)main=$value;;ControlPID)control=$value;;TasksCurrent)tasks=$value;;ControlGroup)group=$value;group_seen=true;;esac
    done <<< "$properties"
    [[ $load = loaded || $load = not-found ]] && $group_seen || return 0
    [[ $main =~ ^[0-9]{1,10}$ && $control =~ ^[0-9]{1,10}$ ]] || return 0
    (( 10#$main > 0 || 10#$control > 0 )) && return 0
    case "$unit_active:$sub" in active:exited|inactive:dead|failed:failed) ;;*)return 0;;esac
    if [[ $tasks =~ ^[0-9]+$ ]] && [[ $tasks != 0 && $tasks != 18446744073709551615 ]]; then return 0;fi
    # Cgroup v2 and v1-systemd are both supported. Check descendants as well:
    # a child may close every inherited stream and outlive the recorded runner.
    local base path paths read_status
    local -a bases=()
    if [[ -n $group ]];then
      [[ $group = /* && $group != *'/../'* && $group != */.. && $group != *'/./'* ]] || return 0
      bases+=("/sys/fs/cgroup$group" "/sys/fs/cgroup/systemd$group")
    fi
    bases+=("/sys/fs/cgroup/system.slice/$U" "/sys/fs/cgroup/systemd/system.slice/$U")
    for base in "${bases[@]}";do
      [[ -d $base ]] || continue
      paths=$(find "$base" -type f \( -name cgroup.procs -o -name tasks \) -print 2>/dev/null) || return 0
      [[ -n $paths ]] || return 0
      while IFS= read -r path;do
        [[ -r $path ]] || return 0
        if grep -q '[0-9]' "$path";then return 0;else read_status=$?;[[ $read_status = 1 ]] || return 0;fi
      done <<< "$paths"
    done
    return 1
}

worker_active=false
pid=$(jq -r '.pid // 0' "$D/status.json"); boot=$(jq -r '.bootId // ""' "$D/status.json")
case "$pid" in ''|*[!0-9]*) pid=0;; esac
if [ "$boot" = "$(cat /proc/sys/kernel/random/boot_id)" ] && [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$D"; then worker_active=true; fi
if linux_worker_active;then worker_active=true;fi
jq --arg state "$state" --argjson active "$worker_active" '.state=$state | .workerActive=$active | if $state=="Interrupted" then .message="Linux runner stopped without a terminal result" | .exitCode=null else . end' "$D/status.json"
'@
    $raw = Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId -ExistingOnly -Secrets) + $code.Replace('__DIR__', $dir).Replace('__UNIT__', $unit))
    $status = ConvertTo-PASHashtable (ConvertFrom-Json -InputObject $raw)
    if ($status.state -eq 'Succeeded') {
        $contract = ([string](Invoke-PASLinuxControl $Target ('cat -- ' + $dir + '/contract.txt'))).Trim()
        if ($contract -notin @('Object', 'ExitCode')) { throw 'PAExecUnknown: Linux terminal contract is missing or invalid' }
        $tail = Invoke-PASLinuxControl $Target ('tail -c 262144 -- ' + $dir + '/stdout.log.tail')
        $marker = Read-PASResultMarker $tail 'Linux durable attempt'
        if (-not $marker.Found -and
            $contract -eq 'Object') { throw 'PAExecUnknown: successful Linux Object attempt has no terminal result marker; retain the claim and inspect evidence' }
        if ($marker.Found) {
            $terminal = $marker.Value
            if ($terminal.Contains('Passed') -and $terminal.Passed -is [bool]) {
                $status.check = @{
                    schemaVersion = 1
                    passed = [bool]$terminal.Passed
                    message = [string](Get-PASValue $terminal 'Message' '')
                    evidence = @(Get-PASValue $terminal 'Evidence' @())
                    sessionClosed = $true
                }
            }
            if ($terminal.Contains('Data')) { $status.data = $terminal.Data }
            if ($terminal.Contains('Changed') -and $terminal.Changed -is [bool]) { $status.changed = $terminal.Changed }
            if ($terminal.Contains('Message')) { $status.message = Limit-PASText ([string]$terminal.Message) 2000 }
        }
    }
    return $status
}
function Finish-PASLinuxDetached {
    param([hashtable]$Target, [string]$AttemptId)
    $dir = Get-PASLinuxAttemptRoot $AttemptId
    $status = Get-PASLinuxDetachedStatus $Target $AttemptId
    # A step that staged nothing on the server (a file transfer, a direct check) has nothing to clean.
    if ($status.state -eq 'Missing') { return }
    if ($status.state -notin @('Succeeded', 'Failed')) { throw "Cannot clean an unresolved Linux attempt (state $($status.state))" }
    [void](Invoke-PASLinuxControl $Target ((Get-PASLinuxAttemptGuard $AttemptId -ExistingOnly -Secrets) + 'rm -f ' + $dir + '/inputs.json /run/paeasyinstall/attempts/' + $AttemptId + '/inputs.json /etc/systemd/system/paeasy-' + $AttemptId + '.service; systemctl daemon-reload'))
}
