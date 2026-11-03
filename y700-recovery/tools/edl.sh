#!/bin/bash
# bkerler edl with the TB323FU loader, UFS, 4096-byte sectors; logs to notes/edl-log.txt.
# Not for the `reset` subcommand (it rejects --memory/--sectorsize): run edl.py --loader=... reset directly.
R=$(cd "$(dirname "$0")/.." && pwd)
cd "$R/edl" || exit 1
echo "== $(date -Is) edl $*" >> "$R/notes/edl-log.txt"
"$R/edlvenv/bin/python" edl.py --loader="$R/loader/qsahara_device_programmer.xml" --memory=ufs --sectorsize=4096 "$@" 2>&1 | tee -a "$R/notes/edl-log.txt"
rc=${PIPESTATUS[0]}   # edl's, not tee's: README's `edl.sh r ... && sha256sum ...` relies on it
echo "== exit $rc" | tee -a "$R/notes/edl-log.txt"
exit "$rc"
