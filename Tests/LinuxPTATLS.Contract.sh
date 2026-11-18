#!/usr/bin/env bash
# Real Java-properties guard and OpenSSL certificate unit tests, not a native
# PTA installation/PFX-import qualification. All keys are disposable fixtures.
set -euo pipefail
recipe=${1:?Pass candidate Task.sh}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
chmod 700 "$fixture"
for name in pta_vault_state pta_tls_public_valid; do
    eval "$(awk -v name="$name" '$0==name"() {"{p=1} p{print} p && /^}/{exit}' "$recipe")"
done
state() { printf '%s\n' "$1" > "$fixture/Vault.ini"; [[ $(pta_vault_state "$fixture/Vault.ini") = "$2" ]]; }
state $'ADDRESS=11.22.33.444\nPORT=1858' Default
state $'ADDRESS=192.0.2.194\nPORT=1858' Configured
state $'ADDRESS=192.0.2.194,192.0.2.124\nPORT=1858' Configured
state $'ADDRESS=192.0.2.194\nADDRESS=192.0.2.124\nPORT=-1' Configured
state $'ADDRESS=11.22.33.444,192.0.2.194\nPORT=1858' Partial
state $'ADDRESS=999.1.2.3\nPORT=1858' Partial
state $'ADDRESS=01.1.2.3\nPORT=1858' Partial
state $'ADDRESS=192.0.2.194\nPORT=0' Partial
state $'ADDRESS=11.22.33.444\nPORT=0' Partial
state $'ADDRESS=11.22.33.444\nPORT=1858\nPORT=1858' Unknown
state $'ADDRESS=11.22.33.444\\\nPORT=1858' Unknown
[[ $(pta_vault_state "$fixture/missing") = Unknown ]]
ln -s "$fixture/Vault.ini" "$fixture/symlink"
[[ $(pta_vault_state "$fixture/symlink") = Unknown ]]
echo 'PASS native Vault predicate: default/configured/list/nonzero port; partial/ambiguous/missing/symlink fail closed.'
# Ephemeral fixture keys only. Production uses native CSR private key or PFX.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture/ca.key" -out "$fixture/ca.pem" -days 2 -subj /CN=DisposableUnitCA -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -keyout "$fixture/leaf.key" -out "$fixture/leaf.csr" -subj /CN=pta-unit >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:127.0.0.1,DNS:pta-unit\n' > "$fixture/extensions"
openssl x509 -req -in "$fixture/leaf.csr" -CA "$fixture/ca.pem" -CAkey "$fixture/ca.key" -set_serial 1 -days 2 -sha256 -extfile "$fixture/extensions" -out "$fixture/leaf.pem" >/dev/null 2>&1
tls_ip=127.0.0.1;tls_name=pta-unit
pta_tls_public_valid "$fixture/leaf.pem" "$fixture/ca.pem"
tls_ip=127.0.0.2
if pta_tls_public_valid "$fixture/leaf.pem" "$fixture/ca.pem" >/dev/null 2>&1; then echo 'FAIL wrong IP';exit 1;fi
tls_ip=127.0.0.1;tls_name=wrong-name
if pta_tls_public_valid "$fixture/leaf.pem" "$fixture/ca.pem" >/dev/null 2>&1; then echo 'FAIL wrong DNS';exit 1;fi
tls_name=pta-unit
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture/self.key" -out "$fixture/self.pem" -days 2 -subj /CN=pta-unit -addext 'basicConstraints=critical,CA:FALSE' -addext 'keyUsage=critical,digitalSignature,keyEncipherment' -addext 'extendedKeyUsage=serverAuth,clientAuth' -addext 'subjectAltName=IP:127.0.0.1,DNS:pta-unit' >/dev/null 2>&1
if pta_tls_public_valid "$fixture/self.pem" "$fixture/self.pem" >/dev/null 2>&1; then echo 'FAIL non-CA leaf trusted as authority';exit 1;fi
cat "$fixture/leaf.pem" "$fixture/leaf.key" > "$fixture/not-public.pem"
if pta_tls_public_valid "$fixture/not-public.pem" "$fixture/ca.pem" >/dev/null 2>&1; then echo 'FAIL private material accepted as public artifact';exit 1;fi
# PFX public extraction uses stdin password; no private-key extraction command.
printf 'UnitOnlyContainerPassword\n' > "$fixture/password"
openssl pkcs12 -export -inkey "$fixture/leaf.key" -in "$fixture/leaf.pem" -certfile "$fixture/ca.pem" -passout "file:$fixture/password" -out "$fixture/input.pfx" >/dev/null 2>&1
openssl pkcs12 -in "$fixture/input.pfx" -passin fd:3 -clcerts -nokeys -out "$fixture/pfx-leaf.pem" 3<"$fixture/password"
openssl pkcs12 -in "$fixture/input.pfx" -passin fd:3 -cacerts -nokeys -out "$fixture/pfx-chain.pem" 3<"$fixture/password"
pta_tls_public_valid "$fixture/pfx-leaf.pem" "$fixture/pfx-chain.pem"
echo 'PASS real OpenSSL leaf/CA IP+DNS+both-purpose validation, wrong identity/private artifact refusal, password-file/fd PFX public extraction. Native utilities NotTested.'

# Execute the actual public result emitter without executing any native utility.
tls_leaf_hash=$(openssl x509 -in "$fixture/leaf.pem" -outform DER | sha256sum | cut -d' ' -f1)
tls_trust_bundle_hash=$(sha256sum "$fixture/ca.pem" | cut -d' ' -f1)
tls_changed=false
emitter=$(awk '/^[[:space:]]*jq -nc --arg hash.*PTA native TLS configured/{print}' "$recipe")
[[ -n $emitter ]]
result=$(eval "$emitter")
printf '%s' "${result#PAEASY_RESULT:}" | jq -e --arg leaf "$tls_leaf_hash" --arg bundle "$tls_trust_bundle_hash" '.Changed==false and .Data.Hash==$leaf and .Data.TrustBundleSHA256==$bundle and (has("Hash")|not) and (has("TrustBundleSHA256")|not)' >/dev/null
echo 'PASS actual ConfigureTLS marker exposes only approved Data.Hash/Data.TrustBundleSHA256 digests; read-only Changed=false preserved.'
