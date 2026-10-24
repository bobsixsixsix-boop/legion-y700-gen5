#!/bin/sh
# pill-drag-run.sh [OUT]: the pill-drag scenario (pill-drag.sh: the control centre's brightness / volume pills
# under a finger, relative drag) in the headless bed (sb-bed.sh) against the INSTALLED control centre, or
# SB_CC=BIN for another build (one installed under its own prefix, say
#   cmake -S SRC -B B -DCMAKE_INSTALL_PREFIX=/opt/y700-pill && cmake --build B -j8 && cmake --install B
# then SB_CC=/opt/y700-pill/bin/y700-control-center: the binary reads the QML under its own prefix, so a newer
# Pill.qml can also just be copied there).
# Writes the verdict for y700-checklist to /var/lib/y700/pill-drag-last.txt, stamped with the sha256 (12) of the
# Pill.qml it tested (a verdict for another Pill.qml than the installed one = rerun). The hash is taken before the
# run; a Pill.qml swapped while the bed runs (a deploy overlapping the periodic run) makes the verdict a FAIL that
# asks for a rerun rather than certifying a file that was never exercised.
# Root; nothing touches the screen, so it can run while the tablet is in use. About two minutes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); U=user; OUT=${1:-/home/$U/pill-drag}
CC=${SB_CC:-/usr/local/bin/y700-control-center}
QML=$(dirname "$(dirname "$(readlink -f "$CC")")")/share/y700-control-center/qml/Pill.qml
h=$(sha256sum "$QML" 2>/dev/null | cut -c1-12)
rm -f "$OUT/pill-drag.txt" "$OUT/verdict.err"
SB_CC="$CC" sh "$HERE/sb-bed.sh" "$HERE/pill-drag.sh" "$OUT"; rc=$?
v=$(cat "$OUT/pill-drag.txt" 2>/dev/null || echo "FAIL no verdict (the bed did not reach the analysis: $OUT/log)")
[ -n "$v" ] || v="FAIL an empty verdict (the analysis died: $OUT/verdict.err)"
[ $rc = 0 ] || case "$v" in FAIL*) ;; *) v="FAIL the bed failed (rc $rc, $OUT/log) although the gestures passed: $v" ;; esac
h2=$(sha256sum "$QML" 2>/dev/null | cut -c1-12)
[ "$h" = "$h2" ] || v="FAIL Pill.qml changed during the run (${h:-unknown} -> ${h2:-unknown}): rerun | $v"
case "$v" in FAIL*) [ $rc = 0 ] && rc=1 ;; esac
mkdir -p /var/lib/y700
echo "$(date '+%F %T') $v pill ${h:-unknown}" > /var/lib/y700/pill-drag-last.txt
cat /var/lib/y700/pill-drag-last.txt
exit $rc
