#!/bin/bash
# y700-l1ss-probe.sh: read-only snapshot of the WCN7860 PCIe link's ASPM / L1 PM Substates / LTR configuration
# (2026-10-16, see linux/power/PCIE-L1SS.md §5). PCI config-space reads only (lspci, sysfs): it never opens
# /sys/kernel/debug/pcie@* -- reading those PARF debug registers over AHB is what hung the tablet on 10-15 03:41.
# Run as root (lspci needs root to decode extended capabilities). Output is plain text; paste it into the research.
# Optional: MHI_SECS=30 also samples the MHI M0/M2 state changes for 30 s through one tracefs tracepoint (see below).
EP=${EP:-0000:01:00.0}; RP=${RP:-0000:00:00.0}
S=/sys/bus/pci/devices
hdr() { printf '\n## %s\n' "$*"; }

hdr "kernel / policy"
uname -r
echo "pcie_aspm policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
echo "cmdline: $(cat /proc/cmdline)"

hdr "sysfs link/ knobs (y = enabled; file missing = state not supported on this link)"
for d in $RP $EP; do
	printf '%s:' "$d"
	for f in $S/$d/link/*; do [ -e "$f" ] && printf ' %s=%s' "$(basename "$f")" "$(cat "$f")"; done
	echo
done
echo "EP power_state=$(cat $S/$EP/power_state 2>/dev/null) runtime_status=$(cat $S/$EP/power/runtime_status 2>/dev/null) d3cold_allowed=$(cat $S/$EP/d3cold_allowed 2>/dev/null)"
echo "RP power_state=$(cat $S/$RP/power_state 2>/dev/null) runtime_status=$(cat $S/$RP/power/runtime_status 2>/dev/null)"
echo "EP driver=$(basename "$(readlink $S/$EP/driver 2>/dev/null)") RP driver=$(basename "$(readlink $S/$RP/driver 2>/dev/null)")"

# The lines that decide L1.2 (pciutils ls-caps.c / ls-ecaps.c wording):
#   LnkCap/LnkCtl/LnkSta        : ASPM support/enable, ClockPM, exit latencies, speed/width
#   DevCap2/DevCtl2 LTR+         : LTR supported / enabled (both ends must be enabled, else aspm.c drops ASPM L1.2)
#   Latency Tolerance Reporting  : Max snoop / Max no snoop latency the EP may *request* (0ns = nobody programmed it)
#   L1SubCap                     : PortCommonModeRestoreTime, PortTPowerOnTime (RP is expected to say 0us: no t-power-on-us in DT)
#   L1SubCtl1                    : enables, T_CommonMode, LTR1.2_Threshold (aspm.c: 2+4+Tcm+TpwrOn us, rounded up)
#   L1SubCtl2                    : T_PwrOn programmed (max of the two caps)
PAT='LnkCap:|LnkCtl:|LnkSta:|DevCap2:|DevCtl2:|Latency Tolerance|Max snoop|Max no snoop|L1 PM Substates|L1SubCap|PortCommonMode|L1SubCtl|T_CommonMode|LTR1.2|T_PwrOn|Capabilities: \['
for d in $RP $EP; do
	hdr "lspci -vvv $d (ASPM / LTR / L1SS lines only)"
	lspci -vvv -s "$d" 2>&1 | grep -E "$PAT" | sed 's/^[[:space:]]*/  /'
done

hdr "derived"
# Expected LTR_L1.2_THRESHOLD per aspm.c aspm_calc_l12_info(): 2 + 4 + max(CommonModeRestore) + max(TPowerOn) us.
ep=$(lspci -vvv -s "$EP" 2>/dev/null); rp=$(lspci -vvv -s "$RP" 2>/dev/null)
num() { printf '%s\n' "$1" | sed -n "s/.*$2=\([0-9]*\)us.*/\1/p" | head -1; }
cm_ep=$(num "$ep" PortCommonModeRestoreTime); cm_rp=$(num "$rp" PortCommonModeRestoreTime)
tp_ep=$(num "$ep" PortTPowerOnTime);           tp_rp=$(num "$rp" PortTPowerOnTime)
th=$(printf '%s\n' "$ep" | sed -n 's/.*LTR1.2_Threshold=\([0-9]*\)ns.*/\1/p' | head -1)
snoop=$(printf '%s\n' "$ep" | sed -n 's/.*Max snoop latency: \([0-9]*\)ns.*/\1/p' | head -1)
nosnoop=$(printf '%s\n' "$ep" | sed -n 's/.*Max no snoop latency: \([0-9]*\)ns.*/\1/p' | head -1)
if [ -n "$cm_ep$cm_rp$tp_ep$tp_rp" ]; then
	cm=$(( ${cm_ep:-0} > ${cm_rp:-0} ? ${cm_ep:-0} : ${cm_rp:-0} )); tp=$(( ${tp_ep:-0} > ${tp_rp:-0} ? ${tp_ep:-0} : ${tp_rp:-0} ))
	echo "CommonModeRestore RP=${cm_rp:-?}us EP=${cm_ep:-?}us -> $cm us; TPowerOn RP=${tp_rp:-?}us EP=${tp_ep:-?}us -> $tp us"
	echo "aspm.c formula threshold = 2+4+$cm+$tp = $((6 + cm + tp)) us; programmed LTR1.2_Threshold = ${th:-?} ns"
	[ "${tp_rp:-0}" = 0 ] && echo "RP TPowerOn is 0us: the Root Port never got t-power-on-us (Qualcomm says 80us), see PCIE-L1SS.md §3.5"
