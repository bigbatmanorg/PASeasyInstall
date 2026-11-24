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

passed=false
case "$stage" in
  Preflight)
    media=$(jq -r '.Settings.MediaTarget' "$PAEASY_INPUT_JSON")
    [[ -f "$media" ]] && passed=true;;
  PrepareTools) command -v unzip >/dev/null && command -v zipinfo >/dev/null && passed=true;;
  Extract) [[ -d "$root/payload" && -n "$(ls -A "$root/payload")" ]] && passed=true;;
  Install)
    [[ -x /opt/CARKpsmp/bin/envmanager ]] && passed=true;;
  Harden)
    if [[ $type = PSMP && $ID = ubuntu && $(jq -r '.Settings.ApplyHardening' "$PAEASY_INPUT_JSON") != false ]]; then
      psmp_ubuntu_baseline_valid && passed=true || true
    else [[ -f "$root/stage/$stage.json" ]] && passed=true;fi;;
  Register)
    psmp_local_readiness && passed=true || true;;
  Verify)
    if [[ $type = PSMP ]]; then
      if psmp_local_readiness; then
        if [[ $ID = ubuntu && $(jq -r '.Settings.ApplyHardening' "$PAEASY_INPUT_JSON") != false ]]; then psmp_ubuntu_baseline_valid && passed=true || true
        else passed=true;fi
      fi
    fi;;
  *) [[ -f "$root/stage/$stage.json" ]] && passed=true;;
esac
jq -nc --argjson ok "$passed" --arg m "$type $stage local readiness verified=$passed; authenticated functional operation NotTested" '{Passed:$ok,Message:$m,Evidence:[]}' | sed 's/^/PAEASY_RESULT:/'
