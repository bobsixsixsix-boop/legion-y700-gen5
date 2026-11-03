#!/bin/sh
# battcap-run.sh [OUT]: the battcap scenario (battcap.sh: the control centre's battery pill, its ⚡ and its tap) in the
# headless bed (sb-bed.sh) against the INSTALLED control centre, or SB_CC=BIN for another build (installed under its
# own prefix, as vol-open-run.sh says). The control centre runs through a wrapper that puts battcap-bin/ (a
# tb323fu-ctl stand-in that lays canned battery readings over the real status, see it) first on its PATH; its children
# inherit it. Nothing else in the bed sees it. Needs /usr/local/bin/y700-battery (linux/power/battery/install-entry.sh):
# the pill starts it and the scenario looks for the window it opens.
# Root; nothing touches the screen, but each of the bed's three taps on the pill is one real haptic tick (the bed's
# control centre opens the motors): run it with the screen off. About a minute.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); U=user; OUT=${1:-/home/$U/battcap}
CC=$(readlink -f "${SB_CC:-/usr/local/bin/y700-control-center}")
[ -x /usr/local/bin/y700-battery ] || { echo "SBBED_FAIL: no /usr/local/bin/y700-battery (linux/power/battery/install-entry.sh)"; exit 1; }
D=$(mktemp -d /tmp/y700-battcap-XXXXXX)
# without the stand-in the control centre reads the real battery and c1-c3 fail on whatever it says (10-30: a copy of
# the tests without battcap-bin/ ran on and reported "no ⚡")
install -m 755 "$HERE/battcap-bin/tb323fu-ctl" "$D/tb323fu-ctl" \
    || { echo "SBBED_FAIL: no $HERE/battcap-bin/tb323fu-ctl (copy battcap-bin/ along with the tests)"; rm -rf "$D"; exit 1; }
printf '#!/bin/sh\n# battcap-run.sh: the control centre with the stand-in first on its PATH\nPATH=%s:$PATH exec %s "$@"\n' "$D" "$CC" > "$D/y700-control-center"
chmod 755 "$D" "$D/y700-control-center"
SB_CC="$D/y700-control-center" sh "$HERE/sb-bed.sh" "$HERE/battcap.sh" "$OUT"; rc=$?
rm -rf "$D"
# a page the bed's control centre opened outlives the bed only if its compositor connection did: none expected
for p in $(pgrep -x kcmshell6); do
    tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -q '^WAYLAND_DISPLAY=y700-sbbed' && { echo "battcap-run.sh: bed kcmshell6 $p left over, killed"; kill "$p"; }
done
exit $rc
