#!/bin/bash
# 2026-10-18: causal check - freeze plasmashell 20 s (SIGSTOP, always SIGCONT after) and watch cluster0 / system / apss
export LC_ALL=C
P=$(pgrep -x plasmashell | head -1)
G=/sys/kernel/debug/pm_genpd
pd() { printf "%s " "$(date +%T)"; for d in cluster cluster1 system; do printf "%s=%s " $d "$(sed -n 2p $G/power-domain-$d/idle_states | awk '{print $3"/"$4}')"; done
	printf "apss=%s timer=%s\n" "$(grep -i count /sys/kernel/debug/qcom_stats/apss | awk '{print $NF}')" "$(awk '/arch_timer/ {s = 0; for (i = 2; i <= 9; i++) s += $i; print s}' /proc/interrupts)"; }
echo "dpms=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1) aco=$(cat /sys/module/cpuidle_psci_domain/parameters/allow_cluster_off) aso=$(cat /sys/module/cpuidle_psci_domain/parameters/allow_system_off) plasmashell=$P"
trap 'kill -CONT $P' EXIT
echo "-- 20 s running"; pd; sleep 20; pd
kill -STOP $P; echo "-- 20 s stopped"; pd; sleep 20; pd
kill -CONT $P; trap - EXIT; echo "-- 20 s running again"; pd; sleep 20; pd
echo "state: $(awk '{print $3}' /proc/$P/stat)"
