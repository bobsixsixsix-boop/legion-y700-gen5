# sb-bed scenario (10-22, run by vol-open-run.sh): the control centre's volume pill when the curtain opens and while
# it is up (src/backend.cpp readVolume / watchVolume, README「控制中心」第十三轮). Since round 12 a drag moves the
# level relative to the value on screen, so that value must be the current one the moment the curtain is up: until
# 10-22 the volume came only with the status pipeline (0.35 s idle on the tablet, more under load) and a drag
# started before it landed moved the sound from the level of the last opening.
# The bed has no sound server: the runner starts the control centre with vol-open-bin/ first on its PATH (wpctl and
# pactl stand-ins keep the default sink's level in $XDG_RUNTIME_DIR/sb-audio; a change appends a pactl event that the
# stand-in `pactl subscribe` follows; tb323fu-ctl holds the status pipeline back $XDG_RUNTIME_DIR/sb-status-lag s,
# here 2.5, so the pipeline cannot race the screenshots: the pill must not need it). Volume pill x 1204-1544, centre
# y 494 (pill-drag.sh: the same pill, the same fill()). The level starts at the stand-in's 0.40.
#   1 closed: the keys set 80 %; open, shot at once        -> the pill 80 %           (the old backend: 40)
#     at once drag -68 px, lift                             -> sound and pill (80 - 62/340) = 62 %   (the old: 22)
#   2 closed: the keys set 30 %, and the next volume read samples at once but answers 2.5 s late. Open, drag -68 px
#     before it answers (from the level on screen, the last opening's: nothing has answered), lift after it
#                                                           -> the drag's level stays, in the sound and on the pill,
#                                                              not the stale 30 % (a sample older than our write)
#   3 still open, > 1.5 s after the drag: the keys set 70 % -> the pill 70 % within 0.6 s (the old: at the next 5 s
#                                                              poll); one pactl subscribe of ours running
#   4 closed                                                -> no pactl subscribe left (it runs only while open)
# Verdict, one line, in OUT/vol-open.txt (vol-open-run.sh records it for y700-checklist).
verdict() {
    [ -n "$1" ] || set -- "FAIL the analysis printed no verdict: $(head -c 160 "$OUT/verdict.err" 2>/dev/null | tr '\n' ' ') ($OUT/verdict.err)"
    echo "$*" > "$OUT/vol-open.txt"; echo "vol-open: $*"; case "$1" in FAIL*) FAIL=1 ;; esac
}
FAKE=$(dirname "$CC")           # the runner's wrapper sits with the stand-ins
S=$XDG_RUNTIME_DIR/sb-audio
if [ ! -x "$FAKE/wpctl" ] || [ ! -x "$FAKE/pactl" ]; then
    verdict "FAIL no wpctl / pactl stand-ins next to $CC (run vol-open-run.sh, not sb-bed.sh directly)"
    return 0
fi
level() { cut -d' ' -f1 "$S" 2>/dev/null; }
keys() { "$FAKE/wpctl" set-volume @DEFAULT_AUDIO_SINK@ "$1"; echo "vol-open $(date +%T.%N | cut -c1-12) keys $1" >> "$LOG"; }
watchers() { pgrep -f -- "-F $S.events" | wc -l; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || echo "cc $1 failed" >> "$LOG"; }
at() { echo "vol-open $(date +%T.%N | cut -c1-12) $*" >> "$LOG"; }
# a drag on the volume pill from x 1442 to 1374 (-68 px: -62/340 once the 6 px slop is spent), held 600 ms at its end
drag() { printf 'd 1 300 700\ns 150\nswipe 1442 494 1374 494 200 600\ns 30\nu 1\n' | touch; }
app Kate '#3d7bf7'
sleep 1
# the controls: a pull on the right half; the holding finger then sits on the curtain's empty left half for a long
# press, no tap (pill-drag.sh)
HOLD_AT="300 700"; HOLD_MS=1000
echo 2.5 > "$XDG_RUNTIME_DIR/sb-status-lag"
L0=$(level)
# 1
keys 80%
at open 1; pull 1200 10 450 400; at pulled
shot v1-open
at drag 1; drag; at lifted
sleep 0.4; shot v1-after
L1=$(level)
cc hide; sleep 1
# 2
keys 30%
echo 2.5 > "$S.lag"
at open 2; pull 1200 10 450 400; at pulled
shot v2-open
at drag 2; drag; at lifted
sleep 1.2; at read answered
shot v2-after
L2=$(level)
rm -f "$S.lag"
# 3
sleep 0.5
keys 70%
sleep 0.6; shot v3-live
W3=$(watchers)
# 4
cc hide; sleep 1
W4=$(watchers)
wins
verdict "$(python3 - "$OUT" "$L0" "$L1" "$L2" "$W3" "$W4" 2> "$OUT/verdict.err" <<'PY'
import sys

