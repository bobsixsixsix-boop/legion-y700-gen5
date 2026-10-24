# sb-bed scenario (10-22): the control centre's brightness / volume pills (qml/Pill.qml) under a finger.
# Since 10-22 a press does not jump the value: the fill follows the finger's travel from the value on screen
# when the drag starts (relative drag: the pills sit under the right thumb's resting spot, the volume's 100 % end
# right where it lands), a quick tap (< 300 ms, < 16 px from where it landed, thumb roll included) still jumps
# to the tapped spot with the end caps snapping to 0 / 100 %, a press held still past 300 ms is a rest and
# changes nothing, a touch that slides off the bar is no tap, and a drag pinned at an end comes back the moment
# the finger turns (re-anchored). Here, the controls opened from the top edge's right half, on the brightness
# pill (x 1204-1544, centre y 420; the bed has no PowerDevil, so it starts at 0 % and keeps what the pill sets)
# then the volume pill (centre y 494; its level in the bed is whatever the failed wpctl left, and the 5 s status
# poll may rewrite it any time, so it is read while the finger is still down: the fill follows the drag, immune):
#    1 tap at 30 %                       -> 30 %           (a tap jumps)
#    2 press at 80 %, drag +68 px        -> 30 + 62/340   (relative: not 80 + 20; the 6 px slop does not count)
#    3 press, drag +300 px (pinned at 100 %), back 68 px in the same touch -> 100 - 68/340 (re-anchored)
#    4 press at 98 %, hold 700 ms still, release  -> unchanged (a rest)
#    5 press at 98 %, drag -102 px       -> previous - 96/340
#    6 tap that rolls 8 px (1306 -> 1314) in 120 ms -> at(1314) = 110/340 (a thumb's tap, not a drag)
#    7 press, slide 40 px up off the pill, lift -> unchanged (no tap, no drag)
#    8 tap on the right end cap (8 px from the end) -> 100 % (snapped)
#    9 tap on the chip                   -> 0 % (snapped; the backend floors brightness at 1 %)
#   10 volume: press at 50 %, drag +68 px, shot while held -> its start + 62/340
#   11 the fill's outline at both ends (10-22: at the far left the fill was a square bar): brightness,
#      one press dragged left until pinned at 0 (re-anchored at x 1210), then right to 7 / 17 / 27 / 323 / 333 px
#      = 2.1 / 5.0 / 7.9 / 95.0 / 97.9 %, held 2.5 s at each, a shot 0.7 s into every hold
# The value is read off a screenshot: the fill is near-white, the track dark; the fill's right end is the rightmost
# white pixel in the pill's box, leaving out the chip's disc (its icon is white) and the % text (white over the
# track below 82 %). The fill is the capsule cut at that x, so some row always shows it there: exact at both ends.
# The chip (#2e6bf6) must be solid at (1218, centre) (16 px left of its centre, clear of the 24 px icon; not on
# its rim, where a few px of layout drift would read as "moved"), or the pill is not where this scenario thinks
# (layout change: update the numbers here and in Main.qml's comment).
# ±1.2 % (4 px) each: the readout is pixel-exact and the 6 px slop the drags must not count is only 1.8 % of
# the bar, so a looser gate could not tell a pill that counted it (the review caught the old ±3 %); the chip tap
# ±1.5 % (the backend floors brightness at 1 %). The steps of 11 also catch a shot that missed its hold.
# The outline, in every shot and in both pills: no white pixel more than 1.5 px (the antialiasing) outside the
# capsule, its box less the outsides of the two end caps' arcs. Until 10-22 the fill below 60 px was a full-height
# bar with corner radius width / 2 whose corners stuck out of the left cap: the chip tap's 1 % and 11's 2 / 5 / 8 %
# show it (95 / 98 % are the right end, which was always round: they guard the fix's other side).
# The curtain must stay up through all of it (nothing on the panel closes it). Verdict, one line, in
# OUT/pill-drag.txt (pill-drag-run.sh records it for y700-checklist).
verdict() {
    [ -n "$1" ] || set -- "FAIL the analysis printed no verdict: $(head -c 160 "$OUT/verdict.err" 2>/dev/null | tr '\n' ' ') ($OUT/verdict.err)"
    echo "$*" > "$OUT/pill-drag.txt"; echo "pill-drag: $*"; case "$1" in FAIL*) FAIL=1 ;; esac
}
app Kate '#3d7bf7'
sleep 1
# the controls: a pull on the right half (curtain.sh); the holding finger (ftouch's first-touch quirk, sb-bed.sh)
# then sits on the empty left half of the curtain for a long press, which is no tap and closes nothing
HOLD_AT="300 700"; HOLD_MS=1000
pull 1200 10 450 400
sleep 1
mark controls
wins
expect "y700-control-center/"
shot p0-open
# a finger on the pill: the holding finger first (it is lost to the client), ours as slot 0, the hold kept until
# ours is up and long enough in all to be a long press, not a tap
# 1 tap
printf 'd 1 300 700\ns 150\nd 0 1306 420\ns 60\nu 0\ns 900\nu 1\n' | touch
sleep 0.5; shot p1-tap
# 2 relative drag from 80 %
printf 'd 1 300 700\ns 150\nswipe 1476 420 1544 420 200\ns 700\nu 1\n' | touch
sleep 0.5; shot p2-drag
# 3 pinned at the end, then back
{
    printf 'd 1 300 700\ns 150\nd 0 1290 420\ns 30\n'
    x=1290; while [ $x -lt 1590 ]; do x=$((x + 10)); printf 'm 0 %s 420\ns 8\n' $x; done
    printf 's 100\n'
    while [ $x -gt 1522 ]; do x=$((x - 4)); printf 'm 0 %s 420\ns 8\n' $x; done
    printf 's 30\nu 0\ns 500\nu 1\n'
} | touch
sleep 0.5; shot p3-pinned
# 4 a rest
printf 'd 1 300 700\ns 150\nd 0 1538 420\ns 700\nu 0\ns 300\nu 1\n' | touch
sleep 0.5; shot p4-rest
# 5 drag from the far end leftwards
printf 'd 1 300 700\ns 150\nswipe 1538 420 1436 420 200\ns 700\nu 1\n' | touch
sleep 0.5; shot p5-back
# 6 a thumb's tap: 8 px of roll (past the 6 px slop) in 120 ms
printf 'd 1 300 700\ns 150\nd 0 1306 420\ns 40\nm 0 1310 420\ns 40\nm 0 1314 420\ns 40\nu 0\ns 800\nu 1\n' | touch
sleep 0.5; shot p6-roll
# 7 off the pill: 40 px up into the tile above, no x travel
printf 'd 1 300 700\ns 150\nd 0 1340 420\ns 50\nm 0 1340 400\ns 50\nm 0 1340 380\ns 50\nu 0\ns 800\nu 1\n' | touch
sleep 0.5; shot p7-off
# 8 the right end cap
printf 'd 1 300 700\ns 150\nd 0 1536 420\ns 60\nu 0\ns 900\nu 1\n' | touch
sleep 0.5; shot p8-cap
# 9 the chip
printf 'd 1 300 700\ns 150\nd 0 1230 420\ns 60\nu 0\ns 900\nu 1\n' | touch
sleep 0.5; shot p9-chip
# 10 the volume pill: a drag, the shot while the finger rests at its end (ftouch's swipe HOLD)
{ printf 'd 1 300 700\ns 150\nswipe 1374 494 1442 494 200 2500\ns 300\nu 1\n' | touch; } &
fingers=$!                      # wait for this job only: the bed's own KWin / shellbar run in the background too
sleep 1.3; shot p10-volume
wait $fingers
# 11 the outline at both ends: the touch runs in the background, the shots at fixed times from its start (ms):
# down 150, 40 moves left 180-500, 1217 at 600, 1227 at 3100, 1237 at 5600, 37 moves right 8100-8396 (1533),
# 1543 at 10896, up 13396
t0=$(date +%s%N)
at_ms() { d=$(( $1 - ($(date +%s%N) - t0) / 1000000 )); [ $d -gt 0 ] && sleep "$((d / 1000)).$(printf %03d $((d % 1000)))"; true; }
{
    {
        printf 'd 1 300 700\ns 150\nd 0 1530 420\ns 30\n'
        x=1530; while [ $x -gt 1210 ]; do x=$((x - 8)); printf 'm 0 %s 420\ns 8\n' $x; done
        printf 's 100\nm 0 1217 420\ns 2500\nm 0 1227 420\ns 2500\nm 0 1237 420\ns 2500\n'
        x=1237; while [ $x -lt 1533 ]; do x=$((x + 8)); [ $x -gt 1533 ] && x=1533; printf 'm 0 %s 420\ns 8\n' $x; done
        printf 's 2500\nm 0 1543 420\ns 2500\nu 0\ns 300\nu 1\n'
    } | touch
} &
fingers=$!
at_ms 1300; shot o1-2
at_ms 3800; shot o2-5
at_ms 6300; shot o3-8
at_ms 9100; shot o4-95
at_ms 11600; shot o5-98
wait $fingers
wins
expect "y700-control-center/"
verdict "$(python3 - "$OUT" 2> "$OUT/verdict.err" <<'PY'
import sys

