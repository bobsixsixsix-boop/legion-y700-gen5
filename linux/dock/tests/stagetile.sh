# sb-bed scenario (11-08): the control centre's 「台前调度」 tile (Main.qml gridB row 6: 刷新率 | 性能浮层 | 台前调度 | 分屏,
# four across at ctl.quarter = 74.5 since 11-10, three at ctl.third = 104 before) against the bed's own KWin running the INSTALLED Stage
# Manager script (linux/stage/install.sh: ~user/.local/share/kwin/scripts/y700-stage, which the bed's XDG_DATA_DIRS
# reach; the build is the live kwinrc's BuildId, read here and written into the bed's kwinrc). The tile writes the bed's
# kwinrc (XDG_CONFIG_HOME) and calls the shortcut on the bed's bus: nothing reaches the live session.
#   SB_CC=/opt/y700-stagecc/bin/y700-control-center sh ./sb-bed.sh stagetile.sh /root/sb-stagetile     (root; about 50 s)
# Only the stage tile is tapped, and only where the last shot found it (row 6 four across at 1204 / 1293 / 1381 / 1470,
# its icon, a four-glyph title): 刷新率 and 性能浮层 beside it switch the REAL system (分屏 is splittile.sh's). The holding finger is long-pressed on the
# curtain's empty left half (300, 700), as acttile.sh. Each tap is one real haptic tick on the tablet.
# Steps and shots (OUT/*.png, each read by st-look.py, written below into the bed; "st-look NAME: ..." lines):
#   s0-controls   row 6 four across, the stage tile drawn and dark; the script loaded and off, the test app as it was
#   s1-on         tap: kwinrc Active=true, the script says "on, 1 windows" (the app only: the control centre, the bar
#                 and the dock are no windows it takes), the curtain stays (a toggle), and 6 s on (past the 1.5 s the
#                 optimistic value is held and a status poll) the tile still lit: the status reads it back
#   s2-off        tap again: Active=false, "off, restored", the tile dark after 6 s
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "stagetile.sh: ..." lines are notes.
LOOK=$T/run/st-look.py
cat > "$LOOK" <<'PY'
# st-look.py PNG (stagetile.sh writes it into the bed): row 6 of the thumb column off a bed screenshot (1600x1002, the
# controls open). A tile is lighter than the bare curtain: per pixel column, the mean luma of a band inside the tiles'
# straight part (clear of the 18 px corners) minus that of bare curtain in the gap under the row (acttile.sh's
# act-look.py); a run of columns above THR is one tile.
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
# the stage tile (x 1381, 74.5 wide): its chip's icon (26 px around x+37, y 652) and title (y 682-702); the overlay
# tile's title width too (four glyphs in every state since 11-10, 64 px: it must stay inside 74.5)
print("STAGEICON %d" % int((img[640:665, 1406:1430] > 200).all(axis=2).sum()))
for name, x in (("STAGE", 1381), ("HUD", 1293)):
    t = (img[682:702, x:x + 74] > 200).all(axis=2)
    cols = t.any(axis=0).nonzero()[0]
    print("%sTITLEW %d" % (name, int(cols[-1] - cols[0] + 1) if len(cols) else 0))
# lit: the accent #2e6bf6 (opaque) fills the tile; the mean distance from it left of the chip (x+3..x+11: the chip
# is x+13..x+61 at 74.5 wide, y 628-676), clear of the corners (11-08 bed: lit 0, dark 34 over the blue test app). Not
# "how blue": the bed's test app is blue, and the dark tile (white 12 % over its blur) reads blue too
band = img[640:676, 1384:1392]
print("OFFACCENT %d" % int(np.abs(band - np.array([46, 107, 246], dtype=np.float32)).mean()))
PY
HOLD_AT="300 700"; HOLD_MS=1000
STAGE="1418 662"       # the stage tile's centre, tapped only after a shot found it there (seen)
LIVE=$HOME/.local/share/kwin/scripts/y700-stage

