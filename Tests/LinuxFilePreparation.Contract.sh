#!/usr/bin/env bash
# Real filesystem admission tests; run as root on a disposable Linux controller.
set -euo pipefail
if [ "$(id -u)" != 0 ]; then echo 'NotTested: root filesystem contract requires root'; exit 77; fi
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d /opt/paeasy-transfer-test-XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
chmod 700 "$fixture"
export PAEASY_TEST_REPO="$repo" PAEASY_TEST_FIXTURE="$fixture"
pwsh -NoProfile -Command '
  Import-Module (Join-Path $env:PAEASY_TEST_REPO "Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1") -Force
  $body=& (Get-Module PASeasyInstall.Core) {Get-PSLinuxFilePreparation "/opt/paeasyinstall/media/input.zip"}
  [IO.File]::WriteAllText(($env:PAEASY_TEST_FIXTURE+"/guard.sh"),$body.Replace("/opt/paeasyinstall",$env:PAEASY_TEST_FIXTURE),[Text.UTF8Encoding]::new($false))
'
guard="$fixture/guard.sh"
bash "$guard"
[ "$(stat -c %a "$fixture/media")" = 700 ]
printf sentinel > "$fixture/sentinel"
ln -s "$fixture/sentinel" "$fixture/media/input.zip"
if bash "$guard"; then echo 'FAIL: destination symlink admitted'; exit 1; fi
[ "$(cat "$fixture/sentinel")" = sentinel ]
rm "$fixture/media/input.zip"
ln "$fixture/sentinel" "$fixture/media/input.zip"
if bash "$guard"; then echo 'FAIL: hardlinked destination admitted'; exit 1; fi
rm "$fixture/media/input.zip"
chmod 777 "$fixture/media"
if bash "$guard"; then echo 'FAIL: writable ancestor admitted'; exit 1; fi
chmod 700 "$fixture/media"
mv "$fixture/media" "$fixture/elsewhere"
ln -s "$fixture/elsewhere" "$fixture/media"
if bash "$guard"; then echo 'FAIL: symlink ancestor admitted'; exit 1; fi
rm "$fixture/media"
mv "$fixture/elsewhere" "$fixture/media"
touch "$fixture/media/input.zip"
chown 65534 "$fixture/media/input.zip"
if bash "$guard"; then echo 'FAIL: non-root file admitted'; exit 1; fi
chown 0 "$fixture/media/input.zip"
chmod 666 "$fixture/media/input.zip"
if bash "$guard"; then echo 'FAIL: writable destination admitted'; exit 1; fi
chmod 600 "$fixture/media/input.zip"
bash "$guard"
echo 'PASS: real Linux destination/ancestor symlink, hardlink, owner and mode guards; no installer executed'
