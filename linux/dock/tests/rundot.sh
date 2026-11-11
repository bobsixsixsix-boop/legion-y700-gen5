# sb-bed scenario (11-10): the dock's running dots (Dock.qml AppButton). An app with a window open, minimized or
# not, has a 6 px white dot under its icon; one without has none, also when it stays among the recents after its
# window closed. Real apps, started inside the bed (its own display, D-Bus, config and data dirs): Dolphin (pinned by
# default, apps.cpp DEFAULT_PINNED) and Kate (not pinned: it comes in among the recents). ts-app.py windows will not
# do: the task model names a window's app from its process (11-10, a debug run: AppId "python3" whatever the Wayland
# app id), so they never match a dock icon. No icon is tapped (sb-bed.sh: a dock tap with no window to raise would
# start the real app in the owner's session). Steps and shots (OUT/*.png):
#   d0-none     the desktop, no windows: no dot
#   d1-two      both apps up, then minimized: the desktop's dock shows two dots (Dolphin's, Kate's)
#   d2-closed   Kate's window closed: Kate still among the recents (the dock keeps its width), one dot (Dolphin's)
#   d3-inapp    Dolphin raised and the dock revealed over it (B+): one dot
# dots PNG counts the white blobs in the 16 px band under the icons (the dock body is 92 high, 18 above the bottom
# edge; the dot rows are the body's 81..86) and prints "DOTS n x1 x2 ..."; any two dots must sit on icon centres:
# a whole number of icon steps (80 px) apart, plus 22 across the divider (2 px wide, then the row's 20 px spacing;
# the first run, 11-10, had 988.5 and 1090.5: Dolphin, then Kate past the divider). About 40 s.
#   sh ./sb-bed.sh rundot.sh /tmp/y700rd/out      (root; SB_BAR=<a build's bin/y700-shellbar> for a new bar)
say() { echo "rundot.sh: $*"; echo "rundot.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: rundot.sh: $*"; echo "rundot.sh: FAIL $*" >> "$LOG"; FAIL=1; }
dots() {
    python3 - "$1" "$SB_H" <<'PY'
import sys
import numpy as np
from PIL import Image
img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
H = int(sys.argv[2]); top = H - 18 - 92
band = img[top + 80:top + 88]                     # the dot rows 81..86 and a row either side
white = (band.min(axis=2) > 225).any(axis=0)      # a column with a near-white pixel in the band
xs, run = [], []
for x, w in enumerate(list(white) + [False]):
    if w:
        run.append(x)
    elif run:
        if 3 <= len(run) <= 8:                    # a 6 px dot, give or take the edge pixels
            xs.append((run[0] + run[-1]) / 2)
        run = []
print("DOTS %d %s" % (len(xs), " ".join("%.1f" % x for x in xs)))
PY
}
check() {   # check SHOT N: N dots, whole icon steps apart
    l=$(dots "$OUT/$1.png"); say "$1: $l"
    case $l in "DOTS "*) ;; *) bad "$1: no DOTS line from the counter"; return ;; esac
    set -- "$1" "$2" $l
    [ "$4" = "$2" ] || { bad "$1: $4 dots, want $2"; return; }
    shift 4
    [ $# -lt 2 ] && return
    a=$1; shift
    for b in "$@"; do
        awk -v a="$a" -v b="$b" 'BEGIN { d = (b - a) % 80; if (d < 0) d += 80
            exit !(d <= 1 || d >= 79 || (d >= 21 && d <= 23)) }' \
            || bad "dots at $a and $b are not on icon centres (80 px steps, plus 22 across the divider)"
    done
}
# up CLASS: wait (up to 15 s) for a window of that app
up() {
    i=0
    while [ $i -lt 30 ]; do
        n0=$(wc -l < "$LOG")
        eval_js "print('rundot up ' + workspace.stackingOrder.filter(w => w.resourceClass == '$1' && w.normalWindow).length)"
        tail -n +$((n0 + 1)) "$LOG" | grep -q "rundot up [1-9]" && return 0
        sleep 0.2; i=$((i + 1))
    done
    bad "$1 did not come up"; return 1
}

sleep 1
shot d0-none
check d0-none 0

mark two
kate -n >> "$LOG" 2>&1 &
KATE=$!
up org.kde.kate
dolphin >> "$LOG" 2>&1 &
DOLPHIN=$!
up org.kde.dolphin
sleep 1.5
eval_js 'workspace.stackingOrder.filter(w => w.resourceClass == "org.kde.kate" || w.resourceClass == "org.kde.dolphin").forEach(w => w.minimized = true)'
sleep 1.2
wins
expect "y700-shellbar/@0,882"
shot d1-two
check d1-two 2

mark closed
eval_js 'workspace.stackingOrder.filter(w => w.resourceClass == "org.kde.kate").forEach(w => w.closeWindow())'
sleep 1.5
wins
reject "org.kde.kate/"
shot d2-closed
check d2-closed 1
# Kate is still in the dock (among the recents), only its dot went: Dolphin's dot did not move
c1=$(dots "$OUT/d1-two.png" | awk '{ print $3 }'); c2=$(dots "$OUT/d2-closed.png" | awk '{ print $3 }')
[ -n "$c1" ] && [ "$c1" = "$c2" ] || bad "Dolphin's dot moved from '$c1' to '$c2': the dock changed when Kate's window closed"

mark inapp
eval_js 'workspace.stackingOrder.filter(w => w.resourceClass == "org.kde.dolphin").forEach(w => { w.minimized = false; workspace.activeWindow = w; })'
sleep 1
sbcall reveal
sleep 0.9
eval_js 'print("rundot active " + (workspace.activeWindow ? workspace.activeWindow.resourceClass : "none"))'
wins
expect "rundot active org.kde.dolphin"
expect "y700-shellbar/@0,882"
shot d3-inapp
check d3-inapp 1

kill $KATE $DOLPHIN 2>/dev/null
