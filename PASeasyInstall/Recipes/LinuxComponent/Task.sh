#!/usr/bin/env bash
# CyberArk PSMP/PTA lab recipe. The controller is pure PowerShell; target uses native Linux tools.
set -Eeuo pipefail
export LC_ALL=C
: "${PAEASY_INPUT_JSON:?Missing restricted remote input envelope}"
command -v jq >/dev/null || { echo 'jq is required on Linux targets' >&2; exit 2; }
stage=$(jq -r '.Stage' "$PAEASY_INPUT_JSON")
type=$(jq -r '.Settings.Type' "$PAEASY_INPUT_JSON")
root=$(jq -r '.Settings.StageRoot' "$PAEASY_INPUT_JSON")
media=$(jq -r '.Settings.MediaTarget' "$PAEASY_INPUT_JSON")
vault=$(jq -r '.Settings.VaultAddress' "$PAEASY_INPUT_JSON")
user=$(jq -r '.Settings.VaultUser' "$PAEASY_INPUT_JSON")
secure=$(jq -r '.Settings.ValidateTLS' "$PAEASY_INPUT_JSON")
harden=$(jq -r '.Settings.ApplyHardening' "$PAEASY_INPUT_JSON")
password=$(jq -r '.VaultPassword // ""' "$PAEASY_INPUT_JSON")
[[ $vault =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || { echo 'Unsafe Vault host name' >&2; exit 2; }
options() { jq -r --arg k "$1" '.Settings.Options[$k] // empty' "$PAEASY_INPUT_JSON"; }
[[ $root =~ ^/opt/paeasyinstall/components/[a-z][a-z0-9_-]{0,39}$ ]] || { echo 'Unsafe component StageRoot' >&2; exit 2; }
[[ ! -L "$root" ]] || { echo 'Component StageRoot is a symlink' >&2; exit 2; }
. /etc/os-release
marker="$root/stage/$stage.json"
# Every pre-existing staging ancestor must remain root-owned and non-writable
# to other identities. Reject planted symlinks before chmod/write/extraction.
for directory in /opt /opt/paeasyinstall /opt/paeasyinstall/components "$root" "$root/stage" "$root/payload"; do
    [[ ! -L $directory ]] || { echo 'Linux staging directory symlink refused' >&2; exit 2; }
    if [[ -e $directory ]]; then
        [[ -d $directory && $(stat -c %u "$directory") = 0 ]] || { echo 'Linux staging directory must be owned by root' >&2; exit 2; }
        mode=$(stat -c %a "$directory")
        [[ $((8#$mode & 022)) = 0 ]] || { echo 'Linux staging directory must not be group/world writable' >&2; exit 2; }
    fi
done
[[ ! -L $marker ]] || { echo 'Linux stage marker symlink refused' >&2; exit 2; }
[[ ! -e $marker || $(stat -c %u "$marker") = 0 ]] || { echo 'Linux stage marker must be root owned' >&2; exit 2; }
mkdir -p "$root/stage"
chmod 700 "$root" "$root/stage" || true
success() {
    local msg="$1"
    printf '{"stage":"%s","time":"%s"}\n' "$stage" "$(date -u +%FT%TZ)" > "$marker"
    chmod 600 "$marker"
    jq -nc --arg m "$msg" '{Changed:true,Message:$m}' | sed 's/^/PAEASY_RESULT:/'
}
if [[ $type != 'PSMP' && $type != 'PTA' ]]; then echo "Unsupported Linux recipe type $type" >&2; exit 2; fi
# v15 SingleStepRunner uses this same signed vendor wizard and stdin contract.
# This explicit transport keeps SELinux enforcing when installer-webapp authentication
# is incompatible with the supplied ptaweb policy. The API variant remains separate.
paeasy_needrestart_guard() {
    # Ubuntu's needrestart restarts services after library upgrades (also those run by unattended-upgrades).
    # PASeasyInstall attempt units must never be restarted mid-stage; this rule only exempts them.
    [[ -d /etc/needrestart ]] || return 0
    install -d -m 755 /etc/needrestart/conf.d || return 0
    printf '%s\n' '# PASeasyInstall: never restart its own attempt units mid-stage.' '$nrconf{override_rc}{qr(^paeasy-.*)} = 0;' > /etc/needrestart/conf.d/90-paeasyinstall.conf || true
}
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

psmp_ubuntu_publish() {
    local destination=$1 content=$2 temporary
    psmp_ubuntu_trusted "$(dirname "$destination")" || return 1
    if [[ -e $destination || -L $destination ]]; then
        psmp_ubuntu_trusted "$destination" && cmp -s "$destination" <("$content")
        return
    fi
    temporary=$(mktemp "$(dirname "$destination")/.paeasy-psmp.XXXXXXXX") || return 1
    if ! "$content" > "$temporary" || ! chmod 644 "$temporary" || ! sync -f "$temporary" || ! ln "$temporary" "$destination"; then
        unlink "$temporary" || true
        return 1
    fi
    unlink "$temporary" || return 1
    sync -f "$(dirname "$destination")" || return 1
    psmp_ubuntu_trusted "$destination" && cmp -s "$destination" <("$content")
}
psmp_ubuntu_apply() {
    psmp_ubuntu_native || return 1
    # Refuse password-only controllers before activating root public-key-only SSH.
    psmp_ubuntu_trusted /root/.ssh/authorized_keys || return 1
    [[ -s /root/.ssh/authorized_keys ]] || return 1
    ssh-keygen -l -f /root/.ssh/authorized_keys >/dev/null 2>&1 || return 1
    psmp_ubuntu_publish /etc/ssh/sshd_config.d/00-paeasy-psmp-ubuntu.conf psmp_ubuntu_ssh_content || return 1
    psmp_ubuntu_publish /etc/sysctl.d/60-paeasy-psmp-ubuntu.conf psmp_ubuntu_sysctl_content || return 1
    sysctl -w kernel.randomize_va_space=2 fs.suid_dumpable=0 >/dev/null || return 1
    psmp_ubuntu_baseline_valid || return 1
    systemctl reload ssh || return 1
    psmp_ubuntu_baseline_valid
}

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

install_missing_rpms() {
    # Preserve the qualified image versions. dnf install of an already-installed
    # package can upgrade it and its dependency closure without a requested update.
    local package
    local missing=()
    for package in "$@"; do
        if ! rpm -q --quiet "$package"; then missing+=("$package"); fi
    done
    if (( ${#missing[@]} )); then dnf install -y "${missing[@]}"; fi
    for package in "$@"; do rpm -q --quiet "$package" || return 4; done
}

# Supplied v15 VaultIniParser: configured iff nondefault + nonzeroPORT + IPv4.
# This qualified subset fails closed for ambiguous Java-properties syntax.
pta_vault_state() {
    local file=${1:-/etc/opt/pta/diamond-resources/Vault.ini}
    [[ -f $file && ! -L $file && -r $file ]] || { echo Unknown; return; }
    awk '
      function trim(s){sub(/^[ \t]+/,"",s);sub(/[ \t]+$/,"",s);return s}
      function ipv4(s,a,n,i){n=split(s,a,".");if(n!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^(0|[1-9][0-9]?[0-9]?)$/ || a[i]+0>255)return 0;return 1}
      {sub(/\r$/,"");s=trim($0);if(s=="" || s~/^[#!;]/)next;
       if(s!~/^(ADDRESS|PORT)([ \t]*[=:]|[ \t]+)/)next;
       if(s~/\\/){bad=1;next};key=s;sub(/[ \t=:].*$/,"",key);sub(/^[^ \t=:]+[ \t]*[=:]?[ \t]*/,"",s);s=trim(s);
       if(key=="PORT"){ports++;if(s!~/^[+-]?[0-9]+$/ || length(s)>11 || s+0>2147483647 || s+0< -2147483648)bad=1;port=s+0}
       else{n=split(s,a,",");for(i=1;i<=n;i++){v=trim(a[i]);if(v=="11.22.33.444")defaults++;else if(ipv4(v))valid++;else invalid++}}}
      END{if(bad || ports!=1)print "Unknown";else if(defaults && !valid && !invalid && port==1858)print "Default";
          else if(!defaults && port!=0 && valid)print "Configured";else print "Partial"}' "$file"
}
pta_tls_assert_fresh() {
    [[ $(pta_vault_state) = Default ]] || { echo 'PTA certificate changes require untouched native default Vault configuration; configured, partial or unknown state refused' >&2; return 9; }
    # A lost/failed PAS step is also not a fresh installation, regardless of INI.
    [[ ! -e "$root/stage/Register.json" && ! -e "$root/stage/PTA-VendorCLI-PASConnectionConfigurationStep.json" ]] || { echo 'PTA already entered Vault configuration; certificate rotation needs the coordinated vendor repair workflow' >&2; return 9; }
    [[ -f /opt/pta/prepwiz/prepwiz.jar && -f /opt/pta/prepwiz/lib/common-0.1.jar ]] || return 9
    [[ $(sha256sum /opt/pta/prepwiz/prepwiz.jar | cut -d' ' -f1) = fb11d326645207da4d55609c50af3f2a4f7a8f0367b6d98770123bc5980ee1a8 &&
       $(sha256sum /opt/pta/prepwiz/lib/common-0.1.jar | cut -d' ' -f1) = 9d822919ed7cca2cb26808fc627d5b6bdddd5cb1c8cf0c102e0c4ba25d841263 ]] || { echo 'PTA TLS native utility artifacts differ from the qualified supplied v15 files' >&2; return 9; }
}
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
pta_configure_tls() {
    umask 077
    tls_changed=true
    pta_tls_assert_fresh
    pta_tls_names
    local lease=${PAEASY_INPUT_JSON%/*} attempt=${PAEASY_INPUT_JSON%/*} certdir="$root/certificates"
    attempt=${attempt##*/}
    [[ $lease =~ ^/run/paeasyinstall/attempts/[a-f0-9]{32}$ && ! -L $lease && $(stat -c %u "$lease") = 0 && $((8#$(stat -c %a "$lease") & 077)) = 0 ]] || { echo 'PTA TLS requires a durable ephemeral input lease' >&2; return 9; }
    local generate pfxdata certpass pfxsha policy mode identity checkpoint="$root/stage/ConfigureTLS-intent.json"
    jq -e '(.CertificatePassword // "") | type=="string" and (contains("\u0000")|not) and (contains("\r")|not) and (contains("\n")|not)' "$PAEASY_INPUT_JSON" >/dev/null || { echo 'Certificate password is incompatible with the native single-line protocol' >&2;return 9; }
    generate=$(options generateLabCA);pfxdata=$(jq -r '.CertificatePfxData // empty' "$PAEASY_INPUT_JSON");certpass=$(jq -r '.CertificatePassword // empty' "$PAEASY_INPUT_JSON")
    policy=$(jq -r '.Settings.PolicyProfile // empty' "$PAEASY_INPUT_JSON")
    if [[ -n $pfxdata ]]; then
        [[ $generate != true && ${#pfxdata} -le 43692 && -n $certpass && $certpass != *$'\n'* && $certpass != *$'\r'* ]] || { echo 'PFX mode needs a bounded container, nonempty single-line password and no Lab CA flag' >&2; return 9; }
        mode=PFX;pfxsha=$(jq -r '.Settings.PTACertificatePfxSHA256 // empty' "$PAEASY_INPUT_JSON")
        [[ $pfxsha =~ ^[A-Fa-f0-9]{64}$ ]] || return 9
    else
        [[ -z $(jq -r '.Settings.PTACertificatePfxSHA256 // empty' "$PAEASY_INPUT_JSON") ]] || { echo 'Frozen PFX asset has no resolved secret payload' >&2;return 9; }
        [[ $generate = true && $policy = Lab ]] || { echo 'Secure PTA requires operator PFX; disposable generated CA requires audited Lab GenerateLabCA override' >&2; return 9; }
        mode=LabCA;pfxsha=''
    fi
    identity=$(printf '%s\n%s\n%s\n%s\n' "$mode" "$pfxsha" "$tls_ip" "$tls_name" | sha256sum | cut -d' ' -f1)
    [[ ! -L $certdir && ! -L $checkpoint ]] || return 9
    if [[ -e $certdir ]]; then [[ -d $certdir && $(stat -c %u "$certdir") = 0 && $((8#$(stat -c %a "$certdir") & 022)) = 0 ]] || return 9;else mkdir -m 700 "$certdir";fi
    local leaf="$certdir/leaf.pem" bundle="$certdir/trust-bundle.pem"
    if [[ -e $checkpoint ]]; then
        [[ $(jq -r .identity "$checkpoint") = "$identity" ]] || { echo 'PTA TLS intent changed; reconcile target certificate state' >&2; return 9; }
        if pta_tls_live_valid "$leaf" "$bundle" "$lease"; then
            tls_leaf_hash=$(openssl x509 -in "$leaf" -outform DER | sha256sum | cut -d' ' -f1)
            tls_trust_bundle_hash=$(sha256sum "$bundle" | cut -d' ' -f1)
            tls_changed=false
            return 0
        fi
        echo 'Previous PTA TLS attempt is unresolved; native mutation will not be relaunched automatically' >&2;return 9
    fi
    for public in "$leaf" "$bundle"; do [[ ! -e $public && ! -L $public ]] || { echo 'Untracked PTA certificate artifacts require reconciliation' >&2;return 9; };done
    # No passwords or private material appear in this cleanup unit or its argv.
    local tls_cleanup_command="/bin/rm -f $lease/pta-tls-ca.key $lease/pta-tls-ca.pass $lease/pta-tls-input.pfx"
    # Trap embeds only the validated UUID path, not dynamically scoped locals.
    trap "$tls_cleanup_command" EXIT
    trap 'exit 143' TERM;trap 'exit 130' INT;trap 'exit 129' HUP
    # Decode/validate in /run first. A wrong PFX password must not create a
    # persistent mutation checkpoint and prevent a safe corrected retry.
    local final_leaf=$leaf final_bundle=$bundle
    leaf="$lease/pta-tls-leaf.pending.pem";bundle="$lease/pta-tls-chain.pending.pem"
    if [[ $mode = PFX ]]; then
        systemd-run --quiet --collect --unit="paeasy-tls-expiry-$attempt" --on-active=180 --timer-property=AccuracySec=1s /bin/rm -f "$lease/pta-tls-ca.key" "$lease/pta-tls-ca.pass" "$lease/pta-tls-input.pfx"
        printf '%s' "$pfxdata" | base64 -d > "$lease/pta-tls-input.pfx"
        [[ $(stat -c %s "$lease/pta-tls-input.pfx") -le 32768 && $(sha256sum "$lease/pta-tls-input.pfx" | cut -d' ' -f1) = "${pfxsha,,}" ]] || { echo 'PFX size/hash mismatch' >&2;return 9; }
        # fd3 supplies the PFX password; argv contains only /run paths.
        openssl pkcs12 -in "$lease/pta-tls-input.pfx" -passin fd:3 -clcerts -nokeys -out "$leaf" 3<<<"$certpass"
        openssl pkcs12 -in "$lease/pta-tls-input.pfx" -passin fd:3 -cacerts -nokeys -out "$bundle" 3<<<"$certpass"
        [[ $(grep -c 'BEGIN CERTIFICATE' "$leaf") = 1 ]] || { echo 'PFX must contain exactly one server identity and its complete CA chain' >&2;return 9; }
    else
        local old_csr_hash=''
        [[ ! -s /opt/pta/ca/pta_server.csr ]] || old_csr_hash=$(sha256sum /opt/pta/ca/pta_server.csr | cut -d' ' -f1)
        printf '%s\n' "$tls_name" 'PASeasyInstall disposable lab' Prague Prague CZ "$tls_name" "ip:$tls_ip,dns:$tls_name" | timeout 180 /opt/pta/utility/certificateSigningRequestGenerationUtil.sh
        [[ -s /opt/pta/ca/pta_server.csr && $(sha256sum /opt/pta/ca/pta_server.csr | cut -d' ' -f1) != "$old_csr_hash" ]] || { echo 'Native CSR artifact missing or unchanged; zero exit is insufficient' >&2;return 9; }
        systemd-run --quiet --collect --unit="paeasy-tls-expiry-$attempt" --on-active=180 --timer-property=AccuracySec=1s /bin/rm -f "$lease/pta-tls-ca.key" "$lease/pta-tls-ca.pass" "$lease/pta-tls-input.pfx"
        openssl rand -hex 32 > "$lease/pta-tls-ca.pass"
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc -pass "file:$lease/pta-tls-ca.pass" -out "$lease/pta-tls-ca.key" 2>/dev/null
        openssl req -new -x509 -sha256 -days 365 -key "$lease/pta-tls-ca.key" -passin "file:$lease/pta-tls-ca.pass" -subj '/CN=PASeasyInstall transient lab CA/O=PASeasyInstall disposable lab/C=CZ' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign,cRLSign' -out "$bundle"
        printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:%s,DNS:%s\n' "$tls_ip" "$tls_name" > "$lease/pta-tls-public.ext"
        openssl x509 -req -in /opt/pta/ca/pta_server.csr -CA "$bundle" -CAkey "$lease/pta-tls-ca.key" -passin "file:$lease/pta-tls-ca.pass" -set_serial "0x$(openssl rand -hex 16)" -days 365 -sha256 -extfile "$lease/pta-tls-public.ext" -out "$leaf"
        # Signing authority is destroyed before native installation/restart.
        rm -f "$lease/pta-tls-ca.key" "$lease/pta-tls-ca.pass"
    fi
    chmod 600 "$leaf" "$bundle"
    pta_tls_public_valid "$leaf" "$bundle" || { echo 'Certificate chain, identity or TLS-purpose validation failed' >&2;return 9; }
    local ini_hash db_was_active=false
    ini_hash=$(sha256sum /etc/opt/pta/diamond-resources/Vault.ini | cut -d' ' -f1)
    systemctl is-active --quiet ptadb && db_was_active=true || true
    install -m 600 "$leaf" "$final_leaf";install -m 600 "$bundle" "$final_bundle"
    leaf=$final_leaf;bundle=$final_bundle
    jq -nc --arg id "$identity" --argjson db "$db_was_active" '{identity:$id,state:"Applying",DatabaseWasActive:$db}' > "$checkpoint.tmp";chmod 600 "$checkpoint.tmp";mv "$checkpoint.tmp" "$checkpoint"
    if [[ $mode = PFX ]]; then
        printf '%s\n%s\n' "$lease/pta-tls-input.pfx" "$certpass" | timeout 300 /opt/pta/utility/sslCertificateInstallationUtil.sh
    else
        printf '%s\ny\n%s\nn\n' "$leaf" "$bundle" | timeout 300 /opt/pta/utility/sslCertificateInstallationUtil.sh
    fi
    [[ $(sha256sum /etc/opt/pta/diamond-resources/Vault.ini | cut -d' ' -f1) = "$ini_hash" ]] || { echo 'Native TLS utility changed Vault configuration unexpectedly' >&2;return 9; }
    if $db_was_active; then
        # Fresh installer mode restarts only the web service. A database that
        # was already running must reload the new native TLS files as well.
        service ptadb restart
        systemctl is-active --quiet ptadb || { echo 'Previously active native database did not recover' >&2;return 9; }
    fi
    local tls_deadline=$((SECONDS+180))
    until pta_tls_live_valid "$leaf" "$bundle" "$lease"; do
        (( SECONDS < tls_deadline )) || { echo 'PTA new served certificate/DB artifacts not independently verified within readiness window' >&2;return 9; }
        sleep 2
    done
    tls_leaf_hash=$(openssl x509 -in "$leaf" -outform DER | sha256sum | cut -d' ' -f1)
    tls_trust_bundle_hash=$(sha256sum "$bundle" | cut -d' ' -f1)
    jq -nc --arg id "$identity" --arg hash "$tls_leaf_hash" --argjson db "$db_was_active" '{identity:$id,state:"Verified",Hash:$hash,DatabaseWasActive:$db}' > "$checkpoint"
    eval "$tls_cleanup_command";trap - EXIT TERM INT HUP
}

pta_export_public_listener_certificate() {
    local destination="$root/syslog-public.pem" temporary="$root/syslog-public.pem.pending.$$"
    [[ ! -L $destination ]] || { echo 'PTA public certificate symlink refused' >&2; return 6; }
    (umask 077; set -o noclobber; : > "$temporary") || return 6
    if ! timeout 15 openssl s_client -connect 127.0.0.1:514 -showcerts </dev/null 2>/dev/null | openssl x509 -out "$temporary"; then
        rm -f "$temporary"; echo 'Could not capture live PTA TLS listener public certificate' >&2; return 6
    fi
    if ! openssl x509 -in "$temporary" -noout -checkend 86400 >/dev/null; then rm -f "$temporary"; return 6; fi
    if [[ -e $destination ]]; then
        local old new
        old=$(openssl x509 -in "$destination" -outform DER | sha256sum | cut -d' ' -f1)
        new=$(openssl x509 -in "$temporary" -outform DER | sha256sum | cut -d' ' -f1)
        rm -f "$temporary"
        [[ $old = "$new" ]] || { echo 'PTA listener certificate changed; explicit trust reconciliation required' >&2; return 6; }
    else
        chmod 600 "$temporary"; mv "$temporary" "$destination"
    fi
}

pta_vendor_cli() {
    [[ -f /opt/pta/prepwiz/run.sh && -f /opt/pta/prepwiz/prepwiz.jar ]] || { echo 'Native PTA wizard is missing' >&2; return 6; }
    [[ -n $(options vaultTimezone) ]] || { echo 'PTA Options.vaultTimezone is required' >&2; return 6; }
    local portal
    portal=$(options pvwaHost)
    [[ $portal =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || { echo "Safe PTA Options.pvwaHost is required" >&2; return 6; }
    jq -e '(.Settings.Options.vaultDrAddresses // []) | type=="array" and all(.[]; type=="string" and test("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$"))' "$PAEASY_INPUT_JSON" >/dev/null || { echo "Invalid PTA DR address list" >&2; return 6; }
    local identity step checkpoint state result
    identity=$(jq -cS '.Settings' "$PAEASY_INPUT_JSON" | sha256sum | cut -d' ' -f1)
    local steps=(StartDatabaseStep GeneratedComponentPasswordsStep PASConnectionConfigurationStep ActivitiesReportStep BaselinesCreationStep InventoryReportStep AuthorizedSourceHostsConfigurationStep DiamondWebAppDeploymentStep StartPTAStep)
    for step in "${steps[@]}"; do
        checkpoint="$root/stage/PTA-VendorCLI-$step.json"
        [[ ! -L $checkpoint ]] || { echo 'PTA checkpoint symlink refused' >&2; return 6; }
        if [[ -e $checkpoint ]]; then
            state=$(jq -r --arg id "$identity" 'if .identity==$id then .state else "ConfigurationChanged" end' "$checkpoint")
            [[ $state = Succeeded ]] && { echo "Native PTA step already completed: $step"; continue; }
            echo "Native PTA step $step has $state outcome; reconcile vendor state before retry" >&2
            return 6
        fi
        (set -o noclobber; jq -nc --arg step "$step" --arg id "$identity" '{step:$step,identity:$id,state:"Running"}' > "$checkpoint") || return 6
        chmod 600 "$checkpoint"
        # SecretValue in the vendor commandlet protects this password in its logs.
        # Only the PAS step receives it, over stdin; no secret JSON is retained here.
        result=0
        jq -c --arg step "$step" '{stepName:$step,inputParameters:(
          if $step=="PASConnectionConfigurationStep" then {
            runOptionalStep:"y",vaultAddress:.Settings.VaultAddress,vaultPort:(.Settings.Options.vaultPort // "1858"),
            vaultAdminCredentialsUsername:.Settings.VaultUser,vaultCredentialsPassword:.VaultPassword,
            vaultTimezone:.Settings.Options.vaultTimezone,vaultClusterDistributedEnvironmentQuestion:"n",
            vaultDrConfigurationQuestion:(if (.Settings.Options.vaultDrAddresses // [] | length)>0 then "y" else "n" end),
            vaultDrIpsConfiguration:(.Settings.Options.vaultDrAddresses // [] | join(",")),
            pvwaConnectivity:"y",pvwaTrustConnection:"n",pvwaHost:.Settings.Options.pvwaHost,
            pvwaApplicationContext:(.Settings.Options.pvwaAppContext // "PasswordVault"),pvwaHttpsEnabled:"y",pvwaHttpsPort:"443"
          } elif $step=="ActivitiesReportStep" then {runOptionalStep:"y",num_of_previous_days_for_activities_report:(.Settings.Options.vaultActivityDays // 180 | tostring)}
          elif $step=="AuthorizedSourceHostsConfigurationStep" then {syslogInboundOptional:"n",authorizedSourceHostsConfiguration:"all"}
          elif $step=="BaselinesCreationStep" or $step=="InventoryReportStep" or $step=="StartPTAStep" then {runOptionalStep:"y"}
          else {} end)}' "$PAEASY_INPUT_JSON" | bash /opt/pta/prepwiz/run.sh --inputStepData || result=$?
        if [[ $result = 0 && $step = DiamondWebAppDeploymentStep ]]; then
            # The v15 vendor helper returns 0 even when its confined Java caller
            # cannot copy ROOT.war. Perform its exact install operation as this
            # root runner, then prove bytes/context without editing vendor logs.
            [[ ! -L /opt/pta/webapps/ROOT.war ]] || result=6
            if [[ $result = 0 && ! -f /opt/pta/webapps/ROOT.war ]]; then
                install -m0700 -o ptaweb -g ptaweb /opt/pta/utility/internal/DiamondWebApp.war /opt/pta/webapps/ROOT.war || result=$?
                [[ $result != 0 ]] || restorecon /opt/pta/webapps/ROOT.war || result=$?
            fi
            if [[ $result = 0 ]]; then
                cmp -s /opt/pta/utility/internal/DiamondWebApp.war /opt/pta/webapps/ROOT.war || result=6
            fi
        fi
        state=Failed; [[ $result = 0 ]] && state=Succeeded
        jq -nc --arg step "$step" --arg id "$identity" --arg state "$state" --argjson code "$result" \
          '{step:$step,identity:$id,state:$state,exitCode:$code}' > "$checkpoint.tmp"
        chmod 600 "$checkpoint.tmp"; mv -f "$checkpoint.tmp" "$checkpoint"
        [[ $result = 0 ]] || { echo "Native PTA step failed: $step (exit $result); no automatic retry" >&2; return "$result"; }
        echo "Native PTA step completed: $step"
    done
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

pta_cpu_preflight() {
    local cpu_count
    cpu_count=$(nproc) || { echo 'Cannot inspect PTA CPU count' >&2; return 3; }
    [[ $cpu_count =~ ^[1-9][0-9]{0,6}$ ]] || { echo 'Invalid PTA CPU count' >&2; return 3; }
    if (( cpu_count < 8 )); then
        jq -e '.Settings.Options.allowUndersizedCPU == true and .Settings.PolicyProfile == "Lab"' "$PAEASY_INPUT_JSON" >/dev/null || {
            echo 'Supplied PTA P001 diagnostic requires at least 8 CPU cores; explicit audited Lab PTA.AllowUndersizedCPU override required' >&2
            return 3
        }
        echo "LAB DEVIATION: PTA CPU ${cpu_count} below vendor P001 minimum 8; resource qualification unavailable"
    fi
}

# Recheck before every PTA phase (including resumed credential-bearing work).
# Function definitions above perform no product or credential mutation.
if [[ $type = PTA ]];then pta_os_preflight || exit 3;fi

case "$stage" in
  Preflight)
    [[ -f "$media" ]] || { echo "Media missing: $media" >&2; exit 3; }
    paeasy_needrestart_guard
    if ! command -v unzip >/dev/null; then
      # unzip is an installer prerequisite missing from minimal/cloud images: install it from the OS repositories.
      if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 timeout 600 apt-get -q update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 timeout 600 apt-get -q install -y --no-upgrade unzip >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null; then
        timeout 600 dnf -q install -y unzip >/dev/null 2>&1 || true
      fi
      command -v unzip >/dev/null || { echo 'unzip required and could not be installed from the OS repositories' >&2; exit 3; }
      echo 'Installed missing prerequisite: unzip'
    fi
    if [[ $type = PSMP && $ID = ubuntu && ( $VERSION_ID = 22.04 || $VERSION_ID = 24.04 ) ]]; then
      command -v dpkg >/dev/null || exit 3
    elif [[ ( $ID = rhel || $ID = rocky || ( $type = PTA && ( $ID = almalinux || $ID = ol ) ) ) && ( ${VERSION_ID%%.*} = 8 || ${VERSION_ID%%.*} = 9 ) ]]; then
      command -v rpm >/dev/null || exit 3
    else echo 'Selected OS/media combination is unqualified (PSMP Ubuntu22/24 or RHEL/Rocky8/9; PTA EL8/9 vendor allowlist)' >&2; exit 3; fi
    if [[ $type = 'PTA' ]]; then
      pta_os_preflight || exit 3
      pta_filesystem_preflight || exit 3
      pta_cpu_preflight
      command -v curl >/dev/null || exit 3
      memory_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
      if [[ $memory_kb -lt 16000000 ]]; then
        [[ $(options allowUndersizedMemory) = true && $(jq -r '.Settings.PolicyProfile // empty' "$PAEASY_INPUT_JSON") = Lab ]] || { echo 'Supplied PTA P095 diagnostic requires at least 16000000 kB RAM; explicit audited Lab AllowUndersizedPTA override required' >&2; exit 3; }
        echo "LAB DEVIATION: PTA memory ${memory_kb}kB below vendor P095 threshold 16000000 kB; resource qualification unavailable"
      fi
    fi
    success "$type Linux prerequisites verified";;
  Extract)
    mkdir -p "$root/payload"
    # Validate names and Unix file types before any extraction; reject traversal and symlinks.
    while IFS= read -r entry; do
      [[ $entry != /* && $entry != *\\* && $entry != *$'\r'* ]] || { echo 'Unsafe archive path' >&2; exit 4; }
      case "/$entry/" in */../*|*/./*) echo 'Unsafe archive traversal' >&2; exit 4;; esac
    done < <(unzip -Z -1 "$media")
    zipinfo -l "$media" | awk '$1 ~ /^l/ {bad=1} END {exit bad}' || { echo 'Archive symlinks unsupported' >&2; exit 4; }
    unzip -n -q "$media" -d "$root/payload"
    [[ $(find "$root/payload" -type f | wc -l) -gt 0 ]] || exit 4
    success "$type installer media extracted";;
  Prerequisites)
    if [[ $type = 'PSMP' ]]; then
      command -v systemctl >/dev/null || exit 4
      if [[ $ID = ubuntu ]]; then
        paeasy_needrestart_guard
        # Install only what is missing: upgrading installed packages here (e.g. libc6) makes needrestart restart
        # services, which can include this very attempt. OS updates are the operator's decision.
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -o DPkg::Lock::Timeout=180 install -y --no-upgrade libssh-4 libpam-runtime openssh-server acl
      else
        command -v dnf >/dev/null || exit 4
        install_missing_rpms policycoreutils-python-utils gnupg2 openssh-clients openssh-server acl
        # The PSMP package ships CyberArk's public RPM key. Unless the operator pins another one, accept only the
        # reviewed CyberArk Software Ltd. signing key (same key in the 15.x RHEL 8 and RHEL 9 packages).
        key="$root/payload/RPM-GPG-KEY-CyberArk"; fingerprint=$(options signingKeyFingerprint)
        [[ -n $fingerprint ]] || fingerprint=97A2859B95D5F078AFC87C64A83D2D8A08BEAA44
        [[ -f $key && $fingerprint =~ ^[A-Fa-f0-9]{40}$ ]] || { echo 'Reviewed PSMP RPM signingKeyFingerprint required' >&2; exit 4; }
        observed=$(gpg --batch --with-colons --show-keys "$key" 2>/dev/null | awk -F: '$1=="fpr" {print $10;exit}')
        [[ ${observed^^} = ${fingerprint^^} ]] || { echo 'PSMP signing key fingerprint mismatch' >&2; exit 4; }
        rpm --import "$key"
        mapfile -d '' packages < <(find "$root/payload" -name 'CARKpsmp*.rpm' -type f -print0)
        [[ ${#packages[@]} -eq 1 ]] || exit 4
        rpm --checksig "${packages[0]}"
      fi
    else
      [[ -r /etc/os-release ]] || exit 4
      . /etc/os-release
      [[ ${VERSION_ID%%.*} = 8 || ${VERSION_ID%%.*} = 9 ]] || { echo 'PTA recipe qualified only for EL8/EL9 family' >&2; exit 4; }
      # Do not run 'dnf update -y' without explicit approval: this changes the entire appliance.
      command -v dnf >/dev/null || exit 4
      # Exact vendor prerequisites; no full distribution upgrade and no GPG/SELinux bypass.
      install_missing_rpms tar sshpass iproute glibc-common logrotate gnupg2 initscripts-service openssl
      key=$(jq -r '.Settings.SigningKeyTarget // empty' "$PAEASY_INPUT_JSON")
      fingerprint=$(options signingKeyFingerprint)
      [[ -f $key && $fingerprint =~ ^[A-Fa-f0-9]{40}$ ]] || { echo 'PTA signing key target and reviewed fingerprint required' >&2; exit 4; }
      observed=$(gpg --batch --with-colons --show-keys "$key" 2>/dev/null | awk -F: '$1=="fpr" {print $10;exit}')
      [[ ${observed^^} = ${fingerprint^^} ]] || { echo 'PTA signing key fingerprint mismatch' >&2; exit 4; }
      rpm --import "$key"
      mapfile -d '' policies < <(find "$root/payload" -name "pta-selinux-policy-*.el${VERSION_ID%%.*}.noarch.rpm" -type f -print0)
      [[ ${#policies[@]} -eq 1 ]] || { echo 'Exactly one platform SELinux policy RPM required' >&2; exit 4; }
      rpm --checksig "${policies[0]}"
    fi
    success "$type target prerequisites checked";;
  Install)
    if [[ $type = 'PSMP' ]]; then
      [[ $(options acceptEula) = true ]] || { echo 'Options.acceptEula=true required after reviewing supplied EULA' >&2; exit 5; }
      # UpdateCredFile/ADBridgeUpdateCredFile=Yes: a rebuilt server re-registers even though its PSMP users already
      # exist in the Vault (no effect on a first installation).
      [[ ! -e /var/tmp/psmpparms && ! -L /var/tmp/psmpparms ]] || { echo 'Existing psmpparms requires reconciliation' >&2; exit 5; }
      umask 077
      if [[ $ID = ubuntu ]]; then
        (set -o noclobber; printf 'AcceptCyberArkEULA=Yes\nCreateVaultEnvironment=No\nUpdateCredFile=Yes\nADBridgeUpdateCredFile=Yes\n' > /var/tmp/psmpparms)
      else
        native_hardening=Yes; [[ $harden != false ]] || native_hardening=No
        (set -o noclobber; printf '[Main]\nAcceptCyberArkEULA=Yes\nHardening=%s\nHardeningDoDIN=No\nUpdateCredFile=Yes\nADBridgeUpdateCredFile=Yes\n' "$native_hardening" > /var/tmp/psmpparms)
      fi
      trap 'rm -f /var/tmp/psmpparms' EXIT
      if [[ $ID = ubuntu ]]; then
        mapfile -d '' packages < <(find "$root/payload" -name 'CARKpsmp*.deb' -type f -print0)
        [[ ${#packages[@]} -eq 1 ]] || { echo 'Expected exactly one CARKpsmp DEB' >&2; exit 5; }
        [[ $(dpkg-deb -f "${packages[0]}" Package) = carkpsmp ]] || exit 5
        ! dpkg-query -W -f='${Status}' carkpsmp 2>/dev/null | grep -q 'install ok installed' || { echo 'Existing PSMP installation requires reconciliation' >&2; exit 5; }
        DEBIAN_FRONTEND=noninteractive dpkg -i "${packages[0]}"
        [[ $(dpkg-query -W -f='${Status}' carkpsmp) = 'install ok installed' ]] || exit 5
      else
        mapfile -d '' packages < <(find "$root/payload" -name 'CARKpsmp*.rpm' -type f -print0)
        [[ ${#packages[@]} -eq 1 ]] || { echo 'Expected exactly one CARKpsmp RPM' >&2; exit 5; }
        ! rpm -q CARKpsmp >/dev/null 2>&1 || { echo 'Existing PSMP installation requires reconciliation' >&2; exit 5; }
        rpm -ivh "${packages[0]}"
      fi
      rm -f /var/tmp/psmpparms; trap - EXIT
      install -d -m 700 /etc/opt/CARKpsmp/vault
      if [[ ! -f /etc/opt/CARKpsmp/vault/vault.ini ]]; then
        cp /opt/CARKpsmp/doc/examples/vault.ini /etc/opt/CARKpsmp/vault/vault.ini
      fi
      [[ -x /opt/CARKpsmp/bin/envmanager ]] || exit 5
    else
      [[ ! -s /etc/opt/pta/diamond-resources/version.properties ]] || { echo 'PTA already installed; independently reconcile instead of rerunning vendor installer' >&2; exit 5; }
      mapfile -d '' installers < <(find "$root/payload" -name pta_installer.sh -type f -print0)
      [[ ${#installers[@]} -eq 1 ]] || { echo 'Expected exactly one PTA installer script' >&2; exit 5; }
      chmod 750 "${installers[0]}"
      # Vendor script accepts EULA confirmation from stdin; never silently disable SELinux.
      printf 'Y\n' | "${installers[0]}"
      [[ -s /etc/opt/pta/diamond-resources/version.properties ]] && grep -Eq '^version_number=15\.0\.0$' /etc/opt/pta/diamond-resources/version.properties && grep -Fq 'PTA deployed successfully.' /tmp/pta_upgrade.log || { echo 'PTA version/completion evidence missing; inspect vendor log' >&2; exit 5; }
    fi
    success "$type installer completed";;
  ConfigureTLS)
    [[ $type = PTA ]] || { echo 'ConfigureTLS applies only to PTA' >&2; exit 9; }
    pta_configure_tls
    printf '{"stage":"ConfigureTLS","time":"%s"}\n' "$(date -u +%FT%TZ)" > "$marker";chmod 600 "$marker"
    jq -nc --arg hash "$tls_leaf_hash" --arg trust "$tls_trust_bundle_hash" --argjson changed "$tls_changed" '{Changed:$changed,Message:"PTA native TLS configured and verified; fresh database startup is checked during native registration",Data:{Hash:$hash,TrustBundleSHA256:$trust}}' | sed 's/^/PAEASY_RESULT:/'
    ;;
  Register)
    [[ -n "$password" ]] || { echo 'Vault admin secret required' >&2; exit 6; }
    if [[ $type = 'PSMP' ]]; then
      if [[ $ID = ubuntu ]]; then
        # Register precedes Harden: validate native inputs, not future baseline files.
        psmp_ubuntu_native || { echo 'Ubuntu PSMP native prerequisites failed before registration' >&2; exit 6; }
        id_suffix=$(hostname -s)
        requested_id=$(options serverId)
        [[ -z $requested_id || $requested_id = "$id_suffix" ]] || { echo 'Ubuntu vendor setup derives PSMP server ID from hostname; Options.serverId must match hostname' >&2; exit 6; }
      else id_suffix=$(options serverId); [[ -n $id_suffix ]] || id_suffix=$(hostname -s); fi
      [[ $id_suffix =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || { echo 'Options.serverId must be set to safe unique ID' >&2; exit 6; }
      cred="$(dirname "$PAEASY_INPUT_JSON")/registration.cred"
      trap 'shred -u "$cred" "$cred.entropy" 2>/dev/null || rm -f "$cred" "$cred.entropy"' EXIT
      umask 077
      [[ $password != *$'\n'* && $password != *$'\r'* && $user != *$'\n'* && $user != *$'\r'* ]] || { echo 'Newline in interactive credential input is unsupported' >&2; exit 6; }
      # v15 native interactive mode accepts stdin. Never pass the Vault password in argv.
      # Restrict encrypted credentials to root + hostname + machine GUID + entropy file.
      printf '%s\n' "$user" "$password" No None No '' '' root No Yes Yes No Yes No '' '' No | \
        timeout 60 /opt/CARKpsmp/bin/createcredfile "$cred" >/dev/null
      [[ -s $cred && -s $cred.entropy ]] || { echo 'Encrypted credential/entropy file missing' >&2; exit 6; }
      chmod 600 "$cred" "$cred.entropy"
      sed -i -E "s/^ADDRESS=.*/ADDRESS=${vault}/" /etc/opt/CARKpsmp/vault/vault.ini
      register_rc=0
      if [[ $ID = ubuntu ]]; then
        DEBIAN_FRONTEND=noninteractive /opt/CARKpsmp/bin/psmp_setup.sh --finalize --credfile "$cred" || register_rc=$?
      else
        /opt/CARKpsmp/bin/envmanager CreateEnv --AcceptEULA Y --CredFile "$cred" \
          --PSMPServerId "PSMPServer_${id_suffix}" --PSMPAppUser "PSMPApp_${id_suffix}" --PSMPGWUser "PSMPGW_${id_suffix}" \
          --ICUFolder /opt/CARKpsmp/bin/ --VaultEnvPath /etc/opt/CARKpsmp/vault/ || register_rc=$?
      fi
      if (( register_rc )); then
        # The most common cause in a new lab: PSMP was started before any PVWA was installed for this Vault.
        if grep -q "ITATS020E Safe Name PVWAConfig" /var/opt/CARKpsmp/temp/EnvManager.log 2>/dev/null; then
          echo 'PSMP registration failed: the Vault has no PVWA environment yet (Safe PVWAConfig is missing). Install PVWA first, then run this step again with Resume-PASRun -RetryStep.' >&2
        fi
        exit "$register_rc"
      fi
      shred -u "$cred" "$cred.entropy" 2>/dev/null || rm -f "$cred" "$cred.entropy"
      trap - EXIT
      systemctl enable --now psmpsrv
      for readiness_wait in $(seq 1 30); do psmp_local_readiness && break; sleep 1; done
      psmp_local_readiness || { echo "PSMP registration returned without protected app/GW credentials and an actual daemon" >&2; exit 6; }
    else
      transport=$(options ptaConfigurationTransport); [[ -n $transport ]] || transport=VendorCLI
      if [[ $transport = VendorCLI ]]; then
        pta_vendor_cli
        pta_export_public_listener_certificate
        success "PTA native vendor CLI registration finished"
        exit 0
      fi
      [[ $transport = API ]] || { echo "Unsupported PTA configuration transport" >&2; exit 6; }
      host=$(options installerHost); [[ -n "$host" ]] || host=$(jq -r '.Settings.Address // "127.0.0.1"' "$PAEASY_INPUT_JSON")
      [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || { echo 'Unsafe PTA installer hostname' >&2; exit 6; }
      local_ips=$( { printf '127.0.0.1\n'; ip -o -4 address show | awk '{print $4}' | cut -d/ -f1; } )
      mapfile -t installer_ips < <(getent ahostsv4 "$host" | awk '{print $1}' | sort -u)
      [[ ${#installer_ips[@]} -gt 0 ]] || { echo 'PTA installer hostname does not resolve' >&2; exit 6; }
      for address in "${installer_ips[@]}"; do
        grep -Fxq "$address" <<< "$local_ips" || { echo 'PTA local OS credential may only be sent to an installer endpoint on this target' >&2; exit 6; }
      done
      portal=$(options pvwaHost); [[ -n "$portal" ]] || { echo 'PTA needs Options.pvwaHost' >&2; exit 6; }
      local_password=$(options installerPasswordFile)
      attempt_dir=$(dirname "$PAEASY_INPUT_JSON")
      tokenfile="$attempt_dir/pta-token.json"; bodyfile="$attempt_dir/pta-login.body"
      payloadfile="$attempt_dir/pta-install.body"; headerfile="$attempt_dir/pta-auth.conf"
      touch "$tokenfile" "$bodyfile" "$payloadfile" "$headerfile"
      trap 'shred -u "$tokenfile" "$bodyfile" "$payloadfile" "$headerfile" 2>/dev/null || rm -f "$tokenfile" "$bodyfile" "$payloadfile" "$headerfile"' EXIT
      chmod 600 "$tokenfile" "$bodyfile" "$payloadfile" "$headerfile"
      curl_args=(--fail --silent --show-error --max-time 30)
      [[ $secure = false ]] && curl_args+=(--insecure)
      ca=$(options caFile); [[ -n "$ca" ]] && curl_args+=(--cacert "$ca")
      # Credentials enter curl via protected config file, not command-line arguments.
      installeruser=$(options installerUser); [[ -n "$installeruser" ]] || installeruser=root
      if jq -e '.InstallerPassword? | type=="string" and length>0' "$PAEASY_INPUT_JSON" >/dev/null; then
        jq -j --arg u "$installeruser" '"username="+($u|@uri)+"&password="+(.InstallerPassword|@uri)' "$PAEASY_INPUT_JSON" > "$bodyfile"
      else
        [[ -n $local_password && -f $local_password && ! -L $local_password && $(stat -c %u "$local_password") = 0 ]] || { echo 'PTAInstallerPassword secret or root-owned password provider file required' >&2; exit 6; }
        mode=$(stat -c %a "$local_password"); [[ $((8#$mode & 077)) = 0 ]] || { echo 'PTA password provider file must not be group/world accessible' >&2; exit 6; }
        jq -nj --arg u "$installeruser" --rawfile p "$local_password" '"username="+($u|@uri)+"&password="+($p|rtrimstr("\n")|@uri)' > "$bodyfile"
      fi
      curl "${curl_args[@]}" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-binary "@$bodyfile" "https://${host}:8443/installer/api/getauthtoken" > "$tokenfile"
      token=$(jq -r '.Authorization // empty' "$tokenfile"); [[ -n "$token" ]] || exit 6
      [[ $token != *$'\n'* && $token != *$'\r'* && $token != *\"* && $token != *\\* ]] || exit 6
      printf 'header = "Authorization: Bearer %s"\n' "$token" > "$headerfile"
      status=$(curl "${curl_args[@]}" --config "$headerfile" "https://${host}:8443/installer/api/installation" | jq -r '.status // empty')
      [[ $status != 'FAILED' ]] || { echo 'PTA previous installation FAILED; manual recovery required' >&2; exit 6; }
      if [[ $status = NOT_STARTED ]]; then
        [[ -n $(options vaultTimezone) ]] || { echo 'PTA Options.vaultTimezone is required by vendor API' >&2; exit 6; }
        jq '{vault:{ip:.Settings.VaultAddress,port:(.Settings.Options.vaultPort // "1858"),timezone:.Settings.Options.vaultTimezone,adminUser:.Settings.VaultUser,adminPassword:.VaultPassword,daysActivity:(.Settings.Options.vaultActivityDays // 180)},pvwa:{connectionMethod:"https",host:.Settings.Options.pvwaHost,port:"443",appContext:(.Settings.Options.pvwaAppContext // "PasswordVault")}}' "$PAEASY_INPUT_JSON" > "$payloadfile"
        curl "${curl_args[@]}" -X POST -H 'Content-Type: application/json' --config "$headerfile" \
          --data-binary "@$payloadfile" "https://${host}:8443/installer/api/installation" >/dev/null
      elif [[ $status != 'SUCCESS' && $status != 'RUNNING' ]]; then echo "PTA state $status unsupported" >&2; exit 6; fi
      for i in $(seq 1 60); do
        status=$(curl "${curl_args[@]}" --config "$headerfile" "https://${host}:8443/installer/api/installation" | jq -r '.status // empty')
        [[ $status = SUCCESS ]] && break
        [[ $status != FAILED ]] || { echo 'PTA configuration failed' >&2; exit 6; }
        sleep 10
      done
      [[ $status = SUCCESS ]] || { echo "PTA configuration unresolved: $status" >&2; exit 6; }
      shred -u "$tokenfile" "$bodyfile" "$payloadfile" "$headerfile" 2>/dev/null || true
      trap - EXIT
      pta_export_public_listener_certificate
    fi
    success "$type registration finished";;
  Harden)
    if [[ $harden = false ]]; then success "$type hardening skipped by explicit Lab override";exit 0;fi
    if [[ $type = PSMP && $ID = ubuntu ]]; then
      psmp_ubuntu_apply || { echo 'PASeasy Ubuntu24 PSMP baseline failed; no vendor RHEL hardening claim' >&2; exit 7; }
      success 'PASeasy Ubuntu24 PSMP baseline verified; vendor RHEL hardening is not applicable; brokered functional validation remains separate'
      exit 0
    elif [[ $type = PSMP ]]; then
      [[ -f /opt/CARKpsmp/bin/PSMPHardening.sh ]] || { echo 'Selected PSMP package has no vendor hardening script; qualified platform procedure required' >&2; exit 7; }
      # RPM postin already applies this mandatory install option. Never launch a
      # second destructive hardening pass; reconcile actual policy independently.
      log=/var/opt/CARKpsmp/temp/PSMPHardening_log.txt
      [[ -s $log ]] && grep -Fq 'Finished' "$log" || { echo 'Native PSMP hardening completion evidence missing' >&2; exit 7; }
      ! grep -Fq 'WARNING:' "$log" || { echo 'Native PSMP hardening warnings require review' >&2; exit 7; }
      sshd -t
      effective=$(sshd -T -C user=root,host="$(hostname -s)",addr=127.0.0.1)
      for setting in 'disableforwarding yes' 'allowtcpforwarding no' 'permitlisten none' 'gatewayports no' 'allowstreamlocalforwarding no' 'permittunnel no' 'x11forwarding no' 'allowagentforwarding no'; do
        grep -Fxq "$setting" <<< "$effective" || { echo "Native PSMP SSH policy missing: $setting" >&2; exit 7; }
      done
      ! grep -Eq '^[[:space:]]*Subsystem[[:space:]]+sftp' /etc/ssh/sshd_config || { echo 'Native PSMP SFTP restriction missing' >&2; exit 7; }
      [[ $(sysctl -n kernel.randomize_va_space) = 2 && $(sysctl -n fs.suid_dumpable) = 0 ]] || { echo 'Native PSMP memory hardening missing' >&2; exit 7; }
    else
      # v15 installTasksList includes hardenPTA. Do not rerun its destructive policy changes.
      # Independently verify the exact effective SSH settings from that supplied task.
      sshd -t
      effective=$(sshd -T)
      for expected in 'ciphers aes256-ctr,aes192-ctr,aes128-ctr' 'macs hmac-sha2-512,hmac-sha2-256' 'kexalgorithms ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group14-sha256,diffie-hellman-group-exchange-sha256' 'gssapiauthentication no'; do
        grep -Fxq "$expected" <<< "$effective" || { echo 'PTA effective SSH hardening differs from vendor task' >&2; exit 7; }
      done
      # The supplied task applies its auditd mask only when an installed RPM name contains auditd.
      # Stock EL9 installs package audit instead; preserve that enabled enterprise audit service.
      if rpm -qa | grep -i auditd >/dev/null; then
        [[ $(systemctl is-enabled auditd 2>/dev/null || true) = masked ]] || { echo 'Applicable PTA vendor auditd policy not observed' >&2; exit 7; }
      fi
    fi
    success "$type hardening completed";;
  Verify)
    if [[ $type = PSMP ]]; then
      if [[ $ID = ubuntu && $harden != false ]]; then psmp_ubuntu_baseline_valid || { echo 'Ubuntu PSMP effective baseline drift' >&2; exit 8; }; fi
      psmp_local_readiness || { echo "PSMP registered credentials or actual daemon unavailable; aggregate service state is insufficient" >&2; exit 8; }
    else
      pta_os_preflight || { echo 'PTA OS/CPU readiness drift' >&2; exit 8; }
      pta_filesystem_preflight || { echo 'PTA filesystem readiness drift' >&2; exit 8; }
      systemctl is-active --quiet appmgr || { echo 'PTA appmgr is not active' >&2; exit 8; }
      host=$(options installerHost); [[ -n $host ]] || host=$(jq -r '.Settings.Address // "127.0.0.1"' "$PAEASY_INPUT_JSON")
      [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || exit 8
      ca=$(options caFile); if [[ -z $ca ]];then if [[ -f "$root/certificates/trust-bundle.pem" ]];then ca="$root/certificates/trust-bundle.pem";else ca="$root/syslog-public.pem";fi;fi; health_args=(--fail --silent --show-error --max-time 20)
      [[ -z $ca ]] || health_args+=(--cacert "$ca")
      [[ $secure != false ]] || health_args+=(--insecure)
      version=$(sed -n 's/^version_number=//p' /etc/opt/pta/diamond-resources/version.properties | tr -d '\r')
      [[ -n $version ]] || exit 8
      curl "${health_args[@]}" "https://${host}:8443/diamond/version" | grep -Fq "Diamond.version = \"$version\"" || { echo 'PTA HTTPS application version check failed' >&2; exit 8; }
    fi
    success "$type independent base health passed; authenticated functional session/event tests are separate";;
  *) echo "Unknown stage $stage" >&2;exit 2;;
esac