import numpy as np
from PIL import Image

out = sys.argv[1]
l0, l1, l2 = (float(x) if x else -1.0 for x in sys.argv[2:5])
w3, w4 = (int(x or -1) for x in sys.argv[5:7])
X0, X1, CY = 1204, 1544, 494


def pic(name):
    return np.asarray(Image.open(f"{out}/{name}.png").convert("RGB"), dtype=int)


def fill(im, cy=CY):        # pill-drag.sh's reader: the fill's fraction at the row 20 px above the pill's centre
    y = cy - 20
    chip = im[cy, 1218]
    if not (chip[0] < 110 and chip[2] > 190):
        print(f"FAIL no pill chip at (1218, {cy}): rgb {tuple(chip)} (the layout moved, or the curtain is not up)"); sys.exit(1)
    row = im[y - 1:y + 2, X0:X1].min(axis=0)
    white = row.min(axis=1) >= 200
    if not white.any():
        return 0.0
    w = float(np.flatnonzero(white)[-1] + 1)
    if w > 310:
        w = 310 + ((w - 310) ** 2 + 100) / 20
    return min(1.0, w / (X1 - X0))


try:
    o1, a1, o2, a2, v3 = (fill(pic(n)) for n in ("v1-open", "v1-after", "v2-open", "v2-after", "v3-live"))
except OSError as e:
    print(f"FAIL screenshot missing: {e}"); sys.exit(1)
D = 62 / 340
T = 0.012           # a fill read off the screen: 4 px
TL = 0.015          # a level: pactl writes whole percent, so the fill's ±1 px plus the rounding
bad = []
if abs(l0 - 0.40) > 0.001:
    bad.append(f"the stand-in started at {l0}, not 0.40 (the bed's level file?)")
if abs(o1 - 0.80) > T:
    bad.append(f"open after the keys set 80: the pill {o1 * 100:.1f} % (a stale level: the volume waits for the pipeline)")
if abs(l1 - (0.80 - D)) > TL or abs(a1 - (0.80 - D)) > T:      # from the level the keys set, whatever the pill showed
    bad.append(f"drag -68 px at once: sound {l1 * 100:.0f} %, pill {a1 * 100:.1f} %, wanted {(0.80 - D) * 100:.1f} % (80 - 18)")
if abs(l2 - (o2 - D)) > TL or abs(a2 - (o2 - D)) > T:
    bad.append(f"drag before a slow read: sound {l2 * 100:.0f} %, pill {a2 * 100:.1f} %, wanted {(o2 - D) * 100:.1f} % (from {o2 * 100:.0f})")
if abs(a2 - 0.30) < 0.05:
    bad.append(f"the slow read's stale 30 % came back over the drag (pill {a2 * 100:.1f} %)")
if abs(v3 - 0.70) > T:
    bad.append(f"keys set 70 while open: the pill {v3 * 100:.1f} % 0.6 s later (no live update)")
if w3 != 1:
    bad.append(f"{w3} pactl subscribe while open, wanted 1")
if w4 != 0:
    bad.append(f"{w4} pactl subscribe left after closing, wanted 0")
shown = (f"open {o1 * 100:.0f} drag {l1 * 100:.0f}/{a1 * 100:.0f} slow-read {o2 * 100:.0f}->{l2 * 100:.0f}/{a2 * 100:.0f}"
         f" live {v3 * 100:.0f} watchers {w3}/{w4}")
print(("FAIL " + "; ".join(bad) + " | " + shown) if bad else "OK 4 steps, " + shown)
PY
)"
