#!/bin/bash
# Arm the restore guard, then run apjoin.sh K HOLD GAP [extra...] from a transient unit 3 s from now.
K=${1:-6}; HOLD=${2:-70}; GAP=${3:-20}
G=$(( K * (HOLD + GAP + 40) + 120 )); [ -n "$RELOAD" ] && G=$(( G + K * 30 ))
systemctl reset-failed y700-apjoin.service y700-aptest2-guard.service 2>/dev/null
systemd-run -q --unit y700-aptest2-guard --on-active=$G /bin/bash -c \
    'echo 0 >/sys/kernel/tracing/tracing_on; pkill -f "hostapd .*aptest2"; pkill -f "dnsmasq.*aptest2"; ip addr flush dev wlp1s0 scope global; rm -f /etc/NetworkManager/conf.d/98-y700-aptest-unmanaged.conf; pgrep -x livi-core >/dev/null || rm -f /etc/NetworkManager/conf.d/99-livi-ap-unmanaged.conf; nmcli general reload conf; [ -e /sys/class/net/wlp1s0 ] || modprobe ath12k_wifi7; sleep 5; nmcli device set wlp1s0 managed yes; nmcli device connect wlp1s0'
systemd-run -q --unit y700-apjoin --on-active=3 -p RuntimeMaxSec=$((G - 10)) ${SEC:+-E SEC=$SEC} ${SETUP:+-E SETUP=$SETUP} \
    ${SETTLE:+-E SETTLE=$SETTLE} ${NOSTA:+-E NOSTA=$NOSTA} ${WATCH:+-E WATCH=$WATCH} ${STA:+-E STA=$STA} \
    ${RELOAD:+-E RELOAD=$RELOAD} ${CLAIM:+-E CLAIM=$CLAIM} /bin/bash /root/apjoin.sh "$@"
echo "armed $(date +%T): K=$K hold $HOLD gap $GAP, guard in $G s"
