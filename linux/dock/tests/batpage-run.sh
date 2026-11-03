#!/bin/sh
# batpage-run.sh [--force] [OUT]: the battery page's bed test (batpage.sh, DESIGN.md §8 in linux/power/battery) at both
# of the tablet's sizes, 1600x1002 and 1002x1600 (sb-bed.sh SB_SIZE), on the canned reports (batpage/*.json, §6b).
# Shots and logs go to OUT/1600x1002 and OUT/1002x1600 (default /home/user/batpage).
#   PAGE_BIN=BIN      the page to test, default the installed /usr/local/libexec/y700-battery-page (say a build that is
#                     not installed yet: page/build/y700-battery-page; its QML is compiled in, the one file is all of it)
#   BP_LAUNCHER=FILE  the launcher p8's pill runs, default the installed /usr/local/bin/y700-battery (say the repo's
#                     linux/power/battery/y700-battery before install-entry.sh put it in place)
# What the bed needs is staged in one directory user can read (/tmp/y700-batpage-*): a copy of the page, the
# canned reports and bp-look.py. Y700_BATTERY_REPORT points at its ok.json; the bed passes that to the scenario (which
# finds the rest next to it) and to the control centre, so the page the pill opens reads it too.
# p8 runs the launcher at its fixed path (the control centre's launch("/usr/local/bin/y700-battery")). When PAGE_BIN or
# BP_LAUNCHER is not the installed one, a copy of the launcher whose page path names the staged page is bind-mounted
# over /usr/local/bin/y700-battery in a private mount namespace (unshare -m) that only the bed runs in: nothing outside
# it sees the copy, and it is gone with the bed. That needs the launcher to name /usr/local/libexec/y700-battery-page
# literally (DESIGN.md §7: the new launcher execs it); one that does not (the old KDE-only launcher) is noted, and p8
# then fails on the KDE page it opens.
# Root. Refuses while the screen is on (--force runs anyway): each size taps the pill twice, two real haptic ticks
# (the bed's control centre opens the motors); the bed itself touches nothing of the real session. About 3 minutes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); U=user
FORCE=0; [ "${1:-}" = --force ] && { FORCE=1; shift; }
OUT=$(readlink -m "${1:-/home/$U/batpage}")
INST=/usr/local/libexec/y700-battery-page; ENTRY=/usr/local/bin/y700-battery
PAGE_BIN=$(readlink -f "${PAGE_BIN:-$INST}"); BP_LAUNCHER=$(readlink -f "${BP_LAUNCHER:-$ENTRY}")
[ "$(id -u)" = 0 ] || { echo "batpage-run.sh: run it as root (sb-bed.sh switches to $U)"; exit 1; }
if [ $FORCE = 0 ] && ! grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then
    echo "batpage-run.sh: the screen is on (each size taps the pill twice: real haptic ticks). Turn it off first, or --force"
    exit 3
fi
[ -x "$PAGE_BIN" ] || { echo "batpage-run.sh: no page at $PAGE_BIN (build linux/power/battery/page, or PAGE_BIN=)"; exit 1; }
[ -f "$BP_LAUNCHER" ] || { echo "batpage-run.sh: no launcher at $BP_LAUNCHER (BP_LAUNCHER=)"; exit 1; }
# a bind mount needs something to mount over: the entry install-entry.sh puts in place
[ -e "$ENTRY" ] || { echo "batpage-run.sh: no $ENTRY for p8's pill to run (linux/power/battery/install-entry.sh)"; exit 1; }
for f in ok just_full empty partial all_charger degraded; do
    [ -f "$HERE/batpage/$f.json" ] || { echo "batpage-run.sh: no canned report $HERE/batpage/$f.json"; exit 1; }
done

D=$(mktemp -d /tmp/y700-batpage-XXXXXX)
trap 'rm -rf "$D"' EXIT
trap 'exit 130' INT TERM
chmod 755 "$D"
install -m 644 "$HERE"/batpage/*.json "$HERE/bp-look.py" "$D/"
install -m 755 "$PAGE_BIN" "$D/y700-battery-page"
PSHA=$(sha256sum "$D/y700-battery-page" | cut -c1-12)

BIND=
SWAP=0; [ "$PAGE_BIN" = "$(readlink -f "$INST")" ] || SWAP=1
if [ $SWAP = 1 ] || [ "$BP_LAUNCHER" != "$(readlink -f "$ENTRY")" ]; then
    BIND=$D/y700-battery
    # the page path swapped for the staged copy wherever the launcher names it (its "is the page there" test, the
    # closing of open pages and the exec alike); python3, not sed (the tablet's sed rule)
    python3 -I - "$BP_LAUNCHER" "$BIND" "$INST" "$D/y700-battery-page" $SWAP <<'PY' || { echo "batpage-run.sh: could not stage the launcher"; exit 1; }
import sys
src, dst, inst, staged, swap = sys.argv[1:]
text = open(src, encoding="utf-8").read()
if swap == "1":
    n = text.count(inst)
    if n == 0:
        print("batpage-run.sh: note: %s never names %s: p8's pill gets whatever page it finds, not PAGE_BIN" % (src, inst))
    text = text.replace(inst, staged)
with open(dst, "w", encoding="utf-8", newline="\n") as f:
    f.write(text)
PY
    chmod 755 "$BIND"
fi
grep -q 'y700-battery-page' "$BP_LAUNCHER" || echo "batpage-run.sh: note: $BP_LAUNCHER never names y700-battery-page (the old KDE-only launcher?): p8 will fail on KDE's power page"

mkdir -p "$OUT"; chown $U:$U "$OUT"
rcs=; bad=0
for size in 1600x1002 1002x1600; do
    echo "batpage-run.sh: $size"
    if [ -n "$BIND" ]; then
        Y700_BATTERY_REPORT="$D/ok.json" SB_SIZE=$size unshare -m --propagation private \
            sh -c 'mount --bind "$0" "$1" && shift && exec "$@"' "$BIND" "$ENTRY" \
            sh "$HERE/sb-bed.sh" "$HERE/batpage.sh" "$OUT/$size"
    else
        Y700_BATTERY_REPORT="$D/ok.json" SB_SIZE=$size sh "$HERE/sb-bed.sh" "$HERE/batpage.sh" "$OUT/$size"
    fi
    rc=$?
    rcs="$rcs $size=$rc"; [ $rc = 0 ] || bad=1
done

# a page the beds opened outlives its bed only if its compositor connection did: none expected
for p in $(pgrep -f "^($D|/usr/local/libexec)/y700-battery-page( |\$)") $(pgrep -f '^(/usr/bin/)?kcmshell6 kcm_mobile_power$'); do
    tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -q '^WAYLAND_DISPLAY=y700-sbbed' && { echo "batpage-run.sh: bed page $p left over, killed"; kill "$p"; }
done
echo "batpage-run.sh: page $PAGE_BIN (sha256 $PSHA), launcher $BP_LAUNCHER${BIND:+ (staged over $ENTRY)}; rc$rcs; shots in $OUT"
exit $bad
