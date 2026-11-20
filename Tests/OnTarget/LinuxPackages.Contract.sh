#!/usr/bin/env bash
# Package-selection unit contract; no package manager or product mutation.
set -euo pipefail
recipe=${1:?Pass candidate Task.sh}
eval "$(awk '/^install_missing_rpms\(\) \{/{p=1} p{print} p && /^}/{exit}' "$recipe")"
installed=' openssh-server openssh-clients gnupg2 '
calls=0
rpm() { [[ $1 = -q && $2 = --quiet ]]; [[ $installed = *" $3 "* ]]; }
dnf() {
    [[ $1 = install && $2 = -y ]]; shift 2
    [[ $# = 1 && $1 = policycoreutils-python-utils ]]
    calls=$((calls+1)); installed+="$1 "
}
install_missing_rpms openssh-server openssh-clients gnupg2
[[ $calls = 0 ]]
install_missing_rpms openssh-server policycoreutils-python-utils gnupg2
[[ $calls = 1 ]]
install_missing_rpms openssh-server policycoreutils-python-utils gnupg2
[[ $calls = 1 ]]
echo 'PASS: installed packages skipped, only missing RPM requested, repeat performs no package transaction.'
