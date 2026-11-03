# sb-bed scenario (10-30): the control centre's 「键盘」 tile (Main.qml colATop: 旁路供电 | 手电筒 | 键盘, three across
# like the tray tiles under them) against fake-osk.py (the keyboard's D-Bus name on the bed's bus, see its header) and
# fake-sni.py (tray items, so the tray tiles are there to line up with).
#   SB_CC=/opt/y700-kbtile/bin/y700-control-center sh ./sb-bed.sh kbtile.sh /root/sb-kbtile     (root; about a minute)
# fake-osk.py is up before anything is tapped: with nobody on fyi.fortime.Fcitx5Osk the tile's call would start the
# real y700-osk inside the bed (sb-bed.sh's note). The controls are opened over D-Bus (show), the holding finger is
# long-pressed on the curtain's empty left half (300, 700), as tray.sh. Nothing is tapped but the keyboard tile, and
# only where the last shot found it (its place in the row, its icon, a two-glyph title); a first tap that reached no
# keyboard ends the taps: the bed's control centre switches the REAL system (torch, bypass, Tailscale next to it).
# Every tap is one real haptic tick on the tablet (the bed's control centre opens the motors too).
# Steps and shots (OUT/*.png), each shot read by kb-look.py (written below into the bed; "kb-look NAME: ..." lines):
#   k0-controls   the far column's first row = three tiles at x 840 / 958 / 1076, 104 wide (the thumb column's first
#                 row still two, 163 wide), the tray tiles' columns the same three, the keyboard icon and title drawn
#   k1-ok         tap: one ForceShow, the curtain closes (the keyboard said yes); no toast
#   k2-fail       fake refuses: the toast 「键盘失败：…」, the curtain stays open, the tile back to full strength
#   k3-busy       fake mute: the tile dims while the call is out and a second tap sends nothing; busctl gives up after
#                 3 s: the toast, the curtain stays open, the tile back
#   k4-late       fake answers yes 2 s late; meanwhile the curtain closed and opened again: that late yes must not
#                 close the new opening
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "kbtile.sh: ..." lines are notes.
FK=$T/bin/fake-osk.py
FS=$T/bin/fake-sni.py
LOOK=$T/run/kb-look.py
if [ ! -f "$FK" ] || [ ! -f "$FS" ]; then
    echo "SBBED_EXPECT_FAIL: kbtile.sh: no $FK or $FS (sb-bed.sh copies them from its own directory)"; FAIL=1; return 0
fi
cat > "$LOOK" <<'PY'
# kb-look.py PNG (kbtile.sh writes it into the bed): the first row of both columns and the tray tiles off a bed
# screenshot (1600x1002, the controls open). A tile is lighter than the bare curtain (white at 12 % over the tinted
# blur): per pixel column, the mean luma of a band of rows inside the tiles' straight part (clear of the 18 px corners)
# minus that of bare curtain at the same x just above or below; a run of columns above THR is one tile.
import sys
import numpy as np
from PIL import Image

img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(np.float32)
luma = img @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
THR = 6.0
X0, X1 = 820, 1560


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
    return out, lift


def fmt(rs):
    return " ".join("%d-%d" % r for r in rs) or "none"


# the first row, y 162-262 (both columns): rows 182-242; bare curtain between the header and the controls, y 140-156
r1, lift = runs(182, 242, 140, 156)
print("ROW1", fmt(r1))
# the tray's first row of tiles, y 377-461: rows 397-441; bare curtain in the gap under it, y 463-473
rt, _ = runs(397, 441, 463, 474)
print("TRAY", fmt([r for r in rt if r[1] < 1190]))
# the keyboard tile (x 1076-1180): its lift left of the chip (x 1082-1098); the icon's white strokes in the chip
# (48 at x 1104-1152, y 178-226) and the title's (y 232-252)
print("KBLIFT %.1f" % float(lift[1082 - X0:1099 - X0].mean()))
print("ICON %d" % int((img[178:227, 1104:1153] > 200).all(axis=2).sum()))
t = (img[232:253, 1080:1176] > 200).all(axis=2)
print("TITLE %d" % int(t.sum()))
# the title's width: two glyphs of 16 px (键盘, about 32) and not three or four (手电筒 48, 旁路供电 64): the one
# reading that tells the keyboard tile from the toggles that could sit in its place
cols = t.any(axis=0).nonzero()[0]
print("TITLEW %d" % (int(cols[-1] - cols[0] + 1) if len(cols) else 0))
PY
HOLD_AT="300 700"; HOLD_MS=1000
KB="1128 212"          # the keyboard tile's centre, tapped only after a shot found the tile there (row1ok)