say() { echo "stagetile.sh: $*"; echo "stagetile.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: stagetile.sh: $*"; echo "stagetile.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
wl() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -F "sbbed wins:"; }
shown() { wl | grep -qF "y700-control-center/"; }
snap() { shot "$1"; LK=$(python3 "$LOOK" "$OUT/$1.png" 2>&1); echo "$LK" | sed "s/^/st-look $1: /" >> "$LOG"; }
val() { echo "$LK" | sed -n "s/^$1 //p" | head -n 1; }
near() { awk -v r="$1" -v a="$2" -v b="$3" 'BEGIN { split(r, e, "-"); d1 = e[1] - a; d2 = e[2] - b
    if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2; exit !(d1 <= 2 && d2 <= 2) }'; }
four() { set -- $1; [ $# = 4 ] && near "$1" 1204 1278 && near "$2" 1293 1366 && near "$3" 1381 1455 && near "$4" 1470 1543; }
drawn() { [ "$(val STAGEICON)" -gt 40 ] && [ "$(val STAGETITLEW)" -ge 54 ] && [ "$(val STAGETITLEW)" -le 72 ]; }
looked() { say "$1 row 6: $(val ROW6); stage icon $(val STAGEICON) px, title $(val STAGETITLEW) wide, overlay title $(val HUDTITLEW) wide, off the accent by $(val OFFACCENT)"; }
active() { kreadconfig6 --file kwinrc --group Script-y700-stage --key Active; }

# ---------------- the installed script into the bed's KWin
BID=$(kreadconfig6 --file $HOME/.config/kwinrc --group Script-y700-stage --key BuildId)
if [ -z "$BID" ] || [ ! -f "$LIVE/contents/build-$BID/ui/Stage.qml" ]; then
    bad "y700-stage is not installed (linux/stage/install.sh); nothing tapped"; return 0
fi
kwriteconfig6 --file kwinrc --group Plugins --key y700-stageEnabled true
kwriteconfig6 --file kwinrc --group Script-y700-stage --key BuildId "$BID"
mark s0
qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1
sleep 1.5
expect 'y700-stage: loaded, off'

# ---------------- s0: the layout
app Kate '#3d7bf7'
cc show; sleep 1.2
shown || bad "s0: the controls did not open (show)"
snap s0-controls
looked s0
if ! four "$(val ROW6)" || ! drawn; then
    bad "s0: row 6 is not 1204-1278 1293-1366 1381-1455 1470-1543 with 台前调度 drawn; nothing tapped"
    cc hide; return 0
fi
[ "$(val HUDTITLEW)" -le 70 ] || bad "s0: the overlay tile's title is $(val HUDTITLEW) wide, over its 74.5 less 2 x 2"
[ "$(val OFFACCENT)" -gt 16 ] || bad "s0: the stage tile lit before any tap (off the accent by $(val OFFACCENT))"

# ---------------- s1: on
mark s1
tap $STAGE; sleep 1.5
expect 'y700-stage: on, 1 windows'
[ "$(active)" = true ] || bad "s1: kwinrc Active is '$(active)', not true"
shown || bad "s1: the curtain closed (the tile is a toggle)"
sleep 4.5
snap s1-on
looked s1
[ "$(val OFFACCENT)" -le 8 ] || bad "s1: the stage tile dark 6 s after turning it on (off the accent by $(val OFFACCENT)): the status does not read Active back"
reject 'toast: 台前调度失败'

# ---------------- s2: off
mark s2
if drawn; then
    tap $STAGE; sleep 1.5
    expect 'y700-stage: off, restored'
    [ "$(active)" = false ] || bad "s2: kwinrc Active is '$(active)', not false"
    sleep 4.5
    snap s2-off
    looked s2
    [ "$(val OFFACCENT)" -gt 16 ] || bad "s2: the stage tile still lit 6 s after turning it off (off the accent by $(val OFFACCENT))"
    reject 'toast: 台前调度失败'
else
    bad "s2: 台前调度 not drawn on s1-on; nothing tapped"
fi
cc hide
say "done (FAIL=$FAIL)"
