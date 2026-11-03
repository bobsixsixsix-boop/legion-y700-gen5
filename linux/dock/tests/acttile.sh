# sb-bed scenario (11-01): the control centre's 「显示桌面」 and 「多任务」 tiles (Main.qml gridB rows 7-8: 录屏 | 截图,
# 显示桌面 | 多任务, WideTile toggle: false, 60 high two across) against the bed's own KWin: the y700-show-desktop
# shortcut of the control centre's KWin script y700-edge (the bed's KWin loads the installed one: its XDG_DATA_DIRS
# reach ~user/.local/share) and the installed task switcher effect (activeEffects on /Effects; sb-bed.sh loads it).
#   sh ./sb-bed.sh acttile.sh /root/sb-acttile     (root; about 40 s)
# Not installed yet: the bed's control centre reads its QML from the install prefix, so bind it over that in a mount
# namespace of its own (the live session keeps the installed one), and a new y700-edge over the installed script:
#   unshare -m sh -c 'mount --bind NEWQML /usr/local/share/y700-control-center/qml
#       && mount --bind NEWSRC/kwin-script /home/user/.local/share/kwin/scripts/y700-edge && sh ./sb-bed.sh acttile.sh OUT'
# The controls are opened over D-Bus (show), the holding finger is long-pressed on the curtain's empty left half
# (300, 700), as kbtile.sh. Only the two new tiles are tapped, and only when the last shot found them drawn (the
# icons, the titles' widths: four glyphs, three, not 录屏 / 截图's two) and a0's shot found both rows where the change
# puts them: the bed's control centre runs its commands against the real system. Each tap is one real haptic tick on
# the tablet.
# 「显示桌面」 is checked the way y700-shellbar sees it: the app minimized, the dock window mapped, the status bar
# see-through (its in-app backing #0e0f12 faded out). The first version used KWin's Show Desktop, which hides without
# minimizing; KWin's showingDesktop said yes, but the shell stayed in app mode (no dock, the dark bar: review 11-01).
# One way: a second tap on the desktop brings nothing back (KWin's minimizeall toggle, tried next, could bring back
# an app it never put away).
# Steps and shots (OUT/*.png), each shot read by act-look.py (written below into the bed; "act-look NAME: ..." lines):
#   a0-controls   rows 7 and 8 of the thumb column: two tiles each at x 1204-1366 / 1381-1543, the new ones' icons and
#                 titles drawn; the app up, no dock
#   a1-desktop    tap 显示桌面: the curtain closes, the app is minimized, the dock is up, the status bar see-through
#   a2            tap 显示桌面 again on the desktop: nothing comes back
#   a2b-back      the app activated as the dock does it: back, the dock gone, the bar dark (the readings flip back)
#   a3-cards      tap 多任务: the curtain closes, the task cards are up; the shortcut again puts them away
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "acttile.sh: ..." lines are notes.
LOOK=$T/run/act-look.py
cat > "$LOOK" <<'PY'
# act-look.py PNG (acttile.sh writes it into the bed): rows 7-8 of the thumb column off a bed screenshot (1600x1002,
# the controls open). A tile is lighter than the bare curtain: per pixel column, the mean luma of a band inside the
# tiles' straight part (clear of the 18 px corners) minus that of bare curtain in the gap over the row; a run of
# columns above THR is one tile (kbtile.sh's kb-look.py). And the status bar's mean luma (curtain closed).
import sys
import numpy as np
from PIL import Image

img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(np.float32)
luma = img @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
THR = 6.0
X0, X1 = 1190, 1560


def runs(y0, y1, r0, r1):
    lift = luma[y0:y1, X0:X1].mean(axis=0) - luma[r0:r1, X0:X1].mean(axis=0)
    out, start = [], None
    for i, v in enumerate(lift > THR):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((X0 + start, X0 + i - 1))
            start = None
    if start is not None:
        out.append((X0 + start, X1 - 1))
    return " ".join("%d-%d" % r for r in out) or "none"


# row 7, y 726-785: rows 746-766 against the gap over it (712-725). Row 8, y 800-859: rows 820-840 against the gap
# 786-799, which the old layout did not have (one row of 100, 726-825, over both bands: no runs there)
print("ROW7", runs(746, 766, 714, 724))
print("ROW8", runs(820, 840, 788, 798))
# row 8's tiles: the chip's icon (24 px, x+18..x+42) and the title right of the chip (from x+64), y 816-843
for name, x in (("DESK", 1204), ("TASKS", 1381)):
    print("%sICON %d" % (name, int((img[818:842, x + 18:x + 42] > 200).all(axis=2).sum())))
    t = (img[816:844, x + 60:x + 156] > 200).all(axis=2)
    cols = t.any(axis=0).nonzero()[0]
    print("%sTITLEW %d" % (name, int(cols[-1] - cols[0] + 1) if len(cols) else 0))
# the status bar (28 high) between the clock (x 22) and the tray icons (right): #0e0f12 in an app (luma 15)
print("BAR %d" % int(luma[4:24, 300:1300].mean()))
PY
HOLD_AT="300 700"; HOLD_MS=1000
DESK="1285 830"        # 显示桌面's centre, tapped only after a shot found it there (seen)
TASKS="1462 830"       # 多任务's
APP="ts-kate/Kate@"    # the test window in wins

