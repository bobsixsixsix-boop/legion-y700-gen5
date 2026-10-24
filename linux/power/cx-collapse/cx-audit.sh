#!/bin/bash
# cx-audit.sh [--off] [--clk]: read-only "who keeps the platform awake / who blocks CX" audit for the CX-collapse
# experiments (PROTOCOL.md section 4). Root. Prints to stdout:
#   cx-audit.sh --off > /var/log/y700-cx-audit-$(date +%H%M).txt     (screen off for the duration, back on after)
# It reads ONLY plain summaries of kernel data structures, PCI config space and the AOP message RAM:
#   pm_genpd summary + the PSCI domains' idle_states, qcom_stats, interconnect_summary, regulator_summary,
#   wakeup_sources, remoteproc states, cpuidle sysfs, PCI link sysfs + lspci, /proc/interrupts (chip column:
#   pdc-routed vs GICv3-only), runtime_status of UFS/USB/GPU/MDSS, psci debugfs; clk_summary only with --clk
#   (clk_core_is_enabled skips controllers that are not runtime-active, so it is safe, but it is long).
# It NEVER opens: /sys/kernel/debug/pcie@* (PARF register reads: the 03:41 bus hang), regmap/*/registers,
# dri/* register dumps, *.gpu, dwc3/usb regdumps, ufshcd*, ieee80211/phy*/ath12k/* (firmware commands), mhi*,
# /dev/mem, nor the write-only qcom_aoss knobs. Nothing is written anywhere but stdout.
set -u
OFF=0; CLK=0
for a in "$@"; do case $a in --off) OFF=1 ;; --clk) CLK=1 ;; *) echo "usage: $0 [--off] [--clk]" >&2; exit 1 ;; esac; done
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
D=/sys/kernel/debug
hdr() { echo; echo "== $*"; }
restore() { [ $OFF = 1 ] && "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; }
trap restore EXIT
if [ $OFF = 1 ]; then "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 20; fi

echo "=== $(date '+%F %T') cx-audit on $(uname -r), uptime $(cut -d' ' -f1 /proc/uptime)s, battery $(cat /sys/class/power_supply/qcom-battmgr-bat/status) $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%, dpms $(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)"
hdr cmdline; cat /proc/cmdline
hdr "knobs"
for f in /sys/module/cpuidle_psci_domain/parameters/* /sys/module/qcom_scm/parameters/download_mode /sys/devices/system/cpu/cpuidle/current_governor /sys/module/pcie_aspm/parameters/policy; do
	[ -e "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
done
hdr "cpuidle states (usage / rejected / time ms) per cpu"
for c in /sys/devices/system/cpu/cpu[0-9]*; do
	for s in "$c"/cpuidle/state*; do
		printf '%s %s %-12s %-10s usage=%s rej=%s time=%sms\n' "${c##*/}" "${s##*/}" "$(cat "$s/name")" "$(cat "$s/desc" | tr ' ' _)" "$(cat "$s/usage")" "$(cat "$s/rejected" 2>/dev/null)" "$(( $(cat "$s/time") / 1000 ))"
	done
done
hdr "pm_genpd summary"; cat $D/pm_genpd/pm_genpd_summary 2>&1
hdr "PSCI domains idle_states"
for d in $D/pm_genpd/power-domain-cluster $D/pm_genpd/power-domain-cluster1 $D/pm_genpd/power-domain-system $D/pm_genpd/power-domain-cpu[0-9]; do
	[ -d "$d" ] || continue
	echo "-- ${d##*/}: $(cat "$d/current_state" 2>/dev/null)"; cat "$d/idle_states" 2>/dev/null
done
hdr "qcom_stats (AOP message RAM)"
for f in $D/qcom_stats/*; do echo "-- ${f##*/}: $(tr '\n' ' ' < "$f" 2>/dev/null)"; done
hdr "remoteproc"; for r in /sys/class/remoteproc/*; do echo "$(cat "$r/name") $(cat "$r/state")"; done
hdr "runtime PM of the usual suspects"
for dev in /sys/bus/platform/devices/*ufshc* /sys/bus/platform/devices/*.ufs /sys/bus/platform/devices/a600000.usb /sys/bus/platform/devices/*.gpu /sys/bus/platform/devices/*display-subsystem* /sys/bus/platform/devices/*.pcie /sys/bus/platform/devices/*.remoteproc /sys/bus/platform/devices/*.dsi /sys/bus/platform/devices/*displayport-controller*; do
	[ -e "$dev/power/runtime_status" ] && printf '%-48s %-10s control=%s active=%sms suspended=%sms\n' "${dev##*/}" "$(cat "$dev/power/runtime_status")" "$(cat "$dev/power/control")" "$(cat "$dev/power/runtime_active_time" 2>/dev/null)" "$(cat "$dev/power/runtime_suspended_time" 2>/dev/null)"
