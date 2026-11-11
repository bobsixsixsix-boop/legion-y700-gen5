# sb-bed scenario (11-10): the control centre's 「分屏」 tile (Main.qml gridB row 6, four across at ctl.quarter = 74.5:
# 刷新率 | 性能浮层 | 台前调度 | 分屏) against the bed's own KWin running a checkout of the split screen script:
#   SB_SPLIT=/tmp/y700sp2/linux/split/y700-split SB_CC=/opt/y700-splitcc/bin/y700-control-center \
#     sh ./sb-bed.sh splittile.sh /root/sb-splittile     (root; chmod -R a+rX the checkout first: the bed runs as user)
# (copied into the bed's own XDG_DATA_HOME and loaded there by path, as install.sh's first install; no BuildId, so
# its main.qml loads contents/ui/Split.qml). The tile calls the shortcut on the bed's bus and the stage step writes the bed's kwinrc:
# nothing reaches the live session.
# Only the split tile is tapped, and only where the last shot found it (row 6 four across at 1204 / 1293 / 1381 / 1470,
# its icon, a short title): the three beside it switch the REAL system. The holding finger is long-pressed on the
# curtain's empty left half (300, 700), as acttile.sh. Each tap is one real haptic tick on the tablet.
# Steps and shots (OUT/*.png, each read by sp-look.py, written below into the bed; "sp-look NAME: ..." lines):
#   p0-controls   row 6 four across, each title inside its tile (four glyphs at most: 64 px of 74.5), the split
#                 icon drawn
#   p1-pick       tap: the curtain goes (an action), the script takes the app it leaves to: Kate on the left half,
#                 the picker on the right (state pick); a tap on the picker's blank: back to full screen (cancel)
#   p2-stage      the stage manager on (the bed's kwinrc Active=true, read back by the status): the tile dimmed, and a
#                 tap only says so (the control centre's toast), the curtain stays, the script is not called
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "splittile.sh: ..." lines are notes.
LOOK=$T/run/sp-look.py
cat > "$LOOK" <<'PY'
# sp-look.py PNG (splittile.sh writes it into the bed): row 6 of the thumb column off a bed screenshot (1600x1002, the
# controls open). A tile is lighter than the bare curtain: per pixel column, the mean luma of a band inside the tiles'
# straight part (clear of the 18 px corners) minus that of bare curtain in the gap under the row (stagetile.sh's
# st-look.py); a run of columns above THR is one tile.
import sys
import numpy as np
from PIL import Image

img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(np.float32)
luma = img @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
THR = 6.0
X0, X1 = 1190, 1560
lift = luma[632:692, X0:X1].mean(axis=0) - luma[714:724, X0:X1].mean(axis=0)
out, start = [], None
for i, v in enumerate(lift > THR):
    if v and start is None:
        start = i
    elif not v and start is not None:
        out.append((X0 + start, X0 + i - 1))
        start = None
if start is not None:
    out.append((X0 + start, X1 - 1))
print("ROW6", " ".join("%d-%d" % r for r in out) or "none")
# the chips' icons (26 px around the tile's middle, y 639-665): white pixels; the stage and split ones
for name, x in (("STAGE", 1381), ("SPLIT", 1470)):
    c = int(round(x + 37.25))
    print("%sICON %d" % (name, int((img[640:665, c - 12:c + 12] > 200).all(axis=2).sum())))
# each title (y 682-702): its first and last white column, relative to its tile's left edge (inside = 1..73)
for i, x in enumerate((1204, 1293, 1381, 1470)):
    t = (img[682:702, x:x + 75] > 200).all(axis=2)
    cols = t.any(axis=0).nonzero()[0]
    print("TITLE%d %s" % (i, "%d-%d" % (cols[0], cols[-1]) if len(cols) else "none"))
PY
HOLD_AT="300 700"; HOLD_MS=1000
SPLIT="1507 662"       # the split tile's centre, tapped only after a shot found it there (seen)

say() { echo "splittile.sh: $*"; echo "splittile.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: splittile.sh: $*"; echo "splittile.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
wl() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -F "sbbed wins:"; }
shown() { wl | grep -qF "y700-control-center/"; }
snap() { shot "$1"; LK=$(python3 "$LOOK" "$OUT/$1.png" 2>&1); echo "$LK" | sed "s/^/sp-look $1: /" >> "$LOG"; }
val() { echo "$LK" | sed -n "s/^$1 //p" | head -n 1; }
near() { awk -v r="$1" -v a="$2" -v b="$3" 'BEGIN { split(r, e, "-"); d1 = e[1] - a; d2 = e[2] - b
    if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2; exit !(d1 <= 2 && d2 <= 2) }'; }
