#!/usr/bin/env bash
# Target-side contract test only. Stub the vendor process, never product health.
# Requires a disposable PTA target with its real vendor wizard files present.
set -Eeuo pipefail
recipe=${1:?Pass exact candidate Task.sh path}
[[ -f /opt/pta/webapps/ROOT.war && ! -L /opt/pta/webapps/ROOT.war ]] || { echo "Requires an already deployed disposable PTA target; no product writes allowed in this contract test"; exit 2; }
fixture=$(mktemp -d /run/paeasy-vendorcli-contract.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
chmod 700 "$fixture"
root="$fixture/component"; mkdir -p "$root/stage"
export PAEASY_INPUT_JSON="$fixture/input.json"
jq -n '{Settings:{Type:"PTA",VaultAddress:"192.0.2.11",VaultUser:"FixtureAdmin",Options:{pvwaHost:"fixture.invalid",vaultTimezone:"UTC",vaultDrAddresses:["192.0.2.12"]}},VaultPassword:"fixture-only-secret"}' > "$PAEASY_INPUT_JSON"
chmod 600 "$PAEASY_INPUT_JSON"
options() { jq -r --arg k "$1" '.Settings.Options[$k] // empty' "$PAEASY_INPUT_JSON"; }
# Exercise the candidate function's real journal/JSON behavior; intercept only launch.
eval "$(awk '/^pta_vendor_cli\(\) \{/{p=1} p{print} p && /^}/{exit}' "$recipe")"
calls=0; fail_step=''
bash() {
  [[ $1 = /opt/pta/prepwiz/run.sh && $2 = --inputStepData ]] || return 92
  local input step
  input=$(cat); step=$(jq -r '.stepName' <<< "$input")
  # This stub runs in pipeline subshells, so count via isolated protected fixture.
  printf '%s\n' "$step" >> "$fixture/calls"
  if [[ $step = PASConnectionConfigurationStep ]]; then
    jq -e '.inputParameters | .vaultCredentialsPassword=="fixture-only-secret" and .pvwaTrustConnection=="n" and .pvwaHttpsEnabled=="y" and .vaultDrIpsConfiguration=="192.0.2.12"' <<< "$input" >/dev/null || return 93
  fi
  [[ $step != "$fail_step" ]] || return 23
}
pta_vendor_cli >/dev/null
[[ $(wc -l < "$fixture/calls") = 9 ]]
pta_vendor_cli >/dev/null
[[ $(wc -l < "$fixture/calls") = 9 ]]
# A different configuration cannot consume old checkpoints.
jq '.Settings.VaultAddress="192.0.2.13"' "$PAEASY_INPUT_JSON" > "$fixture/new"
mv "$fixture/new" "$PAEASY_INPUT_JSON"
if pta_vendor_cli >/dev/null 2>&1; then echo 'FAIL changed configuration resumed'; exit 1; fi
[[ $(wc -l < "$fixture/calls") = 9 ]]
# A genuine nonzero vendor process must retain failure and never repeat it.
rm -f "$root/stage/"*.json
fail_step=PASConnectionConfigurationStep
if pta_vendor_cli >/dev/null 2>&1; then echo 'FAIL vendor failure accepted'; exit 1; fi
[[ $(jq -r .state "$root/stage/PTA-VendorCLI-PASConnectionConfigurationStep.json") = Failed ]]
count=$(wc -l < "$fixture/calls")
if pta_vendor_cli >/dev/null 2>&1; then echo 'FAIL failed step rerun'; exit 1; fi
[[ $(wc -l < "$fixture/calls") = "$count" ]]
# A crash leaves Running; it must be just as non-repeatable as Failed.
jq '.state="Running"' "$root/stage/PTA-VendorCLI-PASConnectionConfigurationStep.json" > "$fixture/new"
mv "$fixture/new" "$root/stage/PTA-VendorCLI-PASConnectionConfigurationStep.json"
if pta_vendor_cli >/dev/null 2>&1; then echo 'FAIL uncertain step rerun'; exit 1; fi
[[ $(wc -l < "$fixture/calls") = "$count" ]]
echo 'PASS: 9-step stdin contract, completed continuation, configuration mismatch, failed/Running refusal. Vendor process STUBBED; product integration NOT TESTED.'