say() { echo "kbtile.sh: $*"; echo "kbtile.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: kbtile.sh: $*"; echo "kbtile.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
mode() { busctl --user call fyi.y700.FakeOsk /FakeOsk fyi.y700.FakeOsk SetMode s "$1" >/dev/null 2>&1 || say "mode $1 failed"; }
cnt() { tail -n +$((MARK + 1)) "$LOG" | grep -cF -- "$1"; }
waitfor() {
    tw=0
    while [ "$(cnt "$1")" -lt "${2:-1}" ]; do
        tw=$((tw + 1)); [ $tw -gt $((${3:-5} * 5)) ] && return 1
        sleep 0.2
    done
}
# the curtain open? (KWin lists the control centre's window only while it is mapped; tray.sh's shown)
shown() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -qF "y700-control-center/"; }
snap() { shot "$1"; LK=$(python3 "$LOOK" "$OUT/$1.png" 2>&1); echo "$LK" | sed "s/^/kb-look $1: /" >> "$LOG"; }
val() { echo "$LK" | sed -n "s/^$1 //p" | head -n 1; }
# run A-B within 2 px of the expected edges
near() { awk -v r="$1" -v a="$2" -v b="$3" 'BEGIN { split(r, e, "-"); d1 = e[1] - a; d2 = e[2] - b
    if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2; exit !(d1 <= 2 && d2 <= 2) }'; }
