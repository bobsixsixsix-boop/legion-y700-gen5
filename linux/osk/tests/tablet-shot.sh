#!/bin/bash
# Windows-side helper (Git Bash): screenshot the tablet's whole screen and fetch a half-size copy.
# usage: tablet-shot.sh NAME [OUTDIR]   -> prints the local path of NAME.png (1520x952, half the panel)
# Spectacle grabs the composited screen including layer-shell surfaces (keyboard, HUD, control centre);
# it is blank while the display is off (DPMS) - then use the keyboard's own --preview grab instead.
# Logical KWin coordinates (what vtouch.py takes) = screenshot pixel * 2 / 1.9 for this half-size copy
# (half-size px * 2 = panel px, panel px / 1.9 scale = logical). NOT * 0.95: that once hit the wrong keys.
set -e
name=${1:?name}; out=${2:-${TMPDIR:-/tmp}}
key=~/.ssh/y700_ed25519; host=root@100.64.0.10
ssh -o BatchMode=yes -i $key $host "sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus timeout 20 spectacle -b -n -f -o /tmp/y700-shot-$name.png >/dev/null 2>&1; test -s /tmp/y700-shot-$name.png"
scp -q -o BatchMode=yes -i $key $host:/tmp/y700-shot-$name.png "$out/$name-full.png"
py -3 - "$out/$name-full.png" "$out/$name.png" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]); im = im.resize((im.width // 2, im.height // 2), Image.LANCZOS); im.save(sys.argv[2])
EOF
echo "$out/$name.png"