done
hdr "PCI link state (config space; sysfs link/* + lspci) - NOT debugfs pcie@*"
for p in /sys/bus/pci/devices/*; do
	echo "-- ${p##*/} $(cat "$p/vendor" 2>/dev/null):$(cat "$p/device" 2>/dev/null) runtime=$(cat "$p/power/runtime_status" 2>/dev/null) control=$(cat "$p/power/control" 2>/dev/null) d3cold_allowed=$(cat "$p/d3cold_allowed" 2>/dev/null) power_state=$(cat "$p/power_state" 2>/dev/null)"
	for f in "$p"/link/*; do [ -f "$f" ] && echo "   ${f##*/}=$(cat "$f" 2>/dev/null)"; done
done
command -v lspci >/dev/null && lspci -vv 2>/dev/null | grep -E '^[0-9a-f]{2}:|LnkCap:|LnkCtl:|LnkSta:|L1SubCap:|L1SubCtl1:|L1SubCtl2:|LTR|DevCtl2'
hdr "interrupts: chip column (pdc = can wake from apps-pc; GICv3 = GIC only) and a 10 s rate"
awk 'NR>1 && $1 ~ /:$/ { n=0; i=2; while (i<=NF && $i ~ /^[0-9]+$/) { n+=$i; i++ } chip=$i; name=""; for (j=i+3;j<=NF;j++) name=name" "$j; if (name=="") name=" "$1; print $1, n, chip, name }' /proc/interrupts | sort > /tmp/.cxa1
sleep 10
awk 'NR>1 && $1 ~ /:$/ { n=0; i=2; while (i<=NF && $i ~ /^[0-9]+$/) { n+=$i; i++ } print $1, n }' /proc/interrupts | sort > /tmp/.cxa2
join /tmp/.cxa1 /tmp/.cxa2 | awk '{ d=$NF-$2; if (d>0) { chip=$3; $1=$2=$3=$NF=""; printf "%7.1f/s %-7s %s\n", d/10, chip, $0 } }' | sort -rn | head -30
echo "-- chip totals (all IRQs with any count): $(awk '{print $3}' /tmp/.cxa1 | sort | uniq -c | tr '\n' ';')"
rm -f /tmp/.cxa1 /tmp/.cxa2
hdr "wakeup sources"; cat $D/wakeup_sources 2>/dev/null | awk 'NR==1 || $2>0'
hdr "interconnect: nodes and requests with non-zero bandwidth"; awk 'NR<=2 || $(NF-1)>0 || $NF>0' $D/interconnect/interconnect_summary 2>/dev/null
hdr "regulators (full regulator_summary: the 22:47 audit's use_count filter hid everything)"; cat $D/regulator/regulator_summary 2>/dev/null
hdr "psci"; cat $D/psci 2>/dev/null
if [ $CLK = 1 ]; then hdr "clk_summary: enabled clocks"; awk 'NR<=3 || ($2 ~ /^[0-9]+$/ && $2>0)' $D/clk/clk_summary 2>/dev/null; fi
hdr "pstore / flight recorder"
ls -la /sys/fs/pstore /var/lib/systemd/pstore /var/log/y700-flightrec 2>/dev/null
tail -2 /var/log/y700-flightrec/current.log 2>/dev/null
echo; echo "=== done $(date +%T)"
