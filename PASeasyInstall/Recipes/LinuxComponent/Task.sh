#!/usr/bin/env bash
# CyberArk PSMP lab recipe. The controller is pure PowerShell; target uses native Linux tools.
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
if [[ $type != 'PSMP' ]]; then echo "Unsupported Linux recipe type $type" >&2; exit 2; fi
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

case "$stage" in
  Preflight)
    [[ -f "$media" ]] || { echo "Media missing: $media" >&2; exit 3; }
    if [[ $type = PSMP && $ID = ubuntu && ( $VERSION_ID = 22.04 || $VERSION_ID = 24.04 ) ]]; then
      command -v dpkg >/dev/null || exit 3
    elif [[ ( $ID = rhel || $ID = rocky ) && ( ${VERSION_ID%%.*} = 8 || ${VERSION_ID%%.*} = 9 ) ]]; then
      command -v rpm >/dev/null || exit 3
    else echo 'Selected OS/media combination is unqualified (PSMP: Ubuntu 22.04/24.04 or RHEL/Rocky 8/9)' >&2; exit 3; fi
    success "$type Linux prerequisites verified";;
  PrepareTools)
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
    command -v unzip >/dev/null && command -v zipinfo >/dev/null || { echo "unzip and zipinfo are required" >&2; exit 3; }
    success "Linux archive tools prepared";;
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
        # A freshly started Ubuntu runs its own package jobs (apt-daily, unattended-upgrades). dpkg does not wait
        # for their lock, it fails at once (seen in the lab on 2026-11-22), so wait here for up to ten minutes.
        # Nothing of the PSMP package has been started while another process holds the lock.
        for attempt in $(seq 1 120); do
          # Not the permanent helper unattended-upgrade-shutdown: only jobs that use the package manager.
          pgrep -x 'apt|apt-get|dpkg' >/dev/null || pgrep -f '/usr/bin/unattended-upgrade( |$)' >/dev/null || break
          sleep 5
        done
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
    fi
    success "$type installer completed";;
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
    fi
    success "$type hardening completed";;
  Verify)
    if [[ $type = PSMP ]]; then
      if [[ $ID = ubuntu && $harden != false ]]; then psmp_ubuntu_baseline_valid || { echo 'Ubuntu PSMP effective baseline drift' >&2; exit 8; }; fi
      psmp_local_readiness || { echo "PSMP registered credentials or actual daemon unavailable; aggregate service state is insufficient" >&2; exit 8; }
    fi
    success "$type independent base health passed; authenticated functional session/event tests are separate";;
  *) echo "Unknown stage $stage" >&2;exit 2;;
esac
