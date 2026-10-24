#!/bin/sh
# dock-glass-real.sh MODE [N]: frames of the dock coming back on the REAL screen as the task switcher leaves for the
# desktop (10-22: leaving the cards for the desktop, the dock showed clear first and blurred only after), by MODE:
#   recents      app -> bottom-edge swipe + hold (cards) -> bottom-edge swipe (leave to the desktop)
#   homeflick    app -> bottom-edge flick up (straight home)
#   deskrecents  desktop -> bottom-edge swipe + hold (cards from the desktop) -> bottom-edge swipe (back)
#   homeflick2   like homeflick, but the dock was revealed over the app first (B+ short swipe)
# The last two showed the bug (the dock is mapped when the effect starts, so the effect paints it); the headless
# bed's dock-glass.sh is the regression test, this is the eye check after a reinstall + reboot. Raises Konsole
# (the dock goes away) for the app modes, so Konsole must be running. Writes /home/user/dock-blur/MODE/:
# the frames, frames.txt, strip.png (the dock band of the frames around the change, labelled with capseq's
# sharpness of the whole band). Takes the screen for about 5 s: not while the tablet is in use. Root.
set -u
U=user; MODE=${1:-deskrecents}; N=${2:-90}; OUT=/home/$U/dock-blur/$MODE
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 HOME=/home/$U"
FT=/usr/local/bin/y700-ftouch
CAP=/usr/local/share/y700-control-center/tests/capseq.py
[ -f "$CAP" ] || { echo "no $CAP (sh linux/controlpanel/y700-control-center/install.sh)"; exit 1; }
mkdir -p $OUT; rm -f $OUT/f*.png $OUT/frames.txt $OUT/sheet.png $OUT/strip.png; chown -R $U:$U /home/$U/dock-blur
if $RUN kscreen-doctor --dpms show 2>/dev/null | grep -q 'off$'; then $RUN kscreen-doctor --dpms on >/dev/null 2>&1; sleep 2.5; fi
$RUN busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1
kwinjs() {   # run a KWin script given on stdin (a fresh temp name: root must not write a fixed path in /tmp)
    local js id; js=$(mktemp /tmp/dock-glass-real-XXXXXX.js); cat > "$js"; chmod 644 "$js"
    id=$($RUN qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$js" dockglass-$$)
    $RUN qdbus6 org.kde.KWin /Scripting/Script$id org.kde.kwin.Script.run >/dev/null
    sleep 1.5
    $RUN qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript dockglass-$$ >/dev/null
    rm -f "$js"
}
raise_konsole() {
    kwinjs <<'EOF'
const w = workspace.stackingOrder.find(w => w.resourceClass == "org.kde.konsole");
if (w) { w.minimized = false; workspace.activeWindow = w; print("js: raised " + w.caption); } else print("js: no konsole");
EOF
}
PRIME='swipe 800 10 840 10 60\ns 400\n'      # a fresh ftouch's first touch is missed: a harmless one first
burst() { $RUN /usr/local/bin/y700-capseq $CAP $OUT $N DSI-1 300 890 1300 990 > $OUT/capseq.log 2>&1 & cap=$!; sleep 0.5; }
case $MODE in
recents)
    raise_konsole
    printf "${PRIME}swipe 800 1001 800 840 350 600\n" | $RUN $FT
    sleep 1.6
    burst
    printf "${PRIME}swipe 800 1001 800 860 250 150\n" | $RUN $FT
    ;;
homeflick)
    raise_konsole
    burst
    printf "${PRIME}swipe 800 1001 800 760 140\n" | $RUN $FT
    ;;
homeflick2)
    raise_konsole
    printf "${PRIME}swipe 800 1001 800 960 300 200\n" | $RUN $FT     # B+: short slow swipe, the dock comes up over the app
    sleep 1.2
    burst
    printf "${PRIME}swipe 800 1001 800 760 140\n" | $RUN $FT
    ;;
deskrecents)
    printf "${PRIME}swipe 800 1001 800 840 350 600\n" | $RUN $FT
    sleep 1.6
    burst
    printf "${PRIME}swipe 800 1001 800 860 250 150\n" | $RUN $FT
    ;;
*)  echo "mode? recents | homeflick | deskrecents | homeflick2"; exit 1 ;;
esac
wait $cap
chown -R $U:$U $OUT
echo "== $MODE: $(tail -1 $OUT/capseq.log | cut -c1-80)"
# the dock band of the frames around the change in the band's numbers, and the glass rim's sharpness per frame
# (x 600-740 / 860-1000, y 895-906, as dock-glass.sh): the real KWin-blurred dock reads about 12 on the wallpaper
# in use, the effect's unblurred thumbnail 216-460
$RUN python3 - "$OUT" <<'EOF'
import sys

import numpy as np
from PIL import Image, ImageDraw

out = sys.argv[1]
rows = [l.split() for l in open(out + "/frames.txt") if l[0] != "#"]
vals = [(r[3], r[4]) for r in rows]
ch = [i for i in range(1, len(vals)) if vals[i] != vals[i - 1]]
if not ch:
    print("no change at all")
    sys.exit(0)


def sharp(g, x0, y0, x1, y1):
    r = g[y0:y1, x0:x1]
    lap = -4 * r[1:-1, 1:-1] + r[:-2, 1:-1] + r[2:, 1:-1] + r[1:-1, :-2] + r[1:-1, 2:]
    return float(lap.var())


lo, hi = max(0, ch[0] - 2), min(len(vals) - 1, ch[-1] + 4)
idx = list(range(lo, hi + 1))
step = max(1, (len(idx) + 21) // 22)
idx = idx[::step]
crops = []
for i in idx:
    full = Image.open(f"{out}/f{i:03d}.png")
    g = np.asarray(full.convert("L"), dtype=np.float64)
    rim = max(sharp(g, 600, 895, 740, 906), sharp(g, 860, 895, 1000, 906))
    im = full.convert("RGB").crop((200, 850, 1400, 1003))
    ImageDraw.Draw(im).text((4, 4), f"f{i} {rows[i][1]}ms band {rows[i][4]} rim {rim:.0f}", fill=(255, 0, 0))
    crops.append(im)
    print(f"f{i:03d} {rows[i][1]:>7} ms  rim {rim:7.1f}")
w, h = crops[0].size
sheet = Image.new("RGB", (w, h * len(crops)))
for k, c in enumerate(crops):
    sheet.paste(c, (0, k * h))
sheet.save(out + "/strip.png")
print("strip", len(idx), "frames", idx[0], "..", idx[-1], "changes at", ch[:3], "..", ch[-3:])
EOF
echo "== shellbar"; $RUN journalctl --user -u y700-shellbar -o short-precise --since "-40s" 2>/dev/null | cut -c1-150 | tail -6
echo "== kwin"; journalctl -b -o short-precise --since "-40s" 2>/dev/null | grep -E "taskswitcher|js: " | cut -c1-150 | tail -6
echo CAP_DONE $MODE
