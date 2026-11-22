#!/usr/bin/env bash
# Read-only checks of the HTML5 Gateway stages.
set -Eeuo pipefail
: "${PAEASY_INPUT_JSON:?Input envelope missing}"
setting() { jq -r --arg k "$1" '.Settings[$k] // empty' "$PAEASY_INPUT_JSON"; }
stage=$(jq -r '.Stage' "$PAEASY_INPUT_JSON")
root=$(setting StageRoot)
port=$(setting GatewayPort)
tool=docker
if [[ -f /etc/redhat-release ]]; then tool=podman; fi
passed=false
detail=''
case "$stage" in
  Preflight) [[ -f $(setting MediaTarget) ]] && passed=true; detail='package on the server';;
  Extract) [[ -n $(find "$root/payload" -name html5_console.sh -type f 2>/dev/null | head -n 1) ]] && passed=true; detail='vendor script unpacked';;
  Prerequisites) command -v "$tool" >/dev/null && passed=true; detail="$tool installed";;
  Install) "$tool" ps --format '{{.Names}}' | grep -qx cahtml5gw && passed=true; detail='container running';;
  *)
    # The health page of the gateway. The first start takes a moment.
    for attempt in $(seq 1 24); do
        code=$(curl --silent --insecure --max-time 10 --output /dev/null --write-out '%{http_code}' "https://127.0.0.1:${port}/guac/rest/healthcheck" || true)
        if [[ $code = 200 ]]; then passed=true; break; fi
        sleep 5
    done
    detail="health page https://127.0.0.1:${port}/guac/rest/healthcheck answered ${code:-nothing}";;
esac
jq -nc --argjson ok "$passed" --arg m "HTML5 Gateway $stage: $detail" '{Passed:$ok,Message:$m,Evidence:[]}' | sed 's/^/PAEASY_RESULT:/'