say() { echo "acttile.sh: $*"; echo "acttile.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: acttile.sh: $*"; echo "acttile.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
# KWin's window list now (wins writes it into the log; this reads back the new line)
wl() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -F "sbbed wins:"; }
# the curtain open? (KWin lists the control centre's window only while it is mapped; kbtile.sh's shown)
shown() { wl | grep -qF "y700-control-center/"; }
# the test app minimized? (wins flags it " MIN"; fields are " | " apart)
appmin() { wl | tr '|' '\n' | grep -F "$APP" | grep -q " MIN"; }
# y700-shellbar's dock window mapped? (Dock.qml: the screen's width, 120 high; unmapped once it has slid away)
dockup() { wl | tr '|' '\n' | grep -qE "y700-shellbar/@[0-9]+,[0-9]+\+1600x120( |$)"; }
snap() { shot "$1"; LK=$(python3 "$LOOK" "$OUT/$1.png" 2>&1); echo "$LK" | sed "s/^/act-look $1: /" >> "$LOG"; }
val() { echo "$LK" | sed -n "s/^$1 //p" | head -n 1; }
near() { awk -v r="$1" -v a="$2" -v b="$3" 'BEGIN { split(r, e, "-"); d1 = e[1] - a; d2 = e[2] - b
    if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2; exit !(d1 <= 2 && d2 <= 2) }'; }
two() { set -- $1; [ $# = 2 ] && near "$1" 1204 1366 && near "$2" 1381 1543; }
# the two new tiles drawn: icons in the chips, a title of four glyphs (显示桌面, 16 px each) and one of three (多任务),
# not 录屏 / 截图's two. White strokes, so it reads the same over any background
drawn() {
    [ "$(val DESKICON)" -gt 40 ] && [ "$(val TASKSICON)" -gt 40 ] \
        && [ "$(val DESKTITLEW)" -ge 54 ] && [ "$(val DESKTITLEW)" -le 72 ] \
        && [ "$(val TASKSTITLEW)" -ge 36 ] && [ "$(val TASKSTITLEW)" -le 52 ]
}
# ... and both rows where the change puts them: a0 only. The rows are told by their lift over the gaps between them,
# which needs an even background (a0 has the maximized test window behind the curtain); with the desktop behind it
# the blurred wallpaper's gradient over 14 px exceeds THR and the runs merge (first run, 11-01: read 1190-1543). A later
# step needs the controls up and these two tiles where a0 measured them, which drawn() alone tells
seen() { two "$(val ROW7)" && two "$(val ROW8)" && drawn; }
fx() { busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects activeEffects 2>/dev/null | grep -q '"y700-taskswitcher"'; }
looked() { say "$1 row 7: $(val ROW7); row 8: $(val ROW8); icons $(val DESKICON) / $(val TASKSICON) px, titles $(val DESKTITLEW) / $(val TASKSTITLEW) wide"; }

# ---------------- a0: the layout (and a window to put away)
mark a0
app Kate '#3d7bf7'
cc show; sleep 1.2
shown || bad "a0: the controls did not open (show)"
snap a0-controls
looked a0
if ! seen; then
    bad "a0: rows 7-8 are not 1204-1366 1381-1543 twice with 显示桌面 | 多任务 drawn; nothing tapped"
    cc hide; return 0
fi
appmin && bad "a0: the app is minimized before any tap"
dockup && bad "a0: the dock is up over the app before any tap"

# ---------------- a1: 显示桌面
mark a1
tap $DESK; sleep 1.2
shown && bad "a1: the curtain still open after 显示桌面"
appmin || bad "a1: 显示桌面 did not minimize the app"
dockup || bad "a1: no dock after 显示桌面 (y700-shellbar still in app mode)"
snap a1-desktop
say "a1 status bar luma $(val BAR)"
[ "$(val BAR)" -gt 40 ] || bad "a1: the status bar is still the dark in-app one (luma $(val BAR))"

# ---------------- a2: 显示桌面 again, on the desktop: one way, nothing comes back
mark a2
cc show; sleep 1.2
snap a2-open
looked a2
if drawn; then
    tap $DESK; sleep 1.2
    shown && bad "a2: the curtain still open after 显示桌面"
    appmin || bad "a2: a second tap on the desktop brought the app back"
    dockup || bad "a2: the dock went after a second tap on the desktop"
else
    bad "a2: 显示桌面 | 多任务 not drawn on a2-open; nothing tapped"
    cc hide; sleep 0.8
fi

# ---------------- a2b: the app back the way the dock brings it (y700-shellbar requestActivate = KWin activates it)
mark a2b
eval_js 'var w = workspace.windowList().filter(function (w) { return w.resourceClass == "ts-kate"; })[0]; if (w) workspace.activeWindow = w;'
sleep 1.2
appmin && bad "a2b: the app did not come back when activated"
dockup && bad "a2b: the dock still up over the app"
snap a2b-back
say "a2b status bar luma $(val BAR)"
[ "$(val BAR)" -lt 30 ] || bad "a2b: the status bar is not the in-app one (luma $(val BAR))"

# ---------------- a3: 多任务
mark a3
cc show; sleep 1.2
snap a3-open
looked a3
if drawn; then
    fx && bad "a3: the task cards up before the tap"
    tap $TASKS; sleep 1.5
    shown && bad "a3: the curtain still open after 多任务"
    fx || bad "a3: 多任务 did not bring the task cards up"
    shot a3-cards
    # away again the way the G9 home key's double tap does it
    qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut y700-taskswitcher >/dev/null 2>&1
    sleep 1.2
    fx && bad "a3: the cards still up after the shortcut again"
else
    bad "a3: 显示桌面 | 多任务 not drawn on a3-open; nothing tapped"
    cc hide
fi
say "done (FAIL=$FAIL)"
