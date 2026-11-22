#!/usr/bin/env bash
# Read-only checks of the PTA stages.
set -Eeuo pipefail
: "${PAEASY_INPUT_JSON:?Input envelope missing}"
setting() { jq -r --arg k "$1" '.Settings[$k] // empty' "$PAEASY_INPUT_JSON"; }
stage=$(jq -r '.Stage' "$PAEASY_INPUT_JSON")
root=$(setting StageRoot)
passed=false
detail=''
case "$stage" in
  Preflight) [[ -f $(setting MediaTarget) ]] && passed=true; detail='package on the server';;
  Extract) [[ -n $(find "$root/payload" -name pta_installer.sh -type f 2>/dev/null | head -n 1) ]] && passed=true; detail='vendor installer unpacked';;
  Prerequisites) rpm -q --quiet sshpass unzip tar && passed=true; detail='sshpass, unzip and tar installed';;
  Install) [[ -f /opt/pta/utility/internal/ptaAutomaticConfiguration.py ]] && passed=true; detail='PTA software installed';;
  *)
    # After the configuration: the service manager is active and the PTA web application answers with its version.
    version=''
    for attempt in $(seq 1 36); do
        if systemctl is-active --quiet appmgr; then
            version=$(curl --silent --insecure --max-time 10 https://localhost:8443/diamond/version 2>/dev/null | sed -n 's/.*Diamond.version = "\([0-9.]*\)".*/\1/p' | head -n 1)
            [[ -n $version ]] && break
        fi
        sleep 10
    done
    if [[ -n $version ]] && grep -q "^ADDRESS=$(setting VaultAddress)\$" /etc/opt/pta/diamond-resources/Vault.ini; then passed=true; fi
    detail="appmgr $(systemctl is-active appmgr 2>/dev/null), PTA web version ${version:-none}, Vault $(sed -n 's/^ADDRESS=//p' /etc/opt/pta/diamond-resources/Vault.ini 2>/dev/null | head -n 1)";;
esac
jq -nc --argjson ok "$passed" --arg m "PTA $stage: $detail" '{Passed:$ok,Message:$m,Evidence:[]}' | sed 's/^/PAEASY_RESULT:/'
