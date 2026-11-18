#!/usr/bin/env bash
# Run only on a disposable PTA target; all fixtures are isolated and removed.
set -eu
recipe=${1:?Pass exact candidate Task.sh path}
umask 077
fixture=$(mktemp -d /run/paeasy-ownership-test.XXXXXX)
root=/opt/paeasyinstall/components/pta-ownership-test
trap 'rm -rf "$fixture" "$root"' EXIT
[[ ! -e $root && ! -L $root ]]
jq -n --arg root "$root" '{Stage:"Preflight",Settings:{Type:"PTA",PolicyProfile:"Lab",StageRoot:$root,MediaTarget:"/opt/paeasyinstall/media/pta/installer.zip",VaultAddress:"192.0.2.11",ValidateTLS:true,ApplyHardening:true,Options:{allowUndersizedMemory:true}}}' > "$fixture/input"
run_refused() { code=0; PAEASY_INPUT_JSON="$fixture/input" bash "$recipe" > "$fixture/result" 2>&1 || code=$?; [[ $code = 2 ]]; }
mkdir "$root"; chown 65534 "$root"
run_refused
[[ $(stat -c %u "$root") = 65534 ]]
rm -rf "$root"; mkdir -m777 "$root"
run_refused
[[ $(stat -c %a "$root") = 777 ]]
rm -rf "$root"; mkdir -m700 "$root"; mkdir "$fixture/outside"; ln -s "$fixture/outside" "$root/stage"
run_refused
[[ -z $(ls -A "$fixture/outside") ]]
rm "$root/stage"; mkdir -m700 "$root/stage"; printf 'ORIGINAL' > "$fixture/outside/data"; ln -s "$fixture/outside/data" "$root/stage/Preflight.json"
run_refused
[[ $(cat "$fixture/outside/data") = ORIGINAL ]]
rm "$root/stage/Preflight.json"
PAEASY_INPUT_JSON="$fixture/input" bash "$recipe" > "$fixture/result" 2>&1
[[ -f "$root/stage/Preflight.json" ]]
echo 'PASS: foreign owner, world-writable directory, stage symlink, marker symlink refused without mutation; valid owned stage accepted. No installer/Vault auth.'