# the last shot's first row where the change puts it: far column 840-943 | 958-1061 | 1076-1179, thumb column
# 1204-1366 | 1381-1543 (the controls are on the shot at all: a closed curtain's desktop reads as anything)
rowseen() {
    set -- $(val ROW1)
    [ $# = 5 ] && near "$1" 840 943 && near "$2" 958 1061 && near "$3" 1076 1179 && near "$4" 1204 1366 && near "$5" 1381 1543
}
# ... and in its third place the keyboard tile (icon strokes, a two-glyph title: not torch or bypass, which this tap
# would switch on the real tablet)
row1ok() {
    rowseen && [ "$(val ICON)" -gt 60 ] && [ "$(val TITLE)" -gt 20 ] && [ "$(val TITLEW)" -ge 24 ] && [ "$(val TITLEW)" -le 40 ]
}
LIFT0=""
# the keyboard tile at full strength again (within 80 % of k0's lift: busy is half) / dimmed and still there (busy:
# a reading between kb-look's THR and 80 % of k0's); both on a shot of the controls: an unreadable shot or one
# without the controls is neither, so both checks fail on it
full() { rowseen && awk -v l="$(val KBLIFT)" -v l0="$LIFT0" 'BEGIN { exit !(l ~ /^[0-9.]+$/ && l0 > 0 && l >= 0.8 * l0) }'; }
dim() { rowseen && awk -v l="$(val KBLIFT)" -v l0="$LIFT0" 'BEGIN { exit !(l ~ /^[0-9.]+$/ && l0 > 0 && l > 6 && l < 0.8 * l0) }'; }

# ---------------- set up: the fakes first (fake-osk before any tap), the tray items in
mark setup
python3 "$FK" >> "$LOG" 2>&1 &
waitfor "FAKEOSK up as" 1 5 || { bad "setup: fake-osk.py not up: $(grep -F FAKEOSK "$LOG" | tail -n 1)"; return 0; }
python3 "$FS" >> "$LOG" 2>&1 &
cc show; sleep 1
waitfor "FAKESNI READY" 1 10 || say "setup: fake-sni.py not ready (the tray columns are not compared)"
cc hide; sleep 0.8

# ---------------- k0: the layout
mark k0
cc show; sleep 1.2
shown || bad "k0: the controls did not open (show)"
snap k0-controls
say "k0 first row: $(val ROW1); tray: $(val TRAY); keyboard lift $(val KBLIFT), icon $(val ICON) px, title $(val TITLE) px"
if ! row1ok; then
    bad "k0: the first row is not 840-943 958-1061 1076-1179 | 1204-1366 1381-1543 with the keyboard drawn: $(val ROW1), icon $(val ICON), title $(val TITLE) px / $(val TITLEW) wide; nothing tapped"
    cc hide; return 0
fi
LIFT0=$(val KBLIFT)
set -- $(val TRAY)
if [ "$1" = none ]; then
    say "k0: no tray tiles on the shot, their columns not compared"
elif ! { [ $# = 3 ] && near "$1" 840 943 && near "$2" 958 1061 && near "$3" 1076 1179; }; then
    bad "k0: the tray tiles' columns ($(val TRAY)) are not the first row's (840-943 958-1061 1076-1179)"
fi

# ---------------- k1: ok
mark k1
mode ok
tap $KB; sleep 1.2
if [ "$(cnt 'FAKEOSK ForceShow from')" != 1 ]; then
    # whatever was tapped, it was not the keyboard: no more taps (the next ones could switch the real torch or bypass)
    bad "k1: $(cnt 'FAKEOSK ForceShow from') ForceShow calls, want 1; nothing more tapped"
    cc hide; return 0
fi
shown && bad "k1: the curtain still open after the keyboard said yes"
[ "$(cnt 'toast:')" = 0 ] || bad "k1: a toast: $(grep -F 'toast:' "$LOG" | tail -n 1)"
shot k1-ok

# ---------------- k2: refused
mark k2
mode fail
cc show; sleep 1.2
snap k2-open
if row1ok; then
    tap $KB; sleep 1
    expect "FAKEOSK ForceShow from"
    expect "toast: 键盘失败"
    shown || bad "k2: the curtain closed on a refusal"
    sleep 0.4; snap k2-fail
    full || bad "k2: the tile not back to full strength after the refusal, or no controls on the shot (row $(val ROW1), lift $(val KBLIFT), k0 $LIFT0)"
else
    bad "k2: the first row not found on k2-open: $(val ROW1); nothing tapped"
fi

# ---------------- k3: no answer: busy, no second call, busctl's 3 s, the toast
mark k3
mode mute
cc hide; sleep 0.8; cc show; sleep 1.2
snap k3-open
if row1ok; then
    # the second tap right after the first, well inside busctl's 3 s (a tap lasts about 1.1 s with the holding
    # finger): a build whose busy tile still took taps would queue a second ForceShow behind the first (Backend::act
    # runs one command per name), sent once the first gives up, so the calls are counted after that
    tap $KB; sleep 0.3; tap $KB
    snap k3-busy
    dim || bad "k3: the tile not dimmed while the call is out (lift $(val KBLIFT), k0 $LIFT0)"
    waitfor "toast: 键盘失败" 1 5 || bad "k3: no toast within 5 s of a keyboard that does not answer"
    sleep 0.6
    [ "$(cnt 'FAKEOSK ForceShow from')" = 1 ] || bad "k3: $(cnt 'FAKEOSK ForceShow from') ForceShow calls for two taps on a busy tile, want 1"
    [ "$(cnt 'toast: 键盘失败')" = 1 ] || bad "k3: $(cnt 'toast: 键盘失败') failure toasts, want 1"
    shown || bad "k3: the curtain closed on no answer"
    sleep 0.4; snap k3-after
    full || bad "k3: the tile not back to full strength after the timeout, or no controls on the shot (row $(val ROW1), lift $(val KBLIFT), k0 $LIFT0)"
else
    bad "k3: the first row not found on k3-open: $(val ROW1); nothing tapped"
fi

# ---------------- k4: a late yes after the curtain was closed and opened again
mark k4
mode late
cc hide; sleep 0.8; cc show; sleep 1.2
snap k4-open
if row1ok; then
    tap $KB; sleep 0.3
    cc hide; sleep 0.6; cc show
    waitfor "FAKEOSK late answered" 1 4 || bad "k4: the late answer never came"
    sleep 1
    shown || bad "k4: a late yes closed the curtain opened after it"
    snap k4-late
    full || bad "k4: the tile dimmed in the new opening, or no controls on the shot (row $(val ROW1), lift $(val KBLIFT), k0 $LIFT0)"
else
    bad "k4: the first row not found on k4-open: $(val ROW1); nothing tapped"
fi

mode ok
cc hide
n=$(grep -cF 'FAKEOSK ForceShow from' "$LOG")
[ "$n" = 4 ] || bad "$n ForceShow calls in all, want 4 (one each in k1-k4)"
say "done (FAIL=$FAIL), ForceShow calls in all: $n"
