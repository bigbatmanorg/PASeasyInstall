#!/usr/bin/env bash
# Executes the actual recipe CPU guard in isolated inputs; no product/target work.
set -euo pipefail
recipe=${1:?Pass candidate Task.sh}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export PAEASY_INPUT_JSON="$fixture/inputs.json"
guard=$(awk '/^pta_cpu_preflight\(\) \{/{p=1} p{print} p && /^}/{exit}' "$recipe")
[[ -n $guard ]]
eval "$guard"
nproc(){ printf '%s\n' "$cpu"; }
run_case(){
    local expected=$1 profile=$2 override=$3
    jq -nc --arg profile "$profile" --argjson override "$override" '{Settings:{PolicyProfile:$profile,Options:{allowUndersizedCPU:$override}}}' > "$PAEASY_INPUT_JSON"
    local rc=0
    pta_cpu_preflight >"$fixture/output" 2>&1 || rc=$?
    [[ $rc == "$expected" ]] || { echo "FAIL CPU=$cpu profile=$profile option=$override rc=$rc"; cat "$fixture/output";exit 1; }
}
cpu=2
run_case 3 Secure false
run_case 3 Secure true
run_case 3 Lab false
run_case 3 Lab '"true"'
run_case 3 Lab 1
run_case 0 Lab true
grep -Fq 'LAB DEVIATION: PTA CPU 2 below vendor P001 minimum 8' "$fixture/output"
cpu=8
run_case 0 Secure false
[[ ! -s $fixture/output ]]
cpu=64
run_case 0 Secure false
cpu=0
run_case 3 Lab true
cpu=eight
run_case 3 Lab true
nproc(){ return 1; }
run_case 3 Lab true
grep -Fq 'Cannot inspect PTA CPU count' "$fixture/output"
# The real Preflight branch must invoke the same guard before success.
preflight=$(awk '/^  Preflight\)/{p=1} p{print} p && /success .*Linux prerequisites verified/{exit}' "$recipe")
[[ $preflight == *'pta_cpu_preflight'* ]]
echo 'PASS actual PTA CPU guard: >=8, fail-closed query, Secure refusal, typed explicit Lab-only exception and visible deviation. Live PTA qualification NotTested.'
