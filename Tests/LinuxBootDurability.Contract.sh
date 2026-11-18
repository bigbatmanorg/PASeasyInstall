#!/usr/bin/env bash
# Isolated local fixtures; never reboots/crashes a host or touches a lab VM.
# Only fixed runner path guards are remapped to a private user-runtime directory.
set -euo pipefail
observer=${1:?Pass LinuxDetached.ps1}
runner=${2:?Pass LinuxDetachedRunner.sh}
fixture=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/paeasy-boot-contract.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
chmod 700 "$fixture"
export PAEASY_BOOT_FIXTURE_ROOT=$fixture
text=$(cat "$runner")
old='[[ $root =~ ^/opt/paeasyinstall/attempts/[a-f0-9]{32}$ ]] || exit 2'
new='[[ $root == "$PAEASY_BOOT_FIXTURE_ROOT"/attempts/* ]] || exit 2'
[[ $text = *"$old"* ]];text=${text/"$old"/"$new"}
old='secret_root=/run/paeasyinstall/attempts/${root##*/}'
new='secret_root=$PAEASY_BOOT_FIXTURE_ROOT/leases/${root##*/}'
[[ $text = *"$old"* ]];text=${text/"$old"/"$new"}
printf '%s\n' "$text" > "$fixture/runner.sh"
boot=$(cat /proc/sys/kernel/random/boot_id)
make_case(){
 id=$1;dir="$fixture/attempts/$id";mkdir -p "$dir" "$fixture/leases/$id"
 printf Object > "$dir/contract.txt";printf '{}' > "$fixture/leases/$id/inputs.json"
 printf '#!/bin/bash\necho BODY >>"$PAEASY_BOOT_FIXTURE_LOG"\necho '\''PAEASY_RESULT:{"Changed":true}'\''\n' > "$dir/task.sh"
 export PAEASY_BOOT_FIXTURE_LOG="$dir/order.log"
}
make_case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq -nc --arg id "$id" --arg boot "$boot" '{schemaVersion:2,state:"Dispatched",attemptId:$id,stagedBootId:$boot}' > "$dir/status.json"
sync(){ printf 'sync:%s\n' "$(jq -r .state status.json)" >> "$PAEASY_BOOT_FIXTURE_LOG";command sync "$@"; }
export -f sync
bash "$fixture/runner.sh" "$dir"
[[ $(cat "$dir/order.log") = $'sync:Dispatched\nsync:Running\nBODY' ]]
[[ $(jq -r .state "$dir/status.json") = Succeeded ]]
echo 'PASS actual sync-f: durable claim and Running publication precede harmless body.'
make_case bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq -nc --arg id "$id" '{schemaVersion:2,state:"Dispatched",attemptId:$id}' > "$dir/status.json"
if bash "$fixture/runner.sh" "$dir";then echo 'FAIL missing staged boot ran';exit 1;fi
[[ ! -e $dir/claimed && ! -e $dir/order.log ]]
make_case cccccccccccccccccccccccccccccccc
jq -nc --arg id "$id" '{schemaVersion:2,state:"Dispatched",attemptId:$id,stagedBootId:"11111111-1111-1111-1111-111111111111"}' > "$dir/status.json"
if bash "$fixture/runner.sh" "$dir";then echo 'FAIL changed boot ran';exit 1;fi
[[ ! -e $dir/claimed && ! -e $dir/order.log ]]
echo 'PASS runner refuses missing/different staged boot before claim/body.'
make_case dddddddddddddddddddddddddddddddd
jq -nc --arg id "$id" --arg boot "$boot" '{schemaVersion:2,state:"Dispatched",attemptId:$id,stagedBootId:$boot}' > "$dir/status.json"
sync(){ return 1; };export -f sync
if bash "$fixture/runner.sh" "$dir";then echo 'FAIL failed flush ran body';exit 1;fi
[[ ! -e $dir/order.log ]]
echo 'PASS failed durability barrier prevents body; no unflushed fallback.'
unset -f sync
# Extract exact observer shell for metadata classification; systemctl is a unit
# stub, not product evidence. No fixed /opt or /etc paths are written.
probe=$(awk '/^set -eu$/{p=1} p && /^'"'"'@/{exit} p{print}' "$observer")
[[ -n $probe ]]
make_case eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
probe=${probe//__DIR__/$dir};probe=${probe//__UNIT__/paeasy-$id.service}
printf '%s\n' "$probe" > "$fixture/probe.sh"
systemctl(){ printf 'inactive\n'; };export -f systemctl
[[ $(bash "$fixture/probe.sh" | jq -r .state) = Interrupted ]]
jq -nc --arg id "$id" '{schemaVersion:2,state:"Dispatched",attemptId:$id}' > "$dir/status.json"
[[ $(bash "$fixture/probe.sh" | jq -r .state) = Interrupted ]]
jq -nc --arg id "$id" '{schemaVersion:2,state:"Dispatched",attemptId:$id,stagedBootId:"11111111-1111-1111-1111-111111111111"}' > "$dir/status.json"
[[ $(bash "$fixture/probe.sh" | jq -r .state) = Interrupted ]]
jq -nc --arg id "$id" --arg boot "$boot" '{schemaVersion:2,state:"Dispatched",attemptId:$id,stagedBootId:$boot}' > "$dir/status.json"
systemctl(){ return 1; };export -f systemctl
[[ $(bash "$fixture/probe.sh" | jq -r .state) = Interrupted ]]
systemctl(){ printf 'inactive\n'; };export -f systemctl
[[ $(bash "$fixture/probe.sh" | jq -r .state) = Interrupted ]]
mkdir "$dir/claimed"
[[ $(bash "$fixture/probe.sh" | jq -r .state) = Interrupted ]]
echo 'PASS observer: incomplete/missing-boot/claimed and same-boot published/unclaimed/no-unit evidence remain Interrupted; a late initializer cannot authorize a new attempt. Actual power loss NotTested.'
