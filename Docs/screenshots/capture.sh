#!/bin/bash
# capture.sh <out.png> <wait-seconds> [ENV=VAL ...]   (PASUI_CAPTURE_ARGS='-Backend Mock' for the dummy backend)
# Launches the UI with the given env vars, captures ONLY its window, then closes it.
# Works while you keep typing elsewhere: a KWin script raises the window (keepAbove) without
# activating it and reports its geometry; Spectacle grabs the screen; the image is cropped to
# that window. Only processes started here (one process group) are stopped.
set -u
out=$1; wait=$2; shift 2
here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$here"
U=$(env | grep -o '^[^=]*-[^=]*=' | tr -d = | sed 's/^/-u /' | tr '\n' ' ')
# Extra launcher arguments (e.g. "-Backend Mock") via PASUI_CAPTURE_ARGS.
setsid env $U "$@" pwsh -NoProfile -File ./Start-PASeasyInstall.ps1 ${PASUI_CAPTURE_ARGS:-} > "${out%.png}.log" 2>&1 &
leader=$!
sleep "$wait"
# The window host runs under systemd-run (outside our process group); match it by this launch's
# unique --app folder, which the in-group launcher process carries on its command line.
appdir=$(pgrep -a -g "$leader" | grep -o -- '--app [^ ]*' | head -1 | cut -d' ' -f2)
pids=$( { pgrep -g "$leader"; [ -n "$appdir" ] && pgrep -f -- "--app $appdir"; } | sort -u | tr '\n' ' ')
cat > "$tmp/raise.js" <<EOF
const mine = [${pids// /,}0];
const wins = workspace.windowList ? workspace.windowList() : workspace.clientList();
for (const w of wins) {
  if (w.caption === 'PASeasyInstall' && mine.indexOf(w.pid) >= 0) {
    w.keepAbove = true;
    const g = w.frameGeometry;
    print('PASGEOM ' + Math.round(g.x) + ' ' + Math.round(g.y) + ' ' + Math.round(g.width) + ' ' + Math.round(g.height));
  }
}
EOF
since=$(date '+%Y-%m-%d %H:%M:%S')
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$tmp/raise.js" pascapture >/dev/null
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null
sleep 1
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript pascapture >/dev/null
geom=$(journalctl --user --since "$since" --no-pager 2>/dev/null | grep -o 'PASGEOM [0-9 -]*' | tail -1 | cut -d' ' -f2-)
if [ -n "$geom" ]; then
  spectacle -b -n -f -o "$tmp/full.png" >/dev/null 2>&1
  python3 -I - "$tmp/full.png" "$out" $geom <<'PY'
import sys
from PIL import Image
src, dst, x, y, w, h = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:7])
img = Image.open(src)
img.crop((max(x, 0), max(y, 0), min(x + w, img.width), min(y + h, img.height))).save(dst)
PY
else
  echo "capture.sh: app window not found; no screenshot taken" >&2
fi
kill -TERM -- "-$leader" 2>/dev/null; sleep 1; pkill -g "$leader" 2>/dev/null
echo "$out"
