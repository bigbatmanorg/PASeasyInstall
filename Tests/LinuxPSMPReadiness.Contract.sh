#!/usr/bin/env bash
# Permission-boundary unit contract on isolated /run fixtures. Daemon/service are
# mocked here ONLY; real gateway qualification is recorded separately in docs.
set -euo pipefail
[[ $(id -u) = 0 ]] || { echo 'Run only on a disposable owned Linux target as root'; exit 2; }
fixture=$(mktemp -d /run/paeasy-readiness-contract.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
chmod 700 "$fixture"
for recipe in "$@"; do
    definition=$(awk '/^psmp_local_readiness\(\) \{/{p=1} p{print} p && /^}/{exit}' "$recipe")
    [[ -n $definition ]]
    definition=${definition//\/etc\/opt\/CARKpsmp\/vault\//$fixture/}
    eval "$definition"
    fixture_daemon=true; fixture_aggregate=true
    systemctl() { $fixture_aggregate; }
    pgrep() { if $fixture_daemon; then printf '1\n'; fi; }
    readlink() { printf '/opt/CARKpsmp/bin/psmpserver\n'; }
    files=(psmpappuser.cred psmpgwuser.cred psmpappuser.cred.entropy psmpgwuser.cred.entropy)
    for file in "${files[@]}" vault.ini; do printf 'NONSECRET UNIT FIXTURE\n' > "$fixture/$file"; chmod 600 "$fixture/$file"; done
    psmp_local_readiness || { echo 'FAIL native600'; exit 1; }
    chmod 640 "$fixture"/*.cred*
    psmp_local_readiness || { echo 'FAIL native640 rootgroup-read'; exit 1; }
    for mode in 644 660 650; do
        chmod "$mode" "$fixture/psmpappuser.cred"
        if psmp_local_readiness; then echo "FAIL unsafe mode$mode"; exit 1; fi
    done
    chmod 640 "$fixture/psmpappuser.cred"
    chown 0:65534 "$fixture/psmpappuser.cred"
    if psmp_local_readiness; then echo 'FAIL nonroot-group read'; exit 1; fi
    chown 65534:0 "$fixture/psmpappuser.cred"
    if psmp_local_readiness; then echo 'FAIL nonroot-owner'; exit 1; fi
    chown 0:0 "$fixture/psmpappuser.cred"
    setfacl -m u:65534:r-- "$fixture/psmpappuser.cred"
    if psmp_local_readiness; then echo 'FAIL extra named-user ACL'; exit 1; fi
    setfacl -b "$fixture/psmpappuser.cred"
    mv "$fixture/psmpappuser.cred" "$fixture/original"
    ln -s "$fixture/original" "$fixture/psmpappuser.cred"
    if psmp_local_readiness; then echo 'FAIL symlink'; exit 1; fi
    rm "$fixture/psmpappuser.cred"; mv "$fixture/original" "$fixture/psmpappuser.cred"
    mv "$fixture/psmpgwuser.cred.entropy" "$fixture/entropy"
    if psmp_local_readiness; then echo 'FAIL incomplete entropy'; exit 1; fi
    mv "$fixture/entropy" "$fixture/psmpgwuser.cred.entropy"
    fixture_daemon=false
    if psmp_local_readiness; then echo 'FAIL aggregate active without daemon'; exit 1; fi
    fixture_daemon=true; fixture_aggregate=false
    if psmp_local_readiness; then echo 'FAIL inactive aggregate'; exit 1; fi
    fixture_aggregate=true
    psmp_local_readiness
    echo "PASS $recipe: native600/640 accepted; unsafe permissions, owner/group, ACL, symlink, incomplete credentials, absent daemon/service rejected. Unit fixtures only."
done
