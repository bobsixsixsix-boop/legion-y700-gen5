#!/bin/bash
# Back to the stock ath12k when the test-only txdbg module is loaded, then NetworkManager owns wlp1s0 again.
# Run by txdbg-run.sh at the end and by the guard unit if the run hangs.
echo 0 >/sys/kernel/tracing/tracing_on
pkill -f "hostapd .*aptest2"; pkill -f "dnsmasq.*aptest2"
if grep -q txdbg /sys/module/ath12k/version 2>/dev/null; then
    modprobe -r ath12k_wifi7 ath12k; sleep 1; modprobe ath12k_wifi7
    for i in $(seq 30); do [ -e /sys/class/net/wlp1s0 ] && break; sleep 1; done
fi
ip addr flush dev wlp1s0 scope global
nmcli device set wlp1s0 managed yes; nmcli device connect wlp1s0