import numpy as np
from PIL import Image

out = sys.argv[1]
X0, X1 = 1204, 1544
W = X1 - X0
YY, XX = np.mgrid[0:60, 0:W] + 0.5                # pixel centres in a pill's box, from its top left corner
DY = YY - 30
CHIP = np.hypot(XX - 30, DY) <= 24.5              # the chip (radius 22, 23.3 armed) and its rim: its icon is white
TEXT = (XX > 250) & (XX < W - 17) & (np.abs(DY) <= 13)   # the % text, ending 18 px from the end: white below 82 %
# the distance from the capsule's spine (the segment between the end caps' centres, 30 px in from each end): past 30
# is outside the outline, the first 1.5 px of that the antialiasing
OUTSIDE = np.hypot(XX - np.clip(XX, 30, W - 30), DY) > 31.5


def pic(name):
    return np.asarray(Image.open(f"{out}/{name}.png").convert("RGB"), dtype=int)


def white(im, cy):
    return im[cy - 30:cy + 30, X0:X1].min(axis=2) >= 200


def fill(im, cy):           # the fill's fraction: its rightmost white pixel, the chip's disc and the % text left out
    chip = im[cy, 1218]     # the chip's solid part (centre 1234, radius 22, the icon 1222-1246), not its rim
    if not (chip[0] < 110 and chip[2] > 190):
        print(f"FAIL no pill chip at (1218, {cy}): rgb {tuple(chip)} (the layout moved?)"); sys.exit(1)
    w = white(im, cy) & ~CHIP & ~TEXT
    return float(XX[w].max() + 0.5) / W if w.any() else 0.0


