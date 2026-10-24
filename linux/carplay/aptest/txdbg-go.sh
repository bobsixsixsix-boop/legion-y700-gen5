#!/bin/bash
# Arm the restore guard, then run txdbg-run.sh K HOLD GAP [extra...] from a transient unit 3 s from now.
# SEC / SETUP / SETTLE pass through to apjoin.sh.
K=${1:-6}; HOLD=${2:-70}; GAP=${3:-20}
G=$(( K * (HOLD + GAP + 40) + 240 ))
systemctl reset-failed y700-apjoin.service y700-aptest2-guard.service 2>/dev/null
systemd-run -q --unit y700-aptest2-guard --on-active=$G /bin/bash /root/txdbg-restore.sh
systemd-run -q --unit y700-apjoin --on-active=3 -p RuntimeMaxSec=$((G - 10)) ${SEC:+-E SEC=$SEC} ${SETUP:+-E SETUP=$SETUP} \
    ${SETTLE:+-E SETTLE=$SETTLE} ${NOSTA:+-E NOSTA=$NOSTA} ${WATCH:+-E WATCH=$WATCH} /bin/bash /root/txdbg-run.sh "$@"
echo "armed $(date +%T): K=$K hold $HOLD gap $GAP, guard in $G s"
