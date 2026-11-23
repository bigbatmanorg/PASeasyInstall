#!/usr/bin/env bash
set -Eeuo pipefail
: "${PAEASY_INPUT_JSON:?Input envelope missing}"
stage=$(jq -r '.Stage' "$PAEASY_INPUT_JSON")
type=$(jq -r '.Settings.Type' "$PAEASY_INPUT_JSON")
. /etc/os-release
root=$(jq -r '.Settings.StageRoot' "$PAEASY_INPUT_JSON")
# BEGIN PAEASY_UBUNTU24_PSMP_BASELINE (identical independent Task/Verify closure)
psmp_ubuntu_trusted() {
    local path=$1 mode owner
    while :; do
        [[ -e $path && ! -L $path ]] || return 1
        owner=$(stat -c %u "$path") || return 1
        [[ $owner = 0 ]] || return 1
        mode=$(stat -c %a "$path") || return 1
        [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 022) == 0 )) || return 1
        getfacl -cp "$path" | awk '/^(user|group):[^:]+:/ {bad=1} /^mask:/ {bad=1} END {exit bad?1:0}' || return 1
        [[ $path != / ]] || break
        path=$(dirname "$path")
    done
}
psmp_ubuntu_ssh_content() {
    cat <<'POLICY'
# PASeasy Ubuntu 24.04 PSMP baseline v1; vendor forwarding/PAM retained.
PermitRootLogin prohibit-password
PermitEmptyPasswords no
X11Forwarding no
PermitTunnel no
GatewayPorts no
Match User root
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    DisableForwarding yes
Match all
POLICY
}
psmp_ubuntu_sysctl_content() {
    printf '%s\n' '# PASeasy Ubuntu 24.04 PSMP baseline v1' 'kernel.randomize_va_space = 2' 'fs.suid_dumpable = 0'
}
psmp_ubuntu_native() {
    [[ ${ID:-} = ubuntu && ${VERSION_ID:-} = 24.04 && $EUID = 0 ]] || return 1
    command -v getfacl >/dev/null || return 1
    local package file hash actual
    package=$(dpkg-query -W -f='${Status} ${Version}' carkpsmp) || return 1
    [[ $package =~ ^install\ ok\ installed\ (15\.[0-9]+(\.[0-9]+){1,2})$ ]] || return 1
    local version=${BASH_REMATCH[1]}
    while read -r hash file; do
        psmp_ubuntu_trusted "$file" || return 1
        [[ -s $file ]] || return 1
        # Content hashes are pinned only for vendor versions observed in qualification.
        # Other 15.x versions: native files must exist, be non-empty and pass the ownership/mode checks.
        [[ $version = 15.0.0.5 ]] || continue
        actual=$(sha256sum "$file" | cut -d' ' -f1) || return 1
        [[ $actual = "$hash" ]] || return 1
    done <<'NATIVE'
d548f57b38da4cb2ff3bb224720e95052e2e004d9bd7bd3272e2b9b1414c60bb /etc/ssh/sshd_config.d/20-CARKpsmp.conf
99bec6752c242fc65958f057f32265f174e0887f587f03c59d880ccbd7d79d1b /usr/lib/systemd/system/ssh.service.d/21-CARKpsmp-preload.conf
8485399ec434024d98a25c427ad9b323dcea7d7b986575ba8ccd9f01a56ea709 /usr/share/pam-configs/psmp
NATIVE
    # Do not replace native PAM/NSS configuration or the PSMP forwarding preloader.
    grep -Eq '^[^#]*pam_psmp\.so' /etc/pam.d/common-auth || return 1
    grep -Eq '^[^#]*pam_psmp\.so' /etc/pam.d/common-account || return 1
    grep -Eq '^passwd:.*[[:space:]]psmp([[:space:]]|$)' /etc/nsswitch.conf || return 1
    getent passwd PSMConnect >/dev/null || return 1
}
psmp_ubuntu_effective() {
    local effective setting aslr dumps
    /usr/sbin/sshd -t || return 1
    effective=$(/usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1) || return 1
    for setting in 'permitrootlogin without-password' 'pubkeyauthentication yes' 'authenticationmethods publickey' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'disableforwarding yes' 'permitemptypasswords no' 'x11forwarding no' 'permittunnel no' 'gatewayports no'; do
        grep -Fxq "$setting" <<< "$effective" || return 1
    done
    effective=$(/usr/sbin/sshd -T -C user=PSMConnect,host=localhost,addr=127.0.0.1) || return 1
    # Our baseline must not take forwarding away from PSMConnect (disableforwarding no). Whether TCP/stream-local
    # forwarding is allowed is the vendor's choice: 15.0 enables it, 15.2 ships it off until tunnelling is configured.
    for setting in 'usepam yes' 'kbdinteractiveauthentication yes' 'disableforwarding no'; do
        grep -Fxq "$setting" <<< "$effective" || return 1
    done
    aslr=$(sysctl -n kernel.randomize_va_space) || return 1
    dumps=$(sysctl -n fs.suid_dumpable) || return 1
    [[ $aslr = 2 && $dumps = 0 ]] || return 1
}
psmp_ubuntu_baseline_valid() {
    psmp_ubuntu_native || return 1
    psmp_ubuntu_trusted /etc/ssh/sshd_config.d/00-paeasy-psmp-ubuntu.conf || return 1
    psmp_ubuntu_trusted /etc/sysctl.d/60-paeasy-psmp-ubuntu.conf || return 1
    cmp -s /etc/ssh/sshd_config.d/00-paeasy-psmp-ubuntu.conf <(psmp_ubuntu_ssh_content) || return 1
    cmp -s /etc/sysctl.d/60-paeasy-psmp-ubuntu.conf <(psmp_ubuntu_sysctl_content) || return 1
    psmp_ubuntu_effective
}
# END PAEASY_UBUNTU24_PSMP_BASELINE

