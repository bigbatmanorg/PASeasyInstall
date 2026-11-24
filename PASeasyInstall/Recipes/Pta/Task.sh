#!/usr/bin/env bash
# CyberArk PTA on a RHEL-family server, with the vendor's own tools:
#   Extract        unpack the vendor package
#   Prerequisites  sshpass, unzip, tar; the CyberArk package signing key
#   Install        pta_installer.sh (the controller restarts the server afterwards)
#   Register       /opt/pta/utility/internal/ptaAutomaticConfiguration.py: connects PTA to the Vault and to PVWA
# Runs as root on the PTA server. The vendor does not support Ubuntu.
set -Eeuo pipefail
export LC_ALL=C
: "${PAEASY_INPUT_JSON:?Missing restricted remote input envelope}"
command -v jq >/dev/null || { echo 'jq is required on Linux targets' >&2; exit 2; }
setting() { jq -r --arg k "$1" '.Settings[$k] // empty' "$PAEASY_INPUT_JSON"; }
option() { jq -r --arg k "$1" '.Settings.Options[$k] // empty' "$PAEASY_INPUT_JSON"; }
stage=$(jq -r '.Stage' "$PAEASY_INPUT_JSON")
root=$(setting StageRoot)
media=$(setting MediaTarget)
[[ $root =~ ^/opt/paeasyinstall/components/[a-z][a-z0-9_-]{0,39}$ && ! -L $root ]] || { echo 'Unsafe component StageRoot' >&2; exit 2; }
. /etc/os-release
payload="$root/payload"
mkdir -p "$root/stage"
chmod 700 "$root" "$root/stage"

success() {
    printf '{"stage":"%s","time":"%s"}\n' "$stage" "$(date -u +%FT%TZ)" > "$root/stage/$stage.json"
    jq -nc --arg m "$1" '{Changed:true,Message:$m}' | sed 's/^/PAEASY_RESULT:/'
}
installer_dir() {
    local script
    script=$(find "$payload" -name pta_installer.sh -type f | head -n 1)
    [[ -n $script ]] || { echo 'pta_installer.sh is not in the unpacked package' >&2; return 1; }
    dirname "$script"
}

