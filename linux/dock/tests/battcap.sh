# sb-bed scenario (10-30): the control centre's battery pill (Main.qml header, batPill) against canned battery readings
# (battcap-bin/tb323fu-ctl lays $XDG_RUNTIME_DIR/sb-battery.json over the real status). Run it through battcap-run.sh:
#   sh ./battcap-run.sh /root/sb-battcap          (root; about a minute; SB_CC=BIN for a candidate build)
# The pill is found on each shot (bc-look.py, written below into the bed: the bright pixels at the header's right end:
# the battery outline, ⚡, the digits, the chevron) and tapped only where it was found; a tap anywhere else in the
# header only closes the curtain. The holding finger is long-pressed on the curtain's empty left half (300, 700), as
# kbtile.sh. Steps and shots (OUT/*.png):
#   c0-discharging  Discharging 57 %, no USB input current: no ⚡ (the pill content's width W0)
#   c1-pump         Charging 57 %, USB input current 0 (PPS charge-pump fast charging, the 10-30 bug): ⚡, W1 - W0 =
#                   the ⚡'s width (6-30 px); the right end stays put (the pill hangs off the header's right edge)
#   c2-held         Not charging 57 %, USB input current 0 (held at the limit): ⚡ (W1 within 2 px)
#   c3-fallback     Discharging 57 % with 900 mA USB input current (the old reading, kept as a fallback): ⚡
#   c4-page         tap the pill's middle: the curtain closes and y700-battery opens the battery page, full width. Which
#                   page is the launcher's choice (linux/power/battery/y700-battery), and c4-c6 wait for that one's
#                   window class (said at the start): ours (y700-battery, linux/power/battery/page, maximized by
#                   itself) when /usr/local/libexec/y700-battery-page is installed and the installed launcher runs it;
#                   else KDE's power page (kcmshell6, class kcm_mobile_power, caption 电量), maximized by the KWin rule
#                   y700-battery-max (the real ~/.config/kwinrulesrc is copied into the bed at the start: what
#                   install-entry.sh wrote; without the rule its width is not checked). Ours runs its real report
#                   here (battcap-run.sh sets no Y700_BATTERY_REPORT) against the bed's own XDG_STATE_HOME and
#                   XDG_CACHE_HOME (sb-bed.sh): an empty ledger, nothing of the owner's read or written. Its look is
#                   batpage.sh's business, not this scenario's
#   c5-edge         that page closed; tap 8 px above the pill (inside the handler's 12 px margin): the page again
#   c6-again        tap the pill with the page still open: still one page (y700-battery closes the open one first;
#                   kcmshell6 alone stacked a second window, 10-30)
#   c7-push         the pages closed; a fast push up that starts and ends inside the handler's reach (pill middle
#                   +24 .. -24): the curtain closes (a push past 40 px) and no page opens (the header's DragHandler
#                   took the point over from the pill's TapHandler)
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "battcap.sh: ..." lines are notes.
LOOK=$T/run/bc-look.py
cat > "$LOOK" <<'PY'
# bc-look.py PNG (battcap.sh writes it into the bed): the battery pill's content on a bed screenshot (1600x1002, the
# controls open): the bounding box of the bright pixels (luma > 170: the white digits and chevron, the battery
# outline, ⚡ drawn as text or as an emoji) in the header's right end, x 1200-1599, y 20-119 (the clock and the date
# are at the left, the controls start at y 162)
import sys
import numpy as np
from PIL import Image

img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(np.float32)
X0, Y0 = 1200, 20
luma = img[Y0:120, X0:1600] @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
ys, xs = np.nonzero(luma > 170)
if len(xs) < 20:
    print("PILL none %d" % len(xs))
else:
    print("PILL %d %d %d %d %d" % (X0 + xs.min(), X0 + xs.max(), Y0 + ys.min(), Y0 + ys.max(), len(xs)))
PY
HOLD_AT="300 700"; HOLD_MS=1000
say() { echo "battcap.sh: $*"; echo "battcap.sh: $*" >> "$LOG"; }
# the page the pill opens, as the launcher decides it (y700-battery: KDE's when ours is not installed): ours names the
# page; the old launcher (before 10-30) opened KDE's only and never names it
if [ -x /usr/local/libexec/y700-battery-page ] && grep -q 'y700-battery-page' /usr/local/bin/y700-battery 2>/dev/null; then
    PCLS=y700-battery
else
    PCLS=kcm_mobile_power
