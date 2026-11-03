#!/bin/bash
# Offline test of tools/edl.sh's exit code (10-31 audit A8). Runs anywhere bash runs (Git Bash on the PC, Linux): a
# copy of edl.sh goes into a fake y700-recovery tree in a temp dir whose edlvenv/bin/python is a stub that exits
# with $FAKE_RC (no edl, no device, the real notes/ is not touched).
#   fail  edl exits 3 -> edl.sh exits 3, so README's `tools/edl.sh r ... && sha256sum ...` stops (it exited 0)
#   ok    edl exits 0 -> edl.sh exits 0; both runs are logged with their "== exit N" line
# Prints ALL PASS.
cd "$(dirname "$0")" || exit 1
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tools" "$T/edl" "$T/notes" "$T/edlvenv/bin"
cp edl.sh "$T/tools/"
printf '#!/bin/sh\necho "fake edl $*"\nexit ${FAKE_RC:-0}\n' > "$T/edlvenv/bin/python"
chmod +x "$T/tools/edl.sh" "$T/edlvenv/bin/python"
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

FAKE_RC=3 bash "$T/tools/edl.sh" r boot_b /dev/null --lun=4 >/dev/null; rc=$?
[ "$rc" = 3 ]; check "fail: edl exits 3 -> edl.sh exits 3 (got $rc)" $?
FAKE_RC=0 bash "$T/tools/edl.sh" r boot_b /dev/null --lun=4 >/dev/null; rc=$?
[ "$rc" = 0 ]; check "ok: edl exits 0 -> edl.sh exits 0 (got $rc)" $?
grep -q "^== exit 3$" "$T/notes/edl-log.txt" && grep -q "^== exit 0$" "$T/notes/edl-log.txt"
check "ok: both exit codes are in notes/edl-log.txt" $?

[ "$fails" = 0 ] && echo "ALL PASS" || echo "$fails FAILED"
[ "$fails" = 0 ]
