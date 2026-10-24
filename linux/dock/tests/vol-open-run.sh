#!/bin/sh
# vol-open-run.sh [OUT]: the vol-open scenario (vol-open.sh: the control centre's volume pill when the curtain opens
# and while it is up) in the headless bed (sb-bed.sh) against the INSTALLED control centre, or SB_CC=BIN for another
# build (one installed under its own prefix: cmake -S SRC -B B -DCMAKE_INSTALL_PREFIX=/opt/y700-next && cmake --build
# B -j8 && cmake --install B, then SB_CC=/opt/y700-next/bin/y700-control-center).
# The bed has no sound server, so the control centre runs through a wrapper that puts vol-open-bin/ (wpctl, pactl and
# tb323fu-ctl stand-ins, see each) first on its PATH; its children inherit it. Nothing else in the bed sees them.
# Writes the verdict for y700-checklist to /var/lib/y700/vol-open-last.txt, stamped with the sha256 (12) of the
# binary it tested (the volume reading is compiled in: a verdict for another binary than /usr/local/bin's = rerun).
# A binary swapped while the bed runs makes the verdict a FAIL that asks for a rerun.
# Root; nothing touches the screen, so it can run while the tablet is in use. About a minute.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); U=user; OUT=${1:-/home/$U/vol-open}
CC=$(readlink -f "${SB_CC:-/usr/local/bin/y700-control-center}")
h=$(sha256sum "$CC" 2>/dev/null | cut -c1-12)
D=$(mktemp -d /tmp/y700-volopen-XXXXXX)
for f in wpctl pactl tb323fu-ctl; do install -m 755 "$HERE/vol-open-bin/$f" "$D/$f"; done
printf '#!/bin/sh\n# vol-open-run.sh: the control centre with the stand-ins first on its PATH\nPATH=%s:$PATH exec %s "$@"\n' "$D" "$CC" > "$D/y700-control-center"
chmod 755 "$D" "$D/y700-control-center"
rm -f "$OUT/vol-open.txt" "$OUT/verdict.err"
SB_CC="$D/y700-control-center" sh "$HERE/sb-bed.sh" "$HERE/vol-open.sh" "$OUT"; rc=$?
rm -rf "$D"
v=$(cat "$OUT/vol-open.txt" 2>/dev/null || echo "FAIL no verdict (the bed did not reach the analysis: $OUT/log)")
[ -n "$v" ] || v="FAIL an empty verdict (the analysis died: $OUT/verdict.err)"
[ $rc = 0 ] || case "$v" in FAIL*) ;; *) v="FAIL the bed failed (rc $rc, $OUT/log) although the steps passed: $v" ;; esac
h2=$(sha256sum "$CC" 2>/dev/null | cut -c1-12)
[ "$h" = "$h2" ] || v="FAIL the control centre changed during the run (${h:-unknown} -> ${h2:-unknown}): rerun | $v"
case "$v" in FAIL*) [ $rc = 0 ] && rc=1 ;; esac
mkdir -p /var/lib/y700
echo "$(date '+%F %T') $v cc ${h:-unknown}" > /var/lib/y700/vol-open-last.txt
cat /var/lib/y700/vol-open-last.txt
exit $rc