fi
echo "EP LTR Max snoop=${snoop:-?}ns Max no snoop=${nosnoop:-?}ns"
if [ "${snoop:-x}" = 0 ] && [ "${nosnoop:-x}" = 0 ]; then
	echo "-> both 0: nothing programmed the EP's LTR ceiling (no BIOS on a DT platform). PCIE-L1SS.md R3 (Max=0 read as a ceiling,"
	echo "   demoted) stays testable with l1ssbench LTR_US=; the L1.2 decision rests on the LTR the firmware reports, invisible here."
fi
grep -q 'ASPM_L1.2+' <<<"$ep" && echo "EP L1SubCtl1 has ASPM_L1.2+ (enabled)" || echo "EP L1SubCtl1: ASPM L1.2 NOT enabled"

hdr "MHI device power-state churn (tracefs tracepoints only; MHI_SECS=${MHI_SECS:-0}, 0 = skipped)"
# mhi_tryset_pm_state fires on every host-side MHI PM state change (drivers/bus/mhi/host/pm.c:135): M0 = device awake,
# M2 = the device went idle and the host let it sleep, M3 = suspend. "M2 per second" is how often the WCN7860 gets to
# idle at the MHI level, i.e. the firmware state in which its LTR can be the large "sleep" value (PCIE-L1SS.md §3.1/§5).
# It is NOT an L1.2 counter (that is the forbidden debugfs file). Built in with CONFIG_TRACEPOINTS, no MHI_BUS_DEBUG
# needed. Nothing here reads a hardware register; everything touched (event enable, tracing_on, buffer) is put back.
T=/sys/kernel/tracing; EV=$T/events/mhi_host/mhi_tryset_pm_state/enable
if [ "${MHI_SECS:-0}" -gt 0 ] 2>/dev/null && [ -w "$EV" ]; then
	if [ -n "$(cat $T/set_event 2>/dev/null)" ]; then   # tracefs files always stat as 0 bytes, so [ -s ] would never fire
		echo "skipped: tracefs already has events enabled ($(tr '\n' ' ' < $T/set_event)) -- y700-wakeups running? retry later"
	else
		on0=$(cat $T/tracing_on); ev0=$(cat "$EV")
		mhi_restore() { echo "$ev0" > "$EV"; echo > $T/trace; echo "$on0" > $T/tracing_on; }
		trap mhi_restore EXIT
		echo 0 > $T/tracing_on; echo > $T/trace; echo 1 > "$EV"; echo 1 > $T/tracing_on
		sleep "$MHI_SECS"
		echo 0 > $T/tracing_on
		n=$(grep -c 'PM state:' $T/trace)
		echo "$n MHI PM state changes in $MHI_SECS s:"
		sed -n 's/.*PM state: //p' $T/trace | sed 's/[[:space:]]*$//' | sort | uniq -c | sort -rn | sed 's/^/  /'
		[ "$n" = 0 ] && echo "  -> the device never left its state: either it is parked in M0 (firmware not idling: check 1041 / host traffic) or always in M2"
		mhi_restore; trap - EXIT
	fi
else
	echo "set MHI_SECS=30 to sample (needs root and $EV)"
fi

hdr "Wi-Fi state (power save must be on for a meaningful idle measurement)"
for i in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
	echo "$i: $(iw dev "$i" link 2>/dev/null | sed -n '1p;/freq/p' | tr '\n' ' ') $(iw dev "$i" get power_save 2>/dev/null)"
done

hdr "kernel log: AER / ASPM / link events (last 20)"
dmesg 2>/dev/null | grep -i -E 'AER|aspm|L1SS|Link Down|link down|LTR|pcie.*(link|retrain)' | tail -20
