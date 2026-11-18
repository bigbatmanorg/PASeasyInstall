#!/usr/bin/env bash
# Synthetic native query/actual phase tests only; no host/product mutation.
set -Eeuo pipefail
repo=${1:-.};fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
for which in Task Verify;do
 sed -n '/# BEGIN PAEASY_PTA_OS/,/# END PAEASY_PTA_OS/p' "$repo/PASeasyInstall/Recipes/LinuxComponent/$which.sh" >"$fixture/$which.functions"
done
# Exercise the actual awk parsers too, including duplicate/missing identity and
# per-CPU AVX detection. Fixture files replace the fixed read-only native paths.
python3 - "$fixture/Task.functions" "$fixture" <<'PYINNER'
from pathlib import Path
import sys,re
source=Path(sys.argv[1]).read_text();out=Path(sys.argv[2])
(out/'os.awk').write_text(source.split("timeout 5s awk '\n",1)[1].split("' /etc/os-release",1)[0])
(out/'cpu.awk').write_text(source.split("timeout 5s awk '",2)[2].split("' /proc/cpuinfo",1)[0])
PYINNER
printf 'ID="almalinux"\nVERSION_ID="9.9"\n' >"$fixture/os"
[[ $(awk -f "$fixture/os.awk" "$fixture/os") = 'almalinux 9.9' ]]
for malformed in 'ID=ol' 'ID=ol\nID=rhel\nVERSION_ID=9.6';do
 printf '%b\n' "$malformed" >"$fixture/os"
 if awk -f "$fixture/os.awk" "$fixture/os" >/dev/null;then echo 'FAIL ambiguous native identity';exit 1;fi
done
printf 'flags : sse avx avx2\nflags : avx\n' >"$fixture/cpu"
awk -f "$fixture/cpu.awk" "$fixture/cpu"
for flags in 'flags : sse' 'flags : avx2' 'flags : avx\nflags : sse' '';do
 printf '%b\n' "$flags" >"$fixture/cpu"
 if awk -f "$fixture/cpu.awk" "$fixture/cpu";then echo 'FAIL native AVX parser';exit 1;fi
done
cmp -s "$fixture/Task.functions" "$fixture/Verify.functions"
[[ -s $fixture/Task.functions ]]
# Admission must also precede every phase dispatch, including direct Register.
python3 - "$repo" <<'PYINNER'
from pathlib import Path
import sys
s=(Path(sys.argv[1])/'PASeasyInstall/Recipes/LinuxComponent/Task.sh').read_text()
assert s.index('if [[ $type = PTA ]];then pta_os_preflight || exit 3;fi') < s.index('case "$stage" in\n  Preflight)')
PYINNER
source "$fixture/Task.functions"
fixture_os_id=almalinux;fixture_os_version=9.9;fixture_arch=x86_64;fixture_kernel=5.14.0-570.12.1.el9_6.x86_64;fixture_owner=kernel-core
os_error=false;arch_error=false;kernel_error=false;rpm_error=false;cpu_error=false;has_avx=true
# Delegate only harmless local awk parsing; all fixed native identity paths are mocked.
awk(){
 case "${*: -1}" in
 /etc/os-release)printf '%s %s\n' "$fixture_os_id" "$fixture_os_version"; $os_error && return 2;return 0;;
 /proc/cpuinfo) $cpu_error && return 2;$has_avx;return;;
 /proc/meminfo)echo 16400000;;
 *)command awk "$@";;esac
}
uname(){ case "$1" in -m)printf '%s\n' "$fixture_arch";$arch_error && return 2;;-r)printf '%s\n' "$fixture_kernel";$kernel_error && return 2;;*)return 2;;esac;return 0; }
rpm(){ printf '%s|x86_64|%s\n' "$fixture_owner" "$fixture_kernel";$rpm_error && return 2;return 0; }
timeout(){ [[ $1 = 5s ]];shift;"$@"; }
pta_os_preflight
for fixture_os_id in rhel rocky almalinux;do
 for fixture_os_version in 8.6 8.10 8.99 9.2 9.9 9.10;do pta_os_preflight;done
