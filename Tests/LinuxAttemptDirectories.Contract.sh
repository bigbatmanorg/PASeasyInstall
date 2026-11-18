#!/usr/bin/env bash
# Real directory security checks in root-owned isolated fixtures, never global modes.
set -euo pipefail
if [ "$(id -u)" != 0 ]; then echo 'NotTested: directory contract requires root'; exit 77; fi
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d /opt/paeasy-attempt-guard-test-XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
chmod 700 "$fixture"
mkdir -p "$fixture/opt" "$fixture/run/systemd/system" "$fixture/etc/systemd/system"
chmod -R go-rwx "$fixture"
export PAEASY_TEST_REPO="$repo" PAEASY_TEST_FIXTURE="$fixture"
pwsh -NoProfile -Command '
  Import-Module (Join-Path $env:PAEASY_TEST_REPO "Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1") -Force
  $paths=@("/","/opt",$env:PAEASY_TEST_FIXTURE)+@(@("/opt","/run","/run/systemd","/run/systemd/system","/etc","/etc/systemd","/etc/systemd/system")|ForEach-Object {$env:PAEASY_TEST_FIXTURE+$_})
  $code=& (Get-Module PASeasyInstall.Core) {param($paths) Get-PSLinuxDirectoryGuard $paths} $paths
  [IO.File]::WriteAllText(($env:PAEASY_TEST_FIXTURE+"/guard.sh"),$code,[Text.UTF8Encoding]::new($false))
'
bash "$fixture/guard.sh"
for path in opt run run/systemd run/systemd/system etc etc/systemd etc/systemd/system; do
  chmod 777 "$fixture/$path"
  if bash "$fixture/guard.sh"; then echo "FAIL: writable $path admitted"; exit 1; fi
  [ "$(stat -c %a "$fixture/$path")" = 777 ]
  chmod 700 "$fixture/$path"
done
mv "$fixture/opt" "$fixture/real-opt"
ln -s "$fixture/real-opt" "$fixture/opt"
if bash "$fixture/guard.sh"; then echo 'FAIL: symlink ancestor admitted'; exit 1; fi
rm "$fixture/opt";mv "$fixture/real-opt" "$fixture/opt"
chown 65534 "$fixture/opt"
if bash "$fixture/guard.sh"; then echo 'FAIL: non-root ancestor admitted'; exit 1; fi
chown 0 "$fixture/opt"
bash "$fixture/guard.sh"
mv "$fixture/opt" "$fixture/real-opt"
printf fixture > "$fixture/opt";chmod 644 "$fixture/opt"
if bash "$fixture/guard.sh"; then echo 'FAIL: regular file admitted as directory'; exit 1; fi
[ "$(stat -c %a "$fixture/opt")" = 644 ]
rm "$fixture/opt";mv "$fixture/real-opt" "$fixture/opt"
echo 'PASS: generated OS directory guard refuses seven writable ancestors, symlink and non-root owner; no global permissions changed'
