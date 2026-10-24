#!/bin/sh
# blur-flicker.sh [OUT]: pull the curtain down on the LIVE session with a fake finger and keep every frame KWin
# renders meanwhile (capseq.py); fail if any frame under the curtain is tinted but sharp, i.e. painted without its
# blur (the flicker of 10-22, see README「下拉模糊闪烁」). Run as root. Takes the screen for about 4 s: do not run it
# while the owner is using the tablet. Turns the screen on if it is off and turns it off again after.
# Needs the test tools install.sh puts in place: /usr/local/bin/y700-capseq (+ its desktop file, the ScreenShot2
# grant) and /usr/local/bin/y700-ftouch (+ the fake_input grant). Prints BLUR_OK / BLUR_FAIL / BLUR_INCONCLUSIVE
# (exit 0 / 1 / 2) and writes the one-line result to /var/lib/y700/cc-blur-last.txt (y700-checklist reads it).
# OUT (default /home/user/cc-blur) gets the frames, frames.txt and the contact sheet sheet.png.
set -u
U=user
OUT=${1:-/home/$U/cc-blur}
TESTS=$(cd "$(dirname "$0")" && pwd)
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 HOME=/home/$U"
LAST=/var/lib/y700/cc-blur-last.txt
N=100          # frames (about 2.5 s at the rate KWin serves ScreenShot2; 640 MB in memory)
fail() { echo "BLUR_FAIL: $*"; mkdir -p /var/lib/y700; echo "$(date '+%F %T') FAIL $*" > $LAST; exit 1; }
for f in /usr/local/bin/y700-capseq /usr/local/bin/y700-ftouch "$TESTS/capseq.py"; do
    [ -e "$f" ] || fail "$f missing (sh install.sh)"
done
grep -q ScreenShot2 /usr/local/share/applications/y700-capseq.desktop 2>/dev/null || fail "y700-capseq.desktop has no ScreenShot2 grant"
$RUN busctl --user status fyi.y700.ControlCenter >/dev/null 2>&1 || fail "fyi.y700.ControlCenter is not on the bus (control centre not running)"
mkdir -p "$OUT"; rm -f "$OUT"/f*.png "$OUT"/frames.txt "$OUT"/sheet.png; chown -R $U:$U "$OUT"

# the screen: KWin paints nothing while DPMS is off, the frames would all be black
dpms_was=on
if $RUN kscreen-doctor --dpms show 2>/dev/null | grep -q 'off$'; then
    dpms_was=off; $RUN kscreen-doctor --dpms on >/dev/null 2>&1; sleep 2.5
fi
$RUN busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1
# something with detail under the curtain (detail.py: a fullscreen window of 2 px noise), the wallpaper has little
$RUN python3 "$TESTS/detail.py" > "$OUT/detail.log" 2>&1 &
det=$!
sleep 1.5

$RUN /usr/local/bin/y700-capseq "$TESTS/capseq.py" "$OUT" $N > "$OUT/capseq.log" 2>&1 &
cap=$!
sleep 0.3
# one finger from the top edge's right half, 700 ms down to y 520, held 900 ms, up: the curtain follows, then opens
printf 'swipe 1200 2 1200 520 700 900\n' | $RUN /usr/local/bin/y700-ftouch
wait $cap
$RUN busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1
kill $det 2>/dev/null; pkill -u $U -f "$TESTS/detail.py" 2>/dev/null
[ $dpms_was = off ] && { sleep 0.6; $RUN kscreen-doctor --dpms off >/dev/null 2>&1; }
chown -R $U:$U "$OUT"

[ -s "$OUT/frames.txt" ] || fail "no frames.txt: $(tail -3 "$OUT/capseq.log" | tr '\n' ' ')"
# the verdict (columns: i t_ms wdebug_ms mean sharp tint_rows sharp_t ratio; '# first: mean M0 sharp S0')
res=$(awk '
    /^# first:/ { m0 = $4; s0 = $6; next }
    /^#/ { next }
    NF >= 8 { if ($6 >= 24) { tinted++; if ($8 > 0.22) { bad++; badlist = badlist " " $1 "(" $8 ")" } } }
    END {
        if (m0 < 40 || s0 < 200) print "INCONCLUSIVE first frame too dark or too flat (mean " m0 ", sharp " s0 "): put something with detail on screen"
        else if (tinted < 10) print "INCONCLUSIVE the curtain did not come down (" tinted + 0 " frames under it; the pull strip, fake_input?)"
        else if (bad > 0) print "FAIL " bad " of " tinted " frames under the curtain are tinted but sharp:" badlist
        else print "OK " tinted " frames under the curtain, all blurred (first frame mean " m0 " sharp " s0 ")"
    }' "$OUT/frames.txt")
mkdir -p /var/lib/y700
echo "$(date '+%F %T') $res" > $LAST
case "$res" in
    OK*) echo "BLUR_OK: ${res#OK } ($OUT/sheet.png)"; exit 0 ;;
    FAIL*) echo "BLUR_FAIL: ${res#FAIL } ($OUT/sheet.png)"; exit 1 ;;
    *) echo "BLUR_INCONCLUSIVE: ${res#INCONCLUSIVE } ($OUT/sheet.png)"; exit 2 ;;
esac
