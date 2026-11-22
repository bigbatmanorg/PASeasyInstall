#!/usr/bin/env bash
# CyberArk PSM HTML5 Gateway as a container, with the vendor's own script (html5_console.sh):
#   Extract        unpack the vendor package
#   Prerequisites  Docker (Ubuntu, Debian) or Podman (RHEL family)
#   Install        load the image, start the container with the PVWA address and the trusted certificates
# The gateway makes its own HTTPS certificate for its host name. Runs as root on the gateway server.
set -Eeuo pipefail
export LC_ALL=C
: "${PAEASY_INPUT_JSON:?Missing restricted remote input envelope}"
command -v jq >/dev/null || { echo 'jq is required on Linux targets' >&2; exit 2; }
setting() { jq -r --arg k "$1" '.Settings[$k] // empty' "$PAEASY_INPUT_JSON"; }
stage=$(jq -r '.Stage' "$PAEASY_INPUT_JSON")
root=$(setting StageRoot)
media=$(setting MediaTarget)
[[ $root =~ ^/opt/paeasyinstall/components/[a-z][a-z0-9_-]{0,39}$ && ! -L $root ]] || { echo 'Unsafe component StageRoot' >&2; exit 2; }
. /etc/os-release
payload="$root/payload"
trust="$root/trust"
container=cahtml5gw
mkdir -p "$root/stage"
chmod 700 "$root" "$root/stage"

success() {
    printf '{"stage":"%s","time":"%s"}\n' "$stage" "$(date -u +%FT%TZ)" > "$root/stage/$stage.json"
    jq -nc --arg m "$1" '{Changed:true,Message:$m}' | sed 's/^/PAEASY_RESULT:/'
}
engine() {
    # The vendor script uses Podman on the RHEL family and Docker elsewhere.
    if [[ -f /etc/redhat-release ]]; then echo podman; else echo docker; fi
}
console_dir() {
    local script
    script=$(find "$payload" -name html5_console.sh -type f | head -n 1)
    [[ -n $script ]] || { echo 'html5_console.sh is not in the unpacked package' >&2; return 1; }
    dirname "$script"
}

case "$stage" in
  Preflight)
    [[ -f $media ]] || { echo "Staged media missing: $media" >&2; exit 3; }
    [[ $(id -u) = 0 ]] || { echo 'The gateway is installed as root' >&2; exit 3; }
    success 'Gateway server preflight successful';;
  Extract)
    command -v unzip >/dev/null || {
        if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get -y -q install unzip; else dnf -y -q install unzip; fi
    }
    if [[ ! -e "$root/stage/Extract.json" ]]; then
        rm -rf "$payload"
        mkdir -p "$payload"
        # A package that was cut short (seen with the 15.2 bundle) fails here.
        unzip -q -o "$media" -d "$payload" || { echo 'The gateway package cannot be unpacked. It may be incomplete: download it again.' >&2; exit 4; }
    fi
    dir=$(console_dir)
    [[ -s "$dir/cahtml5gw" ]] || { echo 'The container image (cahtml5gw) is not in the package' >&2; exit 4; }
    (cd "$dir" && sha512sum cahtml5gw | cut -d' ' -f1 | grep -qiF "$(grep -oiE '[0-9a-f]{128}' cahtml5gw.sha512)") || { echo 'The container image does not match its SHA-512 file' >&2; exit 4; }
    chmod +x "$dir/html5_console.sh"
    success 'Gateway package unpacked and the container image checked';;
  Prerequisites)
    tool=$(engine)
    if ! command -v "$tool" >/dev/null; then
        if [[ $tool = podman ]]; then
            dnf -y -q install podman
        else
            DEBIAN_FRONTEND=noninteractive apt-get -q update
            DEBIAN_FRONTEND=noninteractive apt-get -y -q install docker.io
        fi
    fi
    if [[ $tool = docker ]]; then systemctl enable --now docker; fi
    "$tool" --version >/dev/null
    success "Container engine ready: $("$tool" --version)";;
  Install)
    [[ $(jq -r '.Settings.Options.acceptEula // false' "$PAEASY_INPUT_JSON") = true ]] || { echo 'The CyberArk license agreement of the gateway was not accepted (options.acceptEula)' >&2; exit 5; }
    tool=$(engine)
    dir=$(console_dir)
    pvwa_url=$(setting PvwaUrl); pvwa_host=$(setting PvwaHost); pvwa_ip=$(setting PvwaAddress)
    name=$(setting GatewayName); port=$(setting GatewayPort)
    [[ $pvwa_url =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_-]+$ ]] || { echo 'The gateway needs the HTTPS address of PVWA' >&2; exit 5; }
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ && $port =~ ^[0-9]{2,5}$ ]] || { echo 'Unsafe gateway name or port' >&2; exit 5; }
    # Certificates the gateway must trust: every certificate file that was put into the trust folder (the PVWA
    # certificate of a lab). The folder is given to the container read-only.
    mkdir -p "$trust"
    certificate=$(setting PVWATrustCertificateTarget)
    if [[ -n $certificate && -f $certificate ]]; then install -m 644 "$certificate" "$trust/pvwa.cer"; fi
    chmod 755 "$root" "$trust"
    image=$("$tool" images --format '{{.Repository}}:{{.Tag}}' | grep -E '(^|/)cahtml5gw:' | head -n 1 || true)
    if [[ -z $image ]]; then
        # Creates the users, the container network and loads the image from the package.
        (cd "$dir" && ./html5_console.sh install -l)
        image=$("$tool" images --format '{{.Repository}}:{{.Tag}}' | grep -E '(^|/)cahtml5gw:' | head -n 1)
    fi
    if "$tool" ps -a --format '{{.Names}}' | grep -qx "$container"; then
        "$tool" start "$container" >/dev/null
    else
        arguments=(-d -p "$port:8443" -v "$trust:/opt/import:ro" -e AcceptCyberArkEULA=yes -e "EndPointAddress=$pvwa_url"
            --hostname "$name" --name "$container" --net=cyberark)
        # The container must find PVWA under the name in its certificate, also without DNS.
        if [[ $pvwa_ip =~ ^[0-9.]+$ && -n $pvwa_host ]]; then arguments+=(--add-host "$pvwa_host:$pvwa_ip"); fi
        # Lab: the PSM servers have self-signed RDP certificates.
        if [[ $(setting ValidateTLS) = false || $(setting SecurityProfile) = Lab ]]; then arguments+=(-e IgnorePSMCertificateErrors=yes); fi
        (cd "$dir" && ./html5_console.sh run "${arguments[@]}" "$image")
    fi
    success "Gateway container started ($image) on port $port for $pvwa_url";;
  *) echo "Unknown stage $stage" >&2; exit 2;;
esac
