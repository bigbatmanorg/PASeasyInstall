#!/usr/bin/env bash
# Disposable live PTA target, public certificates only, isolated root fixtures.
set -eu
recipe=${1:?Pass exact candidate Task.sh}
other=${2:?Pass a different public certificate for trust-change rejection}
root=$(mktemp -d /run/paeasy-cert-contract.XXXXXX)
trap 'rm -rf "$root"' EXIT
chmod 700 "$root"
eval "$(awk '/^pta_export_public_listener_certificate\(\) \{/{p=1} p{print} p && /^}/{exit}' "$recipe")"
pta_export_public_listener_certificate
first=$(sha256sum "$root/syslog-public.pem" | cut -d' ' -f1)
pta_export_public_listener_certificate
[[ $(sha256sum "$root/syslog-public.pem" | cut -d' ' -f1) = "$first" ]]
[[ $(stat -c %a "$root/syslog-public.pem") = 600 ]]
cp "$other" "$root/syslog-public.pem"
other_hash=$(sha256sum "$root/syslog-public.pem" | cut -d' ' -f1)
[[ $other_hash != "$first" ]]
if pta_export_public_listener_certificate >/dev/null 2>&1; then echo 'FAIL changed trust accepted';exit 1;fi
[[ $(sha256sum "$root/syslog-public.pem" | cut -d' ' -f1) = "$other_hash" ]]
mv "$root/syslog-public.pem" "$root/original.pem"
ln -s "$root/original.pem" "$root/syslog-public.pem"
if pta_export_public_listener_certificate >/dev/null 2>&1; then echo 'FAIL public artifact symlink accepted';exit 1;fi
[[ $(sha256sum "$root/original.pem" | cut -d' ' -f1) = "$other_hash" ]]
echo 'PASS: real live listener certificate export, idempotent pin,600mode, changed certificate and symlink refusal. Public material only; no private keys read.'
