#!/bin/bash
# In a transient unit: load the test-only instrumented ath12k (/root/ath12k-txdbg), run apjoin.sh "$@", load the
# stock module back. Log: /root/aptest2/txdbg-run.log (apjoin.sh writes its own join-* directory).
exec >>/root/aptest2/txdbg-run.log 2>&1
W=/root/ath12k-txdbg/ath/ath12k
echo "== $(date +%T) load txdbg, args $*"
modprobe -r ath12k_wifi7 ath12k || { echo "unload failed"; /root/txdbg-restore.sh; exit 1; }
sleep 1
insmod $W/ath12k.ko && insmod $W/wifi7/ath12k_wifi7.ko || { echo "insmod failed"; /root/txdbg-restore.sh; exit 1; }
for i in $(seq 45); do nmcli -t -f DEVICE,STATE device | grep -q '^wlp1s0:connected' && break; sleep 1; done
echo "$(date +%T) module $(cat /sys/module/ath12k/version), $(nmcli -t -f DEVICE,STATE,CONNECTION device | grep wlp1s0)"
/bin/bash /root/apjoin.sh "$@"
echo "== $(date +%T) restore"
/root/txdbg-restore.sh
echo "== $(date +%T) done: module $(cat /sys/module/ath12k/version)"