four() { set -- $1; [ $# = 4 ] && near "$1" 1204 1278 && near "$2" 1293 1366 && near "$3" 1381 1455 && near "$4" 1470 1543; }
# a title inside its tile: some glyph drawn, at least 2 px clear of either edge (74.5 wide: 1..73 is the tile)
inside() { r=$(val "TITLE$1"); [ "$r" != none ] && [ "${r%-*}" -ge 2 ] && [ "${r#*-}" -le 72 ]; }
looked() { say "$1 row 6: $(val ROW6); titles $(val TITLE0) $(val TITLE1) $(val TITLE2) $(val TITLE3); stage icon $(val STAGEICON) px, split icon $(val SPLITICON) px"; }
kate() { eval_js 'workspace.windowList().filter(w => w.caption === "Kate").forEach(w => { const g = w.frameGeometry; print("sbbed kate " + Math.round(g.x) + "," + Math.round(g.y) + " " + Math.round(g.width) + "x" + Math.round(g.height) + (w.minimized ? " min" : "") + (w.maximizeMode === 3 ? " max" : "") + " |") })'; }
lastkate() { tail -n +$((MARK + 1)) "$LOG" | grep -o 'sbbed kate .*' | tail -n 1; }
iw() { eval_js 'workspace.windowList().filter(w => /^y700-split /.test(w.caption)).forEach(w => { const g = w.frameGeometry; print("sbbed iw " + w.caption + " " + Math.round(g.x) + "," + Math.round(g.y) + " " + Math.round(g.width) + "x" + Math.round(g.height) + " |") })'; }

# ---------------- the candidate script into the bed's KWin
if [ -z "${SB_SPLIT:-}" ] || [ ! -f "$SB_SPLIT/contents/ui/Split.qml" ]; then
    bad "SB_SPLIT='${SB_SPLIT:-}' has no contents/ui/Split.qml; nothing tapped"; return 0
fi
mkdir -p "$T/data/kwin/scripts" && cp -r "$SB_SPLIT" "$T/data/kwin/scripts/y700-split"
kwriteconfig6 --file kwinrc --group Plugins --key y700-splitEnabled true
kwriteconfig6 --file kwinrc --group Script-y700-split --key Debug true
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active false
mark p0
# by path, as install.sh's first install: the bed's KWin read its package list at start, before this copy, and
# Enabled + reconfigure loads nothing it has not seen (11-10). Under its name, so [Script-y700-split] is its config
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadDeclarativeScript ss \
    "$T/data/kwin/scripts/y700-split/contents/ui/main.qml" y700-split >/dev/null 2>&1
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting start >/dev/null 2>&1
sleep 1.5
expect 'y700-split: loaded'

# ---------------- p0: the layout
app Kate '#3d7bf7'
kate
K0=$(lastkate); say "p0 $K0"
cc show; sleep 1.2
shown || bad "p0: the controls did not open (show)"
snap p0-controls
looked p0
if ! four "$(val ROW6)" || [ "$(val SPLITICON)" -le 40 ]; then
    bad "p0: row 6 is not 1204-1278 1293-1366 1381-1455 1470-1543 with the split icon drawn; nothing tapped"
    cc hide; return 0
fi
for i in 0 1 2 3; do inside $i || bad "p0: tile $i's title at $(val TITLE$i), not inside 2..72"; done
[ "$(val STAGEICON)" -gt 40 ] || bad "p0: the stage icon not drawn ($(val STAGEICON) px)"

# ---------------- p1: into the picker, and out of it
mark p1
tap $SPLIT; sleep 2
shown && bad "p1: the curtain stayed (the tile is an action)"
kate; iw
shot p1-pick
expect 'y700-split: state pick mode=pick pair= pick=Kate/0'
expect 'sbbed kate 0,'
reject 'y700-split: toast'
reject 'toast: 分屏失败'
mark p1-cancel
# one finger: the picker is KWin's own window (no client to miss a first touch), and KWin gives every later finger to
# the surface the first one went to, so tap()'s holding finger at 300,700 (now on Kate's half) would take this one
# to Kate too (11-10: the cancel went nowhere)
printf 'd 0 1300 560\ns 70\nu 0\n' | touch; sleep 1.2
kate
expect 'y700-split: state cancel mode=off'
[ "$(lastkate)" = "$K0" ] || bad "p1: Kate after the cancel is '$(lastkate)', not as before ('$K0')"

# ---------------- p2: the stage manager on
mark p2
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active true
cc show; sleep 6   # past a status poll: st.stage read back from the bed's kwinrc
snap p2-stage
looked p2
[ "$(val SPLITICON)" -le 10 ] || bad "p2: the split tile not dimmed with the stage manager on (icon $(val SPLITICON) px white)"
if four "$(val ROW6)"; then
    tap $SPLIT; sleep 1
    expect 'toast: 台前调度开着，把卡片拖到舞台上就能并排'
    shown || bad "p2: the curtain closed (the dimmed tile only says why)"
    reject 'y700-split: state'
    reject 'y700-split: toast'
else
    bad "p2: row 6 not found on p2-stage; nothing tapped"
fi
cc hide
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active false
say "done (FAIL=$FAIL)"
