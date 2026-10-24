#!/bin/sh
# dock-glass-run.sh [OUT]: the dock-glass scenario (dock-glass.sh) in the headless bed (sb-bed.sh) against the
# INSTALLED task switcher, or SB_FX=DIR for another build (one from taskswitcher/install.sh --build DIR, tried
# before the live one is replaced). Makes the textured test wallpaper the scenario needs (the metric wants texture
# under the dock's rim; the bed's default wallpaper is flat there), then writes the verdict for y700-checklist to
# /var/lib/y700/dock-glass-last.txt, stamped with the build it tested (a verdict for another build than the
# installed one = rerun), and OUT/strip.png: the dock band of the frames around the leave, for the eye.
# Root; nothing touches the screen, so it can run while the tablet is in use. About a minute.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); U=user; OUT=${1:-/home/$U/dock-glass}
FX=${SB_FX:-/home/$U/.local/share/kwin/effects/y700-taskswitcher}
WALL=$(mktemp /tmp/dock-glass-wall-XXXXXX.png)
python3 - "$WALL" <<'EOF'
# a colour gradient with strong noise on top: sharp everywhere (Laplacian variance in the thousands), so KWin's blur
# and the effect's glass both read as a large drop, and a see-through dock as none. Plus a vertical step at x 800
# (dark left, light right): how wide the blur smears it under the dock is the blur's size (dock-glass.sh edge()),
# which the noise alone cannot tell (any heavy blur flattens it to the same floor)
import sys

import numpy as np
from PIL import Image

rng = np.random.default_rng(7)
h, w = 1002, 1600
y, x = np.mgrid[0:h, 0:w]
base = np.stack([80 + 100 * x / w, 90 + 90 * y / h, 140 - 60 * x / w], axis=-1)
step = np.where(x < 800, -70, 70)[..., None]
noise = rng.integers(-70, 71, size=(h, w, 1))
Image.fromarray(np.clip(base + step + noise, 0, 255).astype(np.uint8)).save(sys.argv[1])
EOF
chmod 644 "$WALL"
# the last run's verdict, frames and strip must not survive into a run that fails before the analysis (the bed itself
# clears only its screenshots and logs)
rm -rf "$OUT/glass"; rm -f "$OUT/dock-glass.txt" "$OUT/verdict.err" "$OUT/strip.png" "$OUT/strip.txt"
SB_WALL="$WALL" SB_FX="$FX" sh "$HERE/sb-bed.sh" "$HERE/dock-glass.sh" "$OUT"; rc=$?
rm -f "$WALL"
build=$(grep -o 'y700Build: "[^"]*"' "$FX/contents/ui/main.qml" 2>/dev/null | cut -d'"' -f2)
v=$(cat "$OUT/dock-glass.txt" 2>/dev/null || echo "FAIL no verdict (the bed did not reach the analysis: $OUT/log)")
[ -n "$v" ] || v="FAIL an empty verdict (the analysis died: $OUT/verdict.err)"
[ $rc = 0 ] || case "$v" in FAIL*) ;; *) v="FAIL the bed failed (rc $rc, $OUT/log) although the frames passed: $v" ;; esac
case "$v" in FAIL*) [ $rc = 0 ] && rc=1 ;; esac
mkdir -p /var/lib/y700
echo "$(date '+%F %T') $v build ${build:-unknown}" > /var/lib/y700/dock-glass-last.txt
cat /var/lib/y700/dock-glass-last.txt
if [ -f "$OUT/glass/frames.txt" ]; then
    python3 "$HERE/glass-strip.py" "$OUT" "$OUT/strip.png" > "$OUT/strip.txt" 2>&1 && echo "strip: $OUT/strip.png"
    chown $U:$U "$OUT/strip.png" "$OUT/strip.txt" 2>/dev/null
fi
exit $rc