case "$stage" in
  Preflight)
    [[ -f $media ]] || { echo "Staged media missing: $media" >&2; exit 3; }
    [[ $(id -u) = 0 ]] || { echo 'PTA is installed as root' >&2; exit 3; }
    [[ -f /etc/redhat-release ]] || { echo "PTA needs a RHEL-family server (RHEL, Rocky, Alma 8.8+ or 9.3+); this is ${PRETTY_NAME:-unknown}" >&2; exit 3; }
    memory=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    (( memory >= 7000 )) || { echo "PTA needs at least 8 GB of memory; this server has ${memory} MB" >&2; exit 3; }
    success "PTA server preflight successful (${PRETTY_NAME:-}, ${memory} MB)";;
  Extract)
    command -v unzip >/dev/null || dnf -y -q install unzip
    if [[ ! -e "$root/stage/Extract.json" ]]; then
        rm -rf "$payload"
        mkdir -p "$payload"
        unzip -q -o "$media" -d "$payload" || { echo 'The PTA package cannot be unpacked. It may be incomplete: download it again.' >&2; exit 4; }
    fi
    dir=$(installer_dir)
    chmod +x "$dir/pta_installer.sh"
    success 'PTA package unpacked';;
  Prerequisites)
    # The vendor installer wants these packages; sshpass comes from EPEL.
    missing=()
    for package in sshpass unzip tar; do rpm -q --quiet "$package" || missing+=("$package"); done
    if (( ${#missing[@]} )); then
        rpm -q --quiet epel-release || dnf -y -q install epel-release
        dnf -y -q install "${missing[@]}"
    fi
    # The installer checks the signature of its SELinux policy package with the CyberArk key.
    key=$(setting RpmKeyTarget)
    if [[ -n $key && -f $key ]]; then rpm --import "$key"; fi
    policy=$(find "$(installer_dir)" -name "pta-selinux-policy-*.el${VERSION_ID%%.*}.noarch.rpm" | head -n 1)
    [[ -n $policy ]] || { echo "The package has no SELinux policy for release ${VERSION_ID%%.*}" >&2; exit 5; }
    rpm -K "$policy" | grep -q 'signatures OK' || { echo 'The CyberArk package signing key is not on this server (RPM-GPG-KEY-CyberArk; it comes with the PSMP package)' >&2; exit 5; }
    success 'Packages and the CyberArk signing key are ready';;
  Install)
    [[ $(option acceptEula) = true ]] || { echo 'The CyberArk license agreement of PTA was not accepted (options.acceptEula)' >&2; exit 6; }
    if systemctl list-unit-files ptaweb.service >/dev/null 2>&1 && [[ -d /opt/pta/utility ]]; then
        success 'PTA is installed already'
        exit 0
    fi
    dir=$(installer_dir)
    # The installer asks to accept the license agreement and to continue.
    (cd "$dir" && printf 'Y\n\n' | ./pta_installer.sh) > "$root/pta_installer.log" 2>&1 || { tail -n 15 "$root/pta_installer.log" >&2; echo 'pta_installer.sh failed' >&2; exit 6; }
    [[ -x /opt/pta/utility/internal/ptaAutomaticConfiguration.py || -f /opt/pta/utility/internal/ptaAutomaticConfiguration.py ]] || { tail -n 15 "$root/pta_installer.log" >&2; echo 'PTA was not installed' >&2; exit 6; }
    success 'PTA software installed; the server restarts next';;
  Register)
    vault=$(setting VaultAddress); vault_user=$(setting VaultUser); timezone=$(setting VaultTimezone)
    pvwa_host=$(setting PvwaHost); pvwa_ip=$(setting PvwaAddress); address=$(setting Address)
    vault_password=$(jq -r '.VaultPassword // ""' "$PAEASY_INPUT_JSON"); root_password=$(jq -r '.RootPassword // ""' "$PAEASY_INPUT_JSON")
    [[ -n $vault_password && -n $root_password ]] || { echo 'PTA configuration needs the Vault administrator password and the root password of this server' >&2; exit 7; }
    [[ $vault =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ && $pvwa_host =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ && $timezone =~ ^[A-Za-z0-9_+/-]{1,64}$ ]] || { echo 'Unsafe Vault address, PVWA name or time zone' >&2; exit 7; }
    tool=/opt/pta/utility/internal/ptaAutomaticConfiguration.py
    [[ -f $tool ]] || { echo 'The PTA automatic configuration tool is missing; is PTA installed?' >&2; exit 7; }
    # Names without DNS: PVWA under the name of its certificate, and this server under its real address.
    if [[ $pvwa_ip =~ ^[0-9.]+$ ]] && ! getent hosts "$pvwa_host" >/dev/null; then echo "$pvwa_ip $pvwa_host" >> /etc/hosts; fi
    if [[ $address =~ ^[0-9.]+$ ]] && ! getent hosts "$(hostname)" | grep -q "^$address "; then echo "$address $(hostname -f) $(hostname -s)" >> /etc/hosts; fi
    # PTA's Java must trust the PVWA certificate (a lab PVWA has its own). With several PVWAs the file is a
    # bundle of all their certificates; keytool -importcert takes one certificate at a time, so the bundle is
    # split (keytool -printcert -rfc prints every certificate in it) and each one is imported under its own alias.
    certificate=$(setting PVWATrustCertificateTarget)
    if [[ -n $certificate && -f $certificate ]]; then
        split=$(mktemp -d)
        for java in /opt/pta/jvm/*/; do
            keytool="$java/bin/keytool"; store="$java/lib/security/cacerts"
            rm -f "$split"/pvwa-*.pem
            "$keytool" -printcert -rfc -file "$certificate" 2>/dev/null |
                awk -v dir="$split" '/-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s/pvwa-%d.pem", dir, n) } out { print > out } /-----END CERTIFICATE-----/ { close(out); out = "" }'
            found=$(find "$split" -name 'pvwa-*.pem' | wc -l)
            [[ $found -gt 0 ]] || { echo "keytool finds no certificate in $certificate" >&2; exit 7; }
            for alias in $("$keytool" -list -keystore "$store" -storepass changeit 2>/dev/null | sed -n 's/^\(paseasy-pvwa[-0-9]*\),.*/\1/p'); do
                "$keytool" -delete -alias "$alias" -keystore "$store" -storepass changeit >/dev/null 2>&1 || true
            done
            for n in $(seq 1 "$found"); do
                alias=paseasy-pvwa; [[ $n -eq 1 ]] || alias="paseasy-pvwa-$n"
                out=$("$keytool" -importcert -alias "$alias" -file "$split/pvwa-$n.pem" -keystore "$store" -storepass changeit -noprompt 2>&1) ||
                    { echo "keytool cannot import PVWA certificate $n of $certificate into $store: $out" >&2; exit 7; }
            done
        done
        rm -rf "$split"
    fi
    for attempt in $(seq 1 30); do
        curl --silent --insecure --max-time 5 --output /dev/null https://localhost:8443/installer/ && break
        sleep 10
    done
    # The installer application signs root in through the system, which the PTA SELinux policy only allows in
    # permissive mode. The mode is set back right after the configuration.
    mode=$(getenforce)
    restore() { if [[ $mode = Enforcing ]]; then setenforce 1; fi; }
    trap restore EXIT
    if [[ $mode = Enforcing ]]; then setenforce 0; fi
    rootPassword="$root_password" vault_ip="$vault" vault_timezone="$timezone" vault_adminUser="$vault_user" vault_adminPassword="$vault_password" pvwa_host="$pvwa_host" \
        /usr/libexec/platform-python "$tool" > "$root/pta_configuration.out" 2>&1 || {
        grep -E 'ERROR|error' /opt/pta/logs/ptaAutomaticConfiguration.log 2>/dev/null | tail -n 5 | sed "s/$root_password/<password>/g; s/$vault_password/<password>/g" >&2
        echo 'The PTA automatic configuration failed (see /opt/pta/logs/ptaAutomaticConfiguration.log on the server)' >&2; exit 7; }
    restore
    trap - EXIT
    # The vendor tool turns firewalld on with only its port forwarding; open the ports PTA listens on.
    if systemctl is-active --quiet firewalld; then
        for port in 80/tcp 443/tcp 8080/tcp 8443/tcp 514/tcp 514/udp 11514/tcp 11514/udp; do firewall-cmd -q --permanent --add-port="$port"; done
        firewall-cmd -q --reload
    fi
    systemctl restart appmgr
    success "PTA configured for Vault $vault and PVWA $pvwa_host";;
  *) echo "Unknown stage $stage" >&2; exit 2;;
esac