psmp_local_readiness() {
    # The vendor SysV aggregate can be active/exited with NO server or Vault
    # credentials. Verify the actual v15 daemon and its protected local inputs.
    local file pid mode daemon=false
    for file in /etc/opt/CARKpsmp/vault/psmpappuser.cred /etc/opt/CARKpsmp/vault/psmpgwuser.cred /etc/opt/CARKpsmp/vault/psmpappuser.cred.entropy /etc/opt/CARKpsmp/vault/psmpgwuser.cred.entropy; do
        [[ -f $file && ! -L $file && -s $file && $(stat -c %u "$file") = 0 ]] || return 1
        command -v getfacl >/dev/null || return 1
        getfacl -cp "$file" | awk '/^(user|group):[^:]+:/ {bad=1} /^mask:/ {bad=1} END {exit bad?1:0}' || return 1
        mode=$(stat -c %a "$file")
        [[ $((8#$mode & 07037)) = 0 ]] || return 1
        if (( 8#$mode & 040 )); then
            [[ $(stat -c %g "$file") = 0 ]] || return 1
        fi
    done
    [[ -s /etc/opt/CARKpsmp/vault/vault.ini ]] || return 1
    systemctl is-active --quiet psmpsrv || return 1
    while read -r pid; do
        if [[ $(readlink -f "/proc/$pid/exe" 2>/dev/null) = /opt/CARKpsmp/bin/psmpserver ]]; then daemon=true; break; fi
    done < <(pgrep -x psmpserver || true)
    $daemon
}

# BEGIN PAEASY_PTA_OS (independent Task/Verify native readback)
pta_os_preflight() {
    local identity os_id major minor architecture kernel package
    # Read data without evaluating shell from os-release. Ambiguous or malformed
    # identity is unsupported; a missing minor never implies a supported release.
    identity=$(LC_ALL=C timeout 5s awk '
      /^(ID|VERSION_ID)=/ {
        key=substr($0,1,index($0,"=")-1);value=substr($0,index($0,"=")+1)
        if(value ~ /^"[^"\\]*"$/)value=substr(value,2,length(value)-2)
        if(key=="ID"){id=value;ni++}else{version=value;nv++}
      }
      END{if(ni!=1||nv!=1)exit 3;printf "%s %s\n",id,version}
    ' /etc/os-release) || { echo 'Cannot read PTA OS identity' >&2; return 3; }
    [[ $identity =~ ^(rhel|rocky|almalinux|ol)\ ([89])\.([0-9]{1,3})$ ]] || { echo 'PTA OS identity/version is unsupported or malformed' >&2; return 3; }
    os_id=${BASH_REMATCH[1]};major=${BASH_REMATCH[2]};minor=${BASH_REMATCH[3]}
    [[ $minor = 0 || $minor != 0* ]] || { echo 'PTA OS minor version is ambiguous' >&2; return 3; }
    minor=$((10#$minor))
    if [[ $os_id = ol ]];then
        (( (major == 8 && minor >= 10) || (major == 9 && minor >= 6) )) || { echo 'PTA Oracle Linux requires RHCK8.10+ or RHCK9.6+' >&2; return 3; }
    else
        (( (major == 8 && minor >= 6) || (major == 9 && minor >= 2) )) || { echo 'PTA requires RHEL/Rocky/Alma8.6+ or9.2+' >&2; return 3; }
    fi
    architecture=$(LC_ALL=C timeout 5s uname -m) || { echo 'Cannot read PTA architecture' >&2; return 3; }
    [[ $architecture = x86_64 ]] || { echo 'PTA requires x86_64 architecture' >&2; return 3; }
    # Every exposed logical CPU must advertise AVX; no Lab resource override
    # authorizes a MongoDB-incompatible processor or a failed native query.
    LC_ALL=C timeout 5s awk '/^flags[[:space:]]*:/ {n++;if($0 !~ /[[:space:]]avx([[:space:]]|$)/)bad=1} END{exit (n==0||bad)?3:0}' /proc/cpuinfo || { echo 'PTA requires AVX on every exposed CPU' >&2; return 3; }
    if [[ $os_id = ol ]];then
        kernel=$(LC_ALL=C timeout 5s uname -r) || { echo 'Cannot read Oracle running kernel' >&2; return 3; }
        # Oracle documents RHCK4.18(EL8)/5.14(EL9); a non-UEK name alone
        # does not establish RHCK. Require ownership of this exact boot image.
        if [[ $major = 8 ]];then
            [[ $kernel =~ ^4\.18\.0-[0-9][0-9.]*\.el8(_[0-9]+)?\.x86_64$ ]] || { echo 'PTA Oracle running kernel is not recognized RHCK8' >&2; return 3; }
        else
            [[ $kernel =~ ^5\.14\.0-[0-9][0-9.]*\.el9(_[0-9]+)?\.x86_64$ ]] || { echo 'PTA Oracle running kernel is not recognized RHCK9' >&2; return 3; }
        fi
        package=$(LC_ALL=C timeout 5s rpm -qf --qf '%{NAME}|%{ARCH}|%{VERSION}-%{RELEASE}.%{ARCH}\n' "/boot/vmlinuz-$kernel") || { echo 'Cannot establish Oracle RHCK package ownership' >&2; return 3; }
        [[ $package = "kernel-core|x86_64|$kernel" ]] || { echo 'PTA Oracle RHCK package identity is unqualified' >&2; return 3; }
    fi
}
# END PAEASY_PTA_OS

# BEGIN PAEASY_PTA_FILESYSTEM (independent Task/Verify native readback)
pta_filesystem_preflight() {
    local directory mountpoint filesystem sizes capacity_bytes free_bytes
    # Only the documented non-CIS single-root layout is qualified here. A split
    # CIS/custom layout needs a separate total-volume/partition proof; do not
    # infer it by summing potentially overlapping mounts or completion markers.
    for directory in / /var /var/log /opt; do
        [[ -d $directory && ! -L $directory ]] || { echo 'PTA data directories must be real directories on the qualified root volume' >&2; return 3; }
        mountpoint=$(LC_ALL=C timeout 5s findmnt -n -o TARGET --target "$directory") || { echo 'PTA mount query failed or timed out' >&2; return 3; }
        [[ $mountpoint == / ]] || { echo 'PTA split/CIS/custom filesystem layout is not qualified by this recipe: vendor requires500GB total, /var>=200GB and /var/log>=100GB; an independent disjoint-volume layout proof is required' >&2; return 3; }
    done
    filesystem=$(LC_ALL=C timeout 5s findmnt -n -o FSTYPE --target /) || { echo 'PTA root filesystem query failed or timed out' >&2; return 3; }
    [[ $filesystem == xfs || $filesystem == ext4 ]] || { echo 'PTA filesystem type is outside this recipe qualification (xfs/ext4 single-root only)' >&2; return 3; }
    sizes=$(LC_ALL=C timeout 5s df -B1 --output=size,avail / | awk 'NR==2{if(NF!=2)exit 3;print $1,$2}END{if(NR!=2)exit 3}') || { echo 'PTA root capacity query failed or timed out' >&2; return 3; }
    read -r capacity_bytes free_bytes <<< "$sizes" || return 3
    [[ $capacity_bytes =~ ^[0-9]{1,15}$ && $free_bytes =~ ^[0-9]{1,15}$ ]] || { echo 'PTA root filesystem capacity is malformed' >&2; return 3; }
    # Vendor500GB decimal, measured on the actual guest filesystem, not merely
    # the hypervisor disk configuration. The supplied installer also needs2GiB
    # root free working space. No policy profile or Lab option bypasses this gate.
    (( capacity_bytes >= 500000000000 && free_bytes >= 2147483648 && free_bytes <= capacity_bytes )) || { echo 'PTA requires an actual root filesystem of at least500GB and2GiB free installer workspace; undersized experimental PTA is unqualified' >&2; return 3; }
}
# END PAEASY_PTA_FILESYSTEM

pta_tls_names() {
    tls_name=$(jq -r '.Settings.PTAName // empty' "$PAEASY_INPUT_JSON"); [[ -n $tls_name ]] || tls_name=$(hostname -f)
    tls_ip=$(jq -r '.Settings.Address // empty' "$PAEASY_INPUT_JSON")
    [[ $tls_name =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && $tls_name != *..* ]] || { echo 'PTAName must be a safe DNS name' >&2; return 9; }
    local dns_label
    local -a dns_labels
    IFS=. read -ra dns_labels <<< "$tls_name"
    for dns_label in "${dns_labels[@]}"; do [[ $dns_label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 9;done
    [[ $tls_ip =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] || { echo 'PTA TLS requires the actual target IPv4 Address' >&2; return 9; }
    ip -o -4 address show | awk '{sub(/\/.*/,"",$4);print $4}' | grep -Fxq "$tls_ip" || { echo 'PTA certificate IP must belong to this target' >&2; return 9; }
}
pta_tls_public_valid() {
    local leaf=$1 bundle=$2 ca_count
    [[ -s $leaf && -s $bundle && ! -L $leaf && ! -L $bundle ]] || return 1
    ! grep -q 'PRIVATE KEY' "$leaf" "$bundle" || return 1
    ca_count=$(grep -c '^-----BEGIN CERTIFICATE-----$' "$bundle")
    [[ $ca_count -gt 0 ]] || return 1
    # A trusted end-entity leaf is insufficient for native Vault syslog. Every
    # exported authority must explicitly permit CA signing, not just OpenSSL trust.
    openssl crl2pkcs7 -nocrl -certfile "$bundle" | openssl pkcs7 -print_certs -text -noout |
      awk -v n="$ca_count" '/X509v3 Basic Constraints:/ {b=1;next} b {if($0~/CA:TRUE/)ca++;b=0}
        /X509v3 Key Usage:/ {k=1;next} k {if($0~/Certificate Sign/)ku++;k=0}
        END {exit (ca==n && ku==n)?0:1}' || return 1
    openssl x509 -in "$leaf" -noout -checkend 86400 >/dev/null || return 1
    openssl verify -purpose sslserver -CAfile "$bundle" -verify_ip "$tls_ip" "$leaf" >/dev/null || return 1
    openssl verify -purpose sslclient -CAfile "$bundle" -verify_hostname "$tls_name" "$leaf" >/dev/null || return 1
}
pta_tls_live_valid() {
    local leaf=$1 bundle=$2 scratch=$3 expected current
    pta_tls_public_valid "$leaf" "$bundle" || return 1
    # -brief avoids recording TLS session master-key diagnostics.
    timeout 15 openssl s_client -brief -connect "$tls_ip:8443" -CAfile "$bundle" -verify_return_error -verify_ip "$tls_ip" </dev/null >/dev/null 2>&1 || return 1
    timeout 15 openssl s_client -brief -connect "$tls_ip:8443" -servername "$tls_name" -CAfile "$bundle" -verify_return_error -verify_hostname "$tls_name" </dev/null >/dev/null 2>&1 || return 1
    timeout 15 openssl s_client -connect "$tls_ip:8443" -servername "$tls_name" -showcerts </dev/null 2>/dev/null | openssl x509 -out "$scratch/served.pem" || return 1
    expected=$(openssl x509 -in "$leaf" -outform DER | sha256sum | cut -d' ' -f1)
    current=$(openssl x509 -in "$scratch/served.pem" -outform DER | sha256sum | cut -d' ' -f1)
    [[ $expected = "$current" ]] || return 1
    # The native utility extracts this public root and combined DB certificate.
    [[ -s /etc/opt/pta/ptadb/certificates/exportedRootCA.crt && -s /etc/opt/pta/ptadb/certificates/exportedPTA.pem ]] || return 1
    openssl verify -CAfile "$bundle" /etc/opt/pta/ptadb/certificates/exportedRootCA.crt >/dev/null || return 1
    openssl x509 -in /etc/opt/pta/ptadb/certificates/exportedPTA.pem -noout >/dev/null || return 1
    current=$(openssl x509 -in /etc/opt/pta/ptadb/certificates/exportedPTA.pem -outform DER | sha256sum | cut -d' ' -f1)
    [[ $expected = "$current" ]] || return 1
    if [[ $(jq -r '.DatabaseWasActive // false' "$root/stage/ConfigureTLS-intent.json" 2>/dev/null) = true ]] || systemctl is-active --quiet ptadb; then
        systemctl is-active --quiet ptadb || return 1
        timeout 15 openssl s_client -brief -connect 127.0.0.1:27017 -CAfile "$bundle" -verify_return_error -verify_ip "$tls_ip" -cert /etc/opt/pta/ptadb/certificates/exportedPTA.pem -key /etc/opt/pta/ptadb/certificates/exportedPTA.pem </dev/null >/dev/null 2>&1 || return 1
    fi
}

passed=false
case "$stage" in
  Preflight)
    media=$(jq -r '.Settings.MediaTarget' "$PAEASY_INPUT_JSON")
    if [[ $type = PTA ]]; then
      if [[ -f $media ]] && pta_os_preflight && pta_filesystem_preflight; then passed=true;fi
    else [[ -f "$media" ]] && passed=true;fi;;
  PrepareTools) command -v unzip >/dev/null && command -v zipinfo >/dev/null && passed=true;;
  Extract) [[ -d "$root/payload" && -n "$(ls -A "$root/payload")" ]] && passed=true;;
  Install)
    if [[ $type = PSMP ]]; then [[ -x /opt/CARKpsmp/bin/envmanager ]] && passed=true
    else [[ -s /etc/opt/pta/diamond-resources/version.properties ]] && passed=true;fi;;
  ConfigureTLS)
    if [[ $type = PTA ]] && pta_tls_names; then
      umask 077
      tls_scratch=$(mktemp -d /run/paeasy-tls-verify.XXXXXX)
      trap 'rm -rf "$tls_scratch"' EXIT
      tls_pfxsha=$(jq -r '.Settings.PTACertificatePfxSHA256 // empty' "$PAEASY_INPUT_JSON")
      tls_mode=PFX
      if [[ -z $tls_pfxsha ]];then
        tls_mode=LabCA
        [[ $(jq -r '.Settings.PolicyProfile' "$PAEASY_INPUT_JSON") = Lab && $(jq -r '.Settings.Options.generateLabCA // false' "$PAEASY_INPUT_JSON") = true ]] || exit 9
      fi
      tls_identity=$(printf '%s\n%s\n%s\n%s\n' "$tls_mode" "$tls_pfxsha" "$tls_ip" "$tls_name" | sha256sum | cut -d' ' -f1)
      if [[ $(jq -r .identity "$root/stage/ConfigureTLS-intent.json" 2>/dev/null) = "$tls_identity" ]] &&
         pta_tls_live_valid "$root/certificates/leaf.pem" "$root/certificates/trust-bundle.pem" "$tls_scratch"; then passed=true;fi
    fi;;
  Harden)
    if [[ $type = PSMP && $ID = ubuntu && $(jq -r '.Settings.ApplyHardening' "$PAEASY_INPUT_JSON") != false ]]; then
      psmp_ubuntu_baseline_valid && passed=true || true
    else [[ -f "$root/stage/$stage.json" ]] && passed=true;fi;;
  Register)
    if [[ $type = PSMP ]]; then psmp_local_readiness && passed=true || true
    else [[ -f "$root/stage/$stage.json" ]] && passed=true;fi;;
  Verify)
    if [[ $type = PSMP ]]; then
      if psmp_local_readiness; then
        if [[ $ID = ubuntu && $(jq -r '.Settings.ApplyHardening' "$PAEASY_INPUT_JSON") != false ]]; then psmp_ubuntu_baseline_valid && passed=true || true
        else passed=true;fi
      fi
    else
      host=$(jq -r '.Settings.Options.installerHost // .Settings.Address // "127.0.0.1"' "$PAEASY_INPUT_JSON")
      ca=$(jq -r '.Settings.Options.caFile // empty' "$PAEASY_INPUT_JSON")
      if [[ -z $ca ]];then if [[ -f "$root/certificates/trust-bundle.pem" ]];then ca="$root/certificates/trust-bundle.pem";else ca="$root/syslog-public.pem";fi;fi
      args=(--fail --silent --show-error --max-time 20)
      [[ -z $ca ]] || args+=(--cacert "$ca")
      [[ $(jq -r '.Settings.ValidateTLS' "$PAEASY_INPUT_JSON") != false ]] || args+=(--insecure)
      version=$(sed -n 's/^version_number=//p' /etc/opt/pta/diamond-resources/version.properties | tr -d '\r')
      if pta_os_preflight && pta_filesystem_preflight && [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ && -n $version ]] && systemctl is-active --quiet appmgr &&
        curl "${args[@]}" "https://${host}:8443/diamond/version" | grep -Fq "Diamond.version = \"$version\""; then passed=true;fi
    fi;;
  *) [[ -f "$root/stage/$stage.json" ]] && passed=true;;
esac
jq -nc --argjson ok "$passed" --arg m "$type $stage local readiness verified=$passed; authenticated functional operation NotTested" '{Passed:$ok,Message:$m,Evidence:[]}' | sed 's/^/PAEASY_RESULT:/'