done
fixture_os_id=ol
for fixture_os_version in 8.10 8.11;do fixture_kernel=4.18.0-553.40.1.el8_10.x86_64;pta_os_preflight;done
for fixture_os_version in 9.6 9.7;do fixture_kernel=5.14.0-570.12.1.0.1.el9_6.x86_64;pta_os_preflight;done
refuse(){ if pta_os_preflight >"$fixture/out" 2>"$fixture/err";then echo "FAIL OS accepted: $*";exit 1;fi; }
for fixture_os_id in rhel rocky almalinux;do for fixture_os_version in 8.0 8.5 9.0 9.1 8 9 9.02 9.2.1 9.2beta 10.0;do refuse minor-version;done;done
fixture_os_id=ol;fixture_os_version=8.9;refuse oracle8minimum
fixture_os_version=9.5;refuse oracle9minimum
fixture_os_version=9.6;fixture_kernel=6.12.0-1.23.3.2.el9uek.x86_64;refuse uek
fixture_kernel=5.14.0-custom;refuse unknownkernel
fixture_kernel=5.14.0-570.12.1.el8_10.x86_64;refuse kernelmajor
fixture_kernel=5.14.0-570.12.1.el9_6.x86_64;fixture_owner=kernel-uek-core;refuse wrongpackage
fixture_owner=kernel-core;rpm_error=true;refuse plausible-rpm-output-nonzero;rpm_error=false
kernel_error=true;refuse plausible-fixture_kernel-output-nonzero;kernel_error=false
fixture_os_id=almalinux;fixture_os_version=9.9
for fixture_arch in aarch64 unknown;do refuse architecture;done;fixture_arch=x86_64
for flag in os_error arch_error cpu_error;do declare "$flag=true";refuse "$flag";declare "$flag=false";done
has_avx=false;refuse noavx;has_avx=true
# Run the real public Task phase arms and full independent verifier case with
# other boundaries stubbed. Rejection must precede product health/credential calls.
python3 - "$repo" "$fixture" <<'PY'
from pathlib import Path
import sys
repo,out=map(Path,sys.argv[1:]);task=(repo/'PASeasyInstall/Recipes/LinuxComponent/Task.sh').read_text();verify=(repo/'PASeasyInstall/Recipes/LinuxComponent/Verify.sh').read_text()
for phase,nextphase in [('Preflight','Extract'),('Verify','*')]:
 body=task.split('  '+phase+')\n',1)[1].split('  '+nextphase+')',1)[0]
 (out/('task-'+phase)).write_text('case "$stage" in\n  '+phase+')\n'+body+'\nesac\n')
admission=task.split('# Recheck before every PTA phase',1)[1].split('case "$stage" in\n  Preflight)',1)[0]
(out/'admission').write_text('if [[ $type = PTA ]]'+admission.split('if [[ $type = PTA ]]',1)[1])
(out/'independent').write_text('passed=false\n'+verify.split('passed=false\n',1)[1].split('\njq -nc',1)[0]+'\n[[ $passed == true ]]\n')
PY
media=$fixture/media.zip;touch "$media";PAEASY_INPUT_JSON=$fixture/input;root=$fixture;type=PTA;secure=true
ID=almalinux;VERSION_ID=9.9
pta_filesystem_preflight(){ return 0; };pta_cpu_preflight(){ return 0; }
success(){ echo PHASE_SUCCESS; };options(){ [[ $1 != installerHost ]] || echo fixture.invalid;return 0; }
jq(){ case "$*" in *MediaTarget*)echo "$media";;*ValidateTLS*)echo true;;*Address*|*installerHost*)echo fixture.invalid;;esac; }
systemctl(){ echo PRODUCT_QUERY >>"$fixture/product";return 0; }
sed(){ echo 15.0.0; };curl(){ echo 'Diamond.version = "15.0.0"'; }
for stage in Preflight Verify;do
 fixture_os_id=almalinux;fixture_os_version=9.9
 (source "$fixture/task-$stage") >"$fixture/pass";grep -Fq PHASE_SUCCESS "$fixture/pass"
 (source "$fixture/independent")
 for scenario in el90 el85 uek nativeerror;do
  fixture_os_id=almalinux;fixture_os_version=9.9;os_error=false
  case "$scenario" in el90)fixture_os_version=9.0;;el85)fixture_os_version=8.5;;uek)fixture_os_id=ol;fixture_os_version=9.6;fixture_kernel=6.12.0-1.23.3.2.el9uek.x86_64;;nativeerror)os_error=true;;esac
  rm -f "$fixture/product"
  if (source "$fixture/task-$stage") >"$fixture/rejected" 2>&1;then echo "FAIL Task $stage $scenario";exit 1;fi
  if grep -Fq PHASE_SUCCESS "$fixture/rejected";then exit 1;else [[ $? = 1 ]] || exit 1;fi
  [[ ! -e $fixture/product ]]
  if (source "$fixture/independent") >/dev/null 2>&1;then echo "FAIL independent $stage $scenario";exit 1;fi
  [[ ! -e $fixture/product ]]
 done
 os_error=false
done
fixture_os_id=almalinux;fixture_os_version=9.0
for stage in Register ConfigureTLS Harden Install;do
 if (source "$fixture/admission";echo DISPATCH) >"$fixture/admission-out" 2>&1;then echo 'FAIL mutation admission';exit 1;fi
 if grep -Fq DISPATCH "$fixture/admission-out";then exit 1;else [[ $? = 1 ]] || exit 1;fi
done
printf 'PASS PTA OS contracts: exact minor boundaries, Oracle RHCK ownership/UEK rejection, x86_64/AVX, native failures, actual Task Preflight/Verify and independent case. Live OS qualification NotTested.\n'
