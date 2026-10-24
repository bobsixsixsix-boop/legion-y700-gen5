# sb-bed scenario (10-22): the dock's frosted glass while the task switcher's cards leave for the desktop.
# On the real screen KWin blurs what is behind the dock's body (the dock asks for it, org_kde_kwin_blur). While the
# switcher effect is up it paints the dock itself, a WindowThumbnail on its desktop layer, and until 10-22 that copy
# had no blur: see-through while the cards left, frosted the moment the effect ended and KWin painted the real
# window (seen on the tablet: clear first, blurred only after the cards were gone). The fix, PanelGlass in
# linux/gesture/taskswitcher/ui/TaskSwitcher.qml, blurs the scene under the dock inside the effect.
# Here: an app, minimized (the dock on the plain desktop: KWin's blur is the reference), the cards opened from the
# desktop by the edge gesture, then a burst of frames (capseq.py) while a bottom-edge swipe sends them away.
# Verdict, one line, in OUT/dock-glass.txt: in every frame the dock's glass rim (x 600-740 and 860-1000, y 895-906:
# clear of the icons and of the close-all X at x 780-820) must be about as blurred as the reference, and the band
# left of the dock's body must sharpen together with the wallpaper above it (the glass must not leak over the whole
# band). The switcher's state is checked at each step (KWin's activeEffects), so the frames are known to be the
# leave. Needs a wallpaper with texture under the dock's rim: dock-glass-run.sh (root) makes one, runs this and
# records the verdict for y700-checklist; the bed's default wallpaper is flat there and fails the texture check.
# GLASS_FRAMES: frames in the burst (90 = 2.5-4 s: the bed renders at 20-50 fps depending on load, and 40 frames once
# ended at 0.8 s, before the cards had left). sb-bed.sh passes it and CAPSEQ through its env -i.
CAPSEQ=${CAPSEQ:-/usr/local/share/y700-control-center/tests/capseq.py}
N=${GLASS_FRAMES:-90}
# one line into OUT/dock-glass.txt; nothing (the analysis died: its traceback is in OUT/verdict.err) is a FAIL too
verdict() {
    [ -n "$1" ] || set -- "FAIL the analysis printed no verdict (its traceback: $OUT/verdict.err)"
    echo "$*" > "$OUT/dock-glass.txt"; echo "dock-glass: $*"; case "$1" in FAIL*) FAIL=1 ;; esac
}
fx_active() { busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects activeEffects 2>/dev/null | grep -q y700-taskswitcher; }
glass_main() {
    [ -f "$CAPSEQ" ] || { verdict "FAIL no $CAPSEQ (sh linux/controlpanel/y700-control-center/install.sh)"; return 0; }
    # the bed's output, for capseq.py's CaptureScreen (the virtual backend names it; the tablet's is DSI-1)
    eval_js 'print("sbbed screens: " + workspace.screens.map(s => s.name).join(" "))'
    SCREEN=$(grep -o 'sbbed screens: .*' "$LOG" | tail -1 | cut -d' ' -f3)
    [ -n "$SCREEN" ] || { verdict "FAIL the bed's KWin did not name its output (eval_js)"; return 0; }
    app Kate '#3d7bf7'
    sleep 1
    # to the desktop without the home flick: a flick's speed is measured in wall-clock time (Stack.velocity), and the
    # bed renders in software, so a flick there can read as a slow swipe and open the cards instead
    eval_js 'workspace.stackingOrder.filter(w => w.caption == "Kate").forEach(w => { w.minimized = true; })'
    sleep 1.5
    wins
    expect "Kate@0,28+1600x974 MIN"
    expect "y700-shellbar/@0,882"
    if fx_active; then verdict "FAIL the switcher is active on the plain desktop, before the cards"; return 0; fi
    shot 01-desktop
    # the cards from the desktop: a bottom-edge swipe, hold, lift (dock-glass-real.sh deskrecents, the path that showed it)
    mark cards
    touch <<'T'
swipe 800 1001 800 840 350 600
T
    sleep 1.6
    expect "y700-taskswitcher: open from the desktop"
    if ! fx_active; then verdict "FAIL the cards did not open from the desktop (the switcher is not active)"; return 0; fi
    shot 02-cards
    # the burst, then the leave: a bottom-edge swipe of 140 px while the cards are up
    rm -rf "$OUT/glass"
    python3 "$CAPSEQ" "$OUT/glass" "$N" "$SCREEN" 300 890 1300 990 > "$OUT/capseq.log" 2>&1 &
    cap=$!
    sleep 0.6
    touch <<'T'
swipe 800 1001 800 860 250 150
T
    wait $cap
    sleep 0.5
    wins
    expect "y700-shellbar/@0,882"
    if fx_active; then verdict "FAIL the cards did not leave for the desktop (the switcher is still active)"; return 0; fi
    shot 03-after
    verdict "$(python3 - "$OUT" 2> "$OUT/verdict.err" <<'PY'
import glob
import os
import sys

import numpy as np
from PIL import Image

out = sys.argv[1]


def gray(p):
    return np.asarray(Image.open(p).convert("L"), dtype=np.float64)


def sharp(g, x0, y0, x1, y1):      # variance of the Laplacian, as capseq.py
    r = g[y0:y1, x0:x1]
    lap = -4 * r[1:-1, 1:-1] + r[:-2, 1:-1] + r[2:, 1:-1] + r[1:-1, :-2] + r[1:-1, 2:]
    return float(lap.var())


def rim(g):        # the dock's glass rim, either side of the close-all X
    return max(sharp(g, 600, 895, 740, 906), sharp(g, 860, 895, 1000, 906))


def beside(g):     # the band left of the dock's body: wallpaper, no glass
    return sharp(g, 100, 895, 400, 906)


def above(g):      # the wallpaper just above the dock's band
    return sharp(g, 100, 862, 400, 880)


def wall_mean(g):  # wallpaper under the cards' tint
    return float(g[300:500, 100:400].mean())


def edge(g):       # the blur's size: the wallpaper's step at x 800 (dock-glass-run.sh), smeared under the dock
    # width of the ramp = the step outside the dock (x 0.7, the body's tint) over the steepest slope inside it,
    # the slope taken over 24 px; a Gaussian's sigma x 2.5. The 11 rows, the 31 px window and the 24 px span
    # average KWin's noise (NoiseStrength) and the wallpaper's out. Sharp: ~31 (the window); the real dock, KWin's
    # blur at strength 12 (5 passes of dual kawase, offset 3): hundreds
    p = g[895:906, :].mean(axis=0)
    s = np.convolve(p, np.ones(31) / 31, mode="same")
    step = 0.7 * abs(s[1200:1500].mean() - s[100:400].mean())
    r = s[600:1000]
    slope = np.abs(r[24:] - r[:-24]).max() / 24
    return float(step / slope) if slope > 0 else 0.0


try:
    ref = gray(f"{out}/01-desktop.png")
except OSError as e:
    print(f"FAIL screenshot missing: {e}")
    sys.exit(0)
ref_rim, ref_beside, ref_above = rim(ref), beside(ref), above(ref)
if ref_above < 60 or ref_beside < 60:
    print(f"FAIL the wallpaper is flat beside the dock (sharpness {ref_beside:.0f} / {ref_above:.0f}): run through dock-glass-run.sh (SB_WALL)")
    sys.exit(0)
# the reference must be KWin's blur, not the tinted sharp wallpaper: otherwise the limit is in the thousands and a
# see-through dock passes (the bed's blur effect off, or the dock's blur region not honoured)
if ref_rim > 0.25 * ref_beside:
    print(f"FAIL the reference dock is not blurred in the bed (rim {ref_rim:.0f} against wallpaper {ref_beside:.0f}): KWin's blur did not paint it")
    sys.exit(0)
frames = sorted(glob.glob(f"{out}/glass/f*.png"))
if len(frames) < 10:
    print(f"FAIL only {len(frames)} frames captured (capseq.log)")
    sys.exit(0)
lim = max(4 * ref_rim, ref_rim + 30)
ref_edge = edge(ref)
times = {}
for line in open(f"{out}/glass/frames.txt"):
    if line[0] != "#":
        p = line.split()
        times[int(p[0])] = p[1]          # frames.txt counts 0, 1, 2; the files are f000, f001, f002
bad, leak, light, rims, edges = [], [], [], [], []
for f in frames:
    g = gray(f)
    name = os.path.basename(f)[:-4]
    r = rim(g)
    rims.append(r)
    if r > lim:
        bad.append(f"{name}@{times.get(int(name[1:]), '?')}ms({r:.0f})")
    if above(g) > 0.5 * ref_above and beside(g) < 0.2 * above(g):
        leak.append(name)
    # once the cards are gone (the wallpaper beside the dock sharp and untinted) the glass must be about as heavy
    # as KWin's blur, or the dock visibly changes when the effect ends and KWin's own takes over (10-22: a
    # visible jump from a light blur to the heavy one). The frames after the effect ended are KWin's dock = reference
    if beside(g) > 0.5 * ref_beside and abs(wall_mean(g) - wall_mean(ref)) <= 6:
        e = edge(g)
        edges.append(e)
        if not 0.7 * ref_edge <= e <= 1.5 * ref_edge:
            light.append(f"{name}({e:.0f})")
last = gray(frames[-1])
if beside(last) < 0.5 * ref_beside or abs(wall_mean(last) - wall_mean(ref)) > 6:
    print(f"FAIL the burst ended before the cards had left ({len(frames)} frames, last at {times.get(int(os.path.basename(frames[-1])[1:-4]), '?')} ms)")
    sys.exit(0)
if bad:
    print(f"FAIL {len(bad)} of {len(frames)} frames show the dock's rim sharp (limit {lim:.0f}, reference {ref_rim:.1f}): "
          + " ".join(bad[:6]))
elif leak:
    print(f"FAIL the glass covers the band beside the dock in {len(leak)} frames (mask): " + " ".join(leak[:6]))
elif light:
    print(f"FAIL the glass is not as heavy as KWin's blur in {len(light)} frames (blur edge, reference {ref_edge:.0f}, "
          f"wanted 0.7-1.5 x): " + " ".join(light[:6]))
else:
    print(f"OK {len(frames)} frames, the dock's rim blurred throughout (max {max(rims):.1f}, reference {ref_rim:.1f}, limit {lim:.0f}; "
          f"blur edge {min(edges):.0f}-{max(edges):.0f}, reference {ref_edge:.0f})")
PY
)"
}
glass_main
