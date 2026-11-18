#!/usr/bin/env bash
# systemd-owned immutable attempt. Never restart a claimed action after process loss/reboot.
set -Eeuo pipefail
umask 077
cleanup_only=false; expire_only=false
if [[ $1 = --cleanup ]]; then cleanup_only=true; root=$2
elif [[ $1 = --expire ]]; then expire_only=true; root=$2
else root=$1; fi
[[ $root =~ ^/opt/paeasyinstall/attempts/[a-f0-9]{32}$ ]] || exit 2
cd "$root"
secret_root=/run/paeasyinstall/attempts/${root##*/}
input="$secret_root/inputs.json"
# Frozen older attempts retain their own older runner and envelope location.
if $expire_only; then
    pid=$(systemctl show "paeasy-${root##*/}.service" -p MainPID --value 2>/dev/null || true)
    if [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$root/runner.sh"; then exit 0; fi
    rm -f "$secret_root/inputs.json" "$secret_root/pta-tls-ca.key" "$secret_root/pta-tls-ca.pass" "$secret_root/pta-tls-input.pfx"; rmdir "$secret_root" 2>/dev/null || true
    exit 0
fi
cleanup() {
    exec 3>&- 4>&-
    # Literal replacement, never regex substitution. Raw vendor logs outside this wrapper remain sensitive.
    if [[ -s $input ]]; then
        for file in stdout.log stdout.log.tail stderr.log stderr.log.tail; do
            [[ -f $file ]] || continue
            if ! jq -Rrs --slurpfile args "$input" '
              reduce ($args[0] | paths(strings) as $p |
                select(any($p[]; tostring | test("password|secret|token|credential|certificatepfxdata";"i"))) |
                getpath($p) | select(length>0)) as $secret (. ; split($secret)|join("[REDACTED]"))
              ' "$file" > "$file.clean"; then
                # Never retain an unfiltered wrapper output if sanitization cannot be completed.
                rm -f "$file" "$file.clean"
            else mv -f "$file.clean" "$file"; fi
        done
    fi
    rm -f inputs.json registration.cred registration.cred.entropy pta-token.json pta-login.body pta-install.body pta-auth.conf
    rm -f "$secret_root/inputs.json" "$secret_root/registration.cred" "$secret_root/registration.cred.entropy" "$secret_root/pta-token.json" "$secret_root/pta-login.body" "$secret_root/pta-install.body" "$secret_root/pta-auth.conf"
    rm -f "$secret_root/pta-tls-ca.key" "$secret_root/pta-tls-ca.pass" "$secret_root/pta-tls-input.pfx"
    rmdir "$secret_root" 2>/dev/null || true
}
if $cleanup_only; then cleanup; exit 0; fi
attempt=${root##*/}; boot=$(cat /proc/sys/kernel/random/boot_id)
linux_dispatched_for_boot() {
    jq -e --arg id "$attempt" --arg boot "$boot" '.schemaVersion==2 and .state=="Dispatched" and .attemptId==$id and .stagedBootId==$boot' status.json >/dev/null
}
# A published job from another boot must never become a new installer launch.
linux_dispatched_for_boot || exit 3
command -v sync >/dev/null || exit 3
mkdir claimed 2>/dev/null || exit 3
sync -f "$root" || exit 3
started=$(date -u +%FT%TZ)
save() { jq -nc --arg state "$1" --arg id "$attempt" --arg boot "$boot" --arg started "$started" --arg ended "$2" --argjson pid "$$" --argjson code "$3" --arg message "$4" '{schemaVersion:2,state:$state,attemptId:$id,bootId:$boot,startedUtc:$started,endedUtc:$ended,pid:$pid,exitCode:$code,message:$message}' > status.tmp; mv -f status.tmp status.json; }
finish() {
    code=$1; trap - EXIT; cleanup
    if [[ $code = 0 ]]; then save Succeeded "$(date -u +%FT%TZ)" 0 'Linux attempt completed; independent verification required'
    elif [[ $code = 129 || $code = 130 || $code = 143 ]]; then save Interrupted "$(date -u +%FT%TZ)" "$code" 'Linux attempt interrupted; reconcile before any retry'
    else save Failed "$(date -u +%FT%TZ)" "$code" 'Linux attempt failed; restricted target logs available'; fi
    exit "$code"
}
trap 'finish $?' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
save Running '' 0 'Linux attempt executing'
sync -f "$root" || exit 3
[[ -s $input ]] || exit 4
export PAEASY_INPUT_JSON="$input"
export PAEASY_CONTRACT="$(cat contract.txt)"
# Keep at most20MiB per wrapper stream, but drain excess so verbose installers never get SIGPIPE.
# Do not apply ulimit to product processes: their database/log files can legitimately be larger.
caplog() {
    # Retain both bounded prefix diagnostics and the bounded protocol tail; drain the entire stream.
    # Filter before ANY durable write, including SIGKILL or power loss. Split
    # multiline secret values into nonempty fragments to redact linewise output.
    jq --unbuffered -Rr --slurpfile args "$input" '
      reduce ($args[0] | paths(strings) as $p |
        select(any($p[]; tostring | test("password|secret|token|credential|certificatepfxdata";"i"))) |
        getpath($p) | split("\n")[] | select(length>0)) as $secret
        (. ; split($secret)|join("[REDACTED]"))' |
      tee >( { head -c 20971520 > "$1"; cat >/dev/null; } ) | tail -c 262144 > "$1.tail"
}
exec 3> >(caplog stdout.log); out_reader=$!
exec 4> >(caplog stderr.log); err_reader=$!
set +e
bash ./task.sh 1>&3 2>&4
code=$?
set -e
exec 3>&- 4>&-
wait "$out_reader" || true
wait "$err_reader" || true
[[ $code = 0 ]] || exit "$code"
if [[ $PAEASY_CONTRACT != ExitCode ]]; then
    marker=$(sed -n 's/^PAEASY_RESULT://p' stdout.log.tail | tail -1)
    [[ -n $marker ]] || exit 4
    printf '%s' "$marker" | jq -e 'type=="object"' >/dev/null || exit 4
fi
