#!/usr/bin/env bash
# Isolated pure-shell/entry-point checks. No target, product, SSH or OS mutation.
set -Eeuo pipefail
repo=${1:-.}
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
for which in Task Verify;do
 sed -n '/# BEGIN PAEASY_PTA_FILESYSTEM/,/# END PAEASY_PTA_FILESYSTEM/p' "$repo/PASeasyInstall/Recipes/LinuxComponent/$which.sh" >"$fixture/$which.functions"
done
cmp -s "$fixture/Task.functions" "$fixture/Verify.functions"
[[ -s $fixture/Task.functions ]]
source "$fixture/Task.functions"
fs_capacity=530000000000;fs_free=510000000000;fs_type=xfs;split_path=;mount_error=false;df_error=false;df_malformed=false
# timeout shim invokes only fixture functions; it never executes host findmnt/df.
timeout(){ [[ $1 == 5s ]];shift;"$@"; }
findmnt(){
 if [[ $* == *FSTYPE* ]];then printf '%s\n' "$fs_type";return 0;fi
 if [[ -n $split_path && ${*: -1} == "$split_path" ]];then printf '%s\n' "$split_path";else printf '/\n';fi
 $mount_error && return 2
 return 0
}
df(){
 if $df_malformed;then printf 'Size Avail\nunknown plausible\n';else printf 'Size Avail\n%s %s\n' "$fs_capacity" "$fs_free";fi
 $df_error && return 1
 return 0
}
pta_filesystem_preflight
fs_capacity=500000000000;fs_free=2147483648;pta_filesystem_preflight
refuse(){ if pta_filesystem_preflight >"$fixture/out" 2>"$fixture/err";then echo "FAIL unsafe filesystem accepted: $1";exit 1;fi; }
for fs_capacity in 20000000000 40000000000 499999999999;do refuse undersized;grep -Fq 'at least500GB' "$fixture/err";done
fs_capacity=530000000000
fs_free=2147483647;refuse installer-workspace
fs_free=540000000000;refuse impossible-free
fs_free=510000000000
for split_path in /var /var/log /opt;do refuse split-layout;grep -Fq 'split/CIS/custom' "$fixture/err";done
split_path=
fs_type=overlay;refuse unsupported-fstype
fs_type=xfs
mount_error=true;refuse native-mount-error-with-valid-output;mount_error=false
df_error=true;refuse native-df-error-with-valid-output;df_error=false
df_malformed=true;refuse malformed-size;df_malformed=false
# Extract actual public phase code (no staging-prefix code or native dispatch).
python3 - "$repo" "$fixture" <<'PY'
from pathlib import Path
import sys
repo,fixture=map(Path,sys.argv[1:])
task=(repo/'PASeasyInstall/Recipes/LinuxComponent/Task.sh').read_text()
verify=(repo/'PASeasyInstall/Recipes/LinuxComponent/Verify.sh').read_text()
preflight=task.split('  Preflight)\n',1)[1].split('  Extract)',1)[0]
(fixture/'task-preflight').write_text('case "$stage" in\n  Preflight)\n'+preflight+'\nesac\n')
last=task.split('  Verify)\n',1)[1].split('  *)',1)[0]
(fixture/'task-verify').write_text('case "$stage" in\n  Verify)\n'+last+'\nesac\n')
case=verify.split('passed=false\n',1)[1].split('\njq -nc',1)[0]
(fixture/'independent-case').write_text('passed=false\n'+case+'\n[[ $passed == true ]]\n')
PY
media=$fixture/media.zip;touch "$media"
PAEASY_INPUT_JSON=$fixture/input.json;printf '{}\n' >"$PAEASY_INPUT_JSON"
type=PTA;ID=almalinux;VERSION_ID=9.9;secure=true;root=$fixture/stage
success(){ printf 'SYNTHETIC_PHASE_SUCCESS\n'; }
pta_cpu_preflight(){ return 0; }
pta_os_preflight(){ return 0; }
# These model existing opt-in CPU/RAM Lab overrides. They MUST NOT bypass disk.
options(){ case "$1" in allowUndersizedDisk|allowUndersizedCPU|allowUndersizedMemory)echo true;; installerHost)echo fixture.invalid;; esac; }
jq(){ case "$*" in *MediaTarget*)printf '%s\n' "$media";; *ValidateTLS*)echo true;; *Address*|*installerHost*)echo fixture.invalid;; *PolicyProfile*)echo Lab;; esac; }
awk(){ if [[ ${*: -1} == /proc/meminfo ]];then echo 16400000;else command awk "$@";fi; }
command(){ if [[ ${1:-} == -v && ${2:-} =~ ^(rpm|curl|unzip)$ ]];then return 0;fi;builtin command "$@"; }
systemctl(){ return 0; }
sed(){ echo 15.0.0; }
curl(){ printf 'Diamond.version = "15.0.0"\n'; }
for stage in Preflight Verify;do
 fs_capacity=530000000000
 (source "$fixture/task-${stage,,}") >"$fixture/positive-$stage"
 grep -Fq SYNTHETIC_PHASE_SUCCESS "$fixture/positive-$stage"
 (source "$fixture/independent-case")
 for fs_capacity in 20000000000 40000000000;do
  if (source "$fixture/task-${stage,,}") >"$fixture/task-fail" 2>&1;then echo 'FAIL public Task accepted undersized PTA';exit 1;fi
  if grep -Fq SYNTHETIC_PHASE_SUCCESS "$fixture/task-fail";then echo 'FAIL success after failed filesystem';exit 1;else [[ $? == 1 ]] || exit 1;fi
  if (source "$fixture/independent-case") >"$fixture/verify-fail" 2>&1;then echo 'FAIL independent Verify accepted undersized PTA';exit 1;fi
 done
done
# No mutation utilities in the closed verifier functions.
if grep -Eq '^[[:space:]]*(growpart|resize2fs|xfs_growfs|mount|umount|parted|sgdisk|fdisk|mkdir|chmod|dnf|yum|apt|systemctl)([[:space:]]|$)' "$fixture/Task.functions";then echo 'FAIL filesystem guard mutates target';exit 1;else [[ $? == 1 ]] || exit 1;fi
printf 'PASS PTA filesystem contracts: actual Task Preflight/Verify and independent verifier refuse20/40GB despiteLab options, enforce500GB boundary/workspace/single-root, and fail closed on native IO errors. Live target/CIS split layout qualification NotTested.\n'