def stray(im, cy):          # white pixels outside the capsule's outline
    return int((white(im, cy) & OUTSIDE).sum())


pnames = ("p0-open", "p1-tap", "p2-drag", "p3-pinned", "p4-rest", "p5-back", "p6-roll", "p7-off", "p8-cap", "p9-chip",
          "p10-volume")
onames = ("o1-2", "o2-5", "o3-8", "o4-95", "o5-98")
try:
    shots = [pic(n) for n in pnames]
    oshots = [pic(n) for n in onames]
except OSError as e:
    print(f"FAIL screenshot missing: {e}"); sys.exit(1)
b = [fill(s, 420) for s in shots[:10]]
v0, v = fill(shots[0], 494), fill(shots[10], 494)
o = [fill(s, 420) for s in oshots]
want = [b[0], 0.30, b[1] + 62 / 340, 1 - 68 / 340, b[3], b[4] - 96 / 340, 110 / 340, b[6], 1.0, 0.0, v0 + 62 / 340]
want += [px / 340 for px in (7, 17, 27, 323, 333)]
got = b + [v] + o
names = ["open", "tap 30", "drag +20", "pinned, back 20", "rest", "drag -30", "roll tap 32", "off the pill", "cap tap 100",
         "chip tap 0", "volume drag +18", "edge 2", "edge 5", "edge 8", "edge 95", "edge 98"]
tol = [0.012] * len(names)  # 4 px: the readout is exact, and a pill that counted the slop would be 6 px (1.8 %) off
tol[9] = 0.015              # the chip tap: the backend floors brightness at 1 %
bad = [f"{n}: {g * 100:.1f} % wanted {w * 100:.1f} %" for n, g, w, t in zip(names, got, want, tol) if abs(g - w) > t]
if b[0] > 0.03:
    bad.insert(0, f"open: the brightness starts at {b[0] * 100:.0f} %, not 0 (the bed has PowerDevil?)")
out_px = [(n, cy, stray(s, cy)) for n, s in zip(pnames + onames, shots + oshots) for cy in (420, 494)]
bad += [f"{n}: {k} white px outside the {'brightness' if cy == 420 else 'volume'} pill's outline"
        for n, cy, k in out_px if k]
shown = " ".join(f"{n} {g * 100:.0f}" for n, g in zip(names, got))
print(("FAIL " + "; ".join(bad) + " | " + shown) if bad else
      f"OK 11 gestures, outline clean in {len(out_px)} pills, " + shown)
PY
)"