fi
say "c4-c6 wait for window class $PCLS"
# the real window rules (y700-battery-max among them) into the bed's KWin
RULES=0
if grep -q '^wmclass=kcm_mobile_power$' /home/user/.config/kwinrulesrc 2>/dev/null; then
    cp /home/user/.config/kwinrulesrc "$XDG_CONFIG_HOME/kwinrulesrc" && qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 && RULES=1
fi
# the width is checked for our page always (it maximizes itself), for KDE's only under the rule that maximizes it
SIZED=1
if [ $PCLS = kcm_mobile_power ] && [ $RULES = 0 ]; then
    SIZED=0
    echo "battcap.sh: no y700-battery-max rule in ~/.config/kwinrulesrc (install-entry.sh): the page's size is not checked" | tee -a "$LOG"
fi

bad() { echo "SBBED_EXPECT_FAIL: battcap.sh: $*"; echo "battcap.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
bat() { printf '%s\n' "$1" > "$XDG_RUNTIME_DIR/sb-battery.json"; }
reopen() { cc hide; sleep 0.8; cc show; sleep 1.6; }
# the curtain open? (KWin lists the control centre's window only while it is mapped; kbtile.sh's shown)
shown() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -qF "y700-control-center/"; }
# battery pages of class $PCLS on the bed's window list (ours: the page's desktop file name, y700-battery; KDE's:
# kcmshell6 names the window after the module, kcm_mobile_power), each entry of a wins line starts after ": " or
# "| "; pagew: the width of the last one listed (0 none), the last +WxH of its entry (the caption comes before it)
pages() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -oE "(: |\| )$PCLS/" | wc -l; }
pagew() {
    n0=$(wc -l < "$LOG"); wins
    g=$(tail -n +$((n0 + 1)) "$LOG" | grep -oE "(: |\| )$PCLS/[^|]*" | tail -n 1 | grep -oE '\+[0-9]+x[0-9]+' | tail -n 1)
    g=${g#+}; echo "${g%%x*}" | grep . || echo 0
}
waitpage() { tw=0; while [ "$(pages)" -lt 1 ]; do tw=$((tw + 1)); [ $tw -gt 10 ] && return 1; sleep 1; done; }
# close the pages this bed opened, either kind (only those: the owner's own are on wayland-0). Ours by its path,
# anchored: pgrep -x cannot match it (the kernel keeps 15 characters of a command name, y700-battery-pa)
closepages() {
    for p in $(pgrep -x kcmshell6) $(pgrep -u "$(id -u)" -f '^/usr/local/libexec/y700-battery-page( |$)'); do
        tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -qx "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" && kill "$p"
    done
    sleep 1
}
# measure NAME: a shot and the pill on it -> PX0 PX1 PY0 PY1, W (content width), CX CY (its middle); pillok: a pill
# where the change puts it (content 30-160 wide and at most 30 high, its right end at x 1500-1545)
measure() {
    shot "$1"; LK=$(python3 "$LOOK" "$OUT/$1.png" 2>&1); echo "bc-look $1: $LK" >> "$LOG"
    set -- $LK
    if [ "${1:-}" = PILL ] && [ "${2:-}" != none ] && [ $# = 6 ]; then
        PX0=$2; PX1=$3; PY0=$4; PY1=$5; W=$((PX1 - PX0 + 1)); CX=$(((PX0 + PX1) / 2)); CY=$(((PY0 + PY1) / 2))
    else
        PX0=0; PX1=0; PY0=0; PY1=0; W=0; CX=0; CY=0
    fi
}
pillok() { [ $W -ge 30 ] && [ $W -le 160 ] && [ $((PY1 - PY0)) -le 30 ] && [ $PX1 -ge 1500 ] && [ $PX1 -le 1545 ]; }
within() { d=$(($1 - $2)); [ $d -lt 0 ] && d=$((-d)); [ $d -le "$3" ]; }

DIS='{"Status": "Discharging", "State": "discharging", "Capacity": 57, "CurrentMa": -420, "ChargerType": "none", "ChargerAdapter": "", "InputCurrentMa": 0, "InputVoltageMv": 0}'
PUMP='{"Status": "Charging", "State": "charging", "Capacity": 57, "CurrentMa": 4200, "ChargerType": "USB", "ChargerAdapter": "PD_PPS", "InputCurrentMa": 0, "InputVoltageMv": 9000}'
HELD='{"Status": "Not charging", "State": "bypass", "Capacity": 57, "CurrentMa": 0, "ChargerType": "USB", "ChargerAdapter": "PD", "InputCurrentMa": 0, "InputVoltageMv": 9000}'
OLD='{"Status": "Discharging", "State": "discharging", "Capacity": 57, "CurrentMa": -150, "ChargerType": "USB", "ChargerAdapter": "DCP", "InputCurrentMa": 900, "InputVoltageMv": 5000}'

# ---------------- c0-c3: ⚡ by charger state
mark c0
bat "$DIS"; reopen
shown || bad "c0: the controls did not open (show)"
measure c0-discharging; W0=$W; R0=$PX1
say "c0 discharging: pill content $PX0-$PX1 x $PY0-$PY1, $W wide"
if ! pillok; then
    bad "c0: no pill where it belongs ($LK); nothing tapped"
    cc hide; return 0
fi
for s in "c1-pump:$PUMP" "c2-held:$HELD" "c3-fallback:$OLD"; do
    n=${s%%:*}; mark "$n"
    bat "${s#*:}"; reopen
    measure "$n"
    say "$n: pill content $PX0-$PX1 x $PY0-$PY1, $W wide ($((W - W0)) more than discharging)"
    if ! pillok; then bad "$n: no pill where it belongs ($LK)"; continue; fi
    within "$PX1" "$R0" 2 || bad "$n: the pill's right end moved ($R0 -> $PX1)"
    if [ "$n" = c1-pump ]; then
        W1=$W
        [ $((W - W0)) -ge 6 ] && [ $((W - W0)) -le 30 ] || bad "c1: no ⚡ while the charge pumps charge (content $W0 -> $W wide, want 6-30 more)"
    else
        within "$W" "${W1:-0}" 2 || bad "$n: ⚡ not as in c1 (content $W wide, c1 ${W1:-?})"
    fi
done

# ---------------- c4: a tap on the pill opens the battery page, the curtain closes
mark c4
bat "$PUMP"; reopen
measure c4-open
if pillok; then
    tap $CX $CY; sleep 1
    shown && bad "c4: the curtain still open after a tap on the pill"
    if waitpage; then
        sleep 1; pw=$(pagew); shot c4-page; say "c4: the battery page ($PCLS) is up, $pw wide"
        if [ $PCLS = y700-battery ]; then
            [ "$pw" -ge 1500 ] || bad "c4: the battery page is $pw wide, not maximized (its showMaximized)"
        else
            [ $SIZED = 0 ] || [ "$pw" -ge 1500 ] || bad "c4: KDE's power page is $pw wide, not maximized (rule y700-battery-max)"
        fi
    else
        bad "c4: no battery page ($PCLS) within 10 s of the tap"
    fi
else
    bad "c4: no pill on c4-open ($LK); nothing tapped"
fi

# ---------------- c5: the handler's margin: 8 px above the pill still opens it
mark c5
closepages
[ "$(pages)" = 0 ] || say "c5: a page still listed after closing them"
reopen
measure c5-open
if pillok; then
    tap $CX $((CY - 24)); sleep 1
    shown && bad "c5: the curtain still open after a tap 8 px above the pill"
    waitpage || bad "c5: no battery page ($PCLS) within 10 s of a tap 8 px above the pill (the 12 px margin)"
else
    bad "c5: no pill on c5-open ($LK); nothing tapped"
fi

# ---------------- c6: again with the page open: still one page
mark c6
PCX=$CX; PCY=$CY; ok6=0; pillok && ok6=1
reopen
measure c6-open
# KDE's maximized page is white under the curtain (ours is #121212, the pill stands out on it): if the pill is not
# found over the page, c5's place (the same pill: the readings did not change), on a shot that has the controls
if pillok; then
    ok6=1
elif [ $ok6 = 1 ] && shown; then
    say "c6: the pill not found over the open page ($LK), tapped at c5's place $PCX $PCY"; CX=$PCX; CY=$PCY
else
    ok6=0
fi
if [ $ok6 = 1 ]; then
    tap $CX $CY; sleep 5
    n=$(pages); say "c6: $n battery page window(s) ($PCLS) after a second tap with one open"
    [ "$n" = 1 ] || bad "c6: $n battery page windows ($PCLS) after a second tap, want 1 (y700-battery closes the open one first)"
    shot c6-again
else
    bad "c6: no pill on c6-open ($LK); nothing tapped"
fi

# ---------------- c7: a push that starts on the pill closes the curtain and opens nothing
mark c7
closepages
reopen
measure c7-open
if pillok; then
    swipe $CX $((CY + 24)) $CX $((CY - 24)) 100; sleep 1.5
    shown && bad "c7: the curtain still open after a 48 px push up from the pill"
    sleep 3
    [ "$(pages)" = 0 ] || bad "c7: a push from the pill opened the battery page (the tap was not taken over)"
    shot c7-push
else
    bad "c7: no pill on c7-open ($LK); nothing pushed"
fi
closepages
cc hide
say "done (FAIL=$FAIL)"
