#!/bin/bash
# always-on-check.sh [--off] [--rtc SECONDS] [--no-clk]: read-only state check of the six "always-on" items in
# linux/power/ALWAYS-ON.md (CDSP, USB3 PHY GDSC, Bluetooth UART, UFS/ICE, LPASS clocks, RTC wakeups, PCIe cross-ref)
# and of who still holds the XO. Root, on the tablet. Prints to stdout:
#   always-on-check.sh --off --rtc 90 > /var/log/y700-always-on-$(date +%H%M).txt
# --off     DPMS off for the whole run (20 s settle first), back on at exit (same as cx-audit.sh)
# --rtc N   capture rtc:* tracepoints for N seconds in a private tracefs instance (who calls rtc_set_time / sets
#           alarms); the instance is removed afterwards. This is the only thing the script writes anywhere.
# --no-clk  skip /sys/kernel/debug/clk/clk_summary (reading it briefly runtime-resumes clock controllers: do not
#           read it inside a power-measurement window)
# NEVER opened: /sys/kernel/debug/pcie@*, regmap, dri, *.gpu, ufshcd*, ath12k, mhi, /dev/mem, the qcom_aoss knobs
# (register-class debugfs hung the bus on 2026-10-15 03:41). Everything else is plain sysfs/procfs/summary files.
set -u
OFF=0; RTC=0; CLK=1
while [ $# -gt 0 ]; do
	case $1 in
	--off) OFF=1 ;;
	--rtc) RTC=${2:-60}; shift ;;
	--no-clk) CLK=0 ;;
	*) echo "usage: $0 [--off] [--rtc SECONDS] [--no-clk]" >&2; exit 1 ;;
	esac
	shift
done
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
D=/sys/kernel/debug
P=/sys/bus/platform/devices
GENPD=$D/pm_genpd/pm_genpd_summary
CLKS=$D/clk/clk_summary
TRACE=/sys/kernel/tracing/instances/y700-always-on
hdr() { echo; echo "== $*"; }
rd() { cat "$1" 2>/dev/null || echo "-"; }
rpm() { # name path: runtime status line of one device
	[ -e "$2/power/runtime_status" ] || { printf '%-44s (no such device)\n' "$1"; return; }
	printf '%-44s %-11s control=%-5s active=%sms suspended=%sms\n' "$1" "$(rd $2/power/runtime_status)" "$(rd $2/power/control)" \
		"$(rd $2/power/runtime_active_time)" "$(rd $2/power/runtime_suspended_time)"
}
genpd() { # domain names: the domain line plus its device lines (indented ones that follow)
	for dom in "$@"; do awk -v d="$dom" '$1==d {p=1; print; next} p && /^    / {print; next} p {exit}' $GENPD 2>/dev/null; done
}
clk() { [ $CLK = 1 ] || return 0; grep -E "$1" $CLKS 2>/dev/null | awk '$2 ~ /^[0-9]+$/' | sed 's/^ *//' | cut -c1-140; }
clkon() { [ $CLK = 1 ] || return 0; grep -E "$1" $CLKS 2>/dev/null | awk '$2 ~ /^[0-9]+$/ && $2 > 0' | sed 's/^ *//' | cut -c1-140; }   # enable_cnt > 0 only
restore() {
	[ -d "$TRACE" ] && { echo 0 > $TRACE/tracing_on 2>/dev/null; echo 0 > $TRACE/events/rtc/enable 2>/dev/null; rmdir $TRACE 2>/dev/null; }
	[ $OFF = 1 ] && "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
}
trap restore EXIT
if [ $OFF = 1 ]; then "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 20; fi

echo "=== $(date '+%F %T') always-on-check on $(uname -r), uptime $(cut -d' ' -f1 /proc/uptime)s, battery $(rd /sys/class/power_supply/qcom-battmgr-bat/status) $(rd /sys/class/power_supply/qcom-battmgr-bat/capacity)%, dpms $(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)"
[ -r $GENPD ] || echo "WARN: $GENPD not readable (run as root, debugfs mounted?)"

hdr "1. CDSP (ALWAYS-ON.md section 1): expected offline once tb323fu-dsp-no-cdsp.conf is installed; it holds no clock either way"
for r in /sys/class/remoteproc/*; do echo "$(rd $r/name) $(rd $r/state)"; done
echo "fastrpc nodes: $(ls /dev/fastrpc-* 2>/dev/null | tr '\n' ' ')"
echo "fastrpc module users: $(awk '$1=="fastrpc"{print $3}' /proc/modules 2>/dev/null)"
echo "qcom_stats cdsp: $(tr '\n' ' ' < $D/qcom_stats/cdsp 2>/dev/null)"
genpd nsp mxc cx | grep -E "^(nsp|mxc|cx) |26300000"
clk "^ *(xo-board|bi_tcxo|bi-tcxo-div2-clk|dsi0vco_clk|clk1) "

hdr "2. USB3 PHY GDSC (section 2): on by design (pm_runtime_forbid + aux_bridge without runtime PM + 0059 RET_ON); PHY clocks must be off"
rpm a600000.usb $P/a600000.usb
rpm 88e8000.phy $P/88e8000.phy
genpd gcc_usb3_phy_gdsc gcc_usb30_prim_gdsc
echo "typec port0: power_role=$(rd /sys/class/typec/port0/power_role) data_role=$(rd /sys/class/typec/port0/data_role); DP-1 $(cat /sys/class/drm/card*-DP-1/status 2>/dev/null | head -1)"
echo "usb3 clocks with enable_cnt>0 (expected none):"; clkon "usb3_prim|usb30_prim"

hdr "3. Bluetooth UART (section 3): the SE stays on while hci0 is powered; IBS votes never reach the serial driver"
echo "hci0: $(bluetoothctl show 2>/dev/null | grep -E 'Powered|Discoverable:' | tr -d '\t' | tr '\n' ' ')"
rpm 1994000.serial $P/1994000.serial
rpm 19c0000.geniqup $P/19c0000.geniqup
clk "qupv3_wrap3_s5|qupv3_wrap_3_|gcc_gpll0 "

hdr "4. UFS / ICE (section 4): host should be runtime-suspended with the screen off and ICE 403 MHz off with it; gcc_ufs_phy_gdsc stays on until the ICE driver gets runtime PM"
UF=$P/1d84000.ufs
rpm 1d84000.ufs $UF
echo "rpm_lvl=$(rd $UF/rpm_lvl) spm_lvl=$(rd $UF/spm_lvl) clkgate_enable=$(rd $UF/clkgate_enable) clkgate_delay_ms=$(rd $UF/clkgate_delay_ms) auto_hibern8=$(rd $UF/auto_hibern8)"
for s in /sys/bus/scsi/devices/*/power/runtime_status; do [ -e "$s" ] && printf '  %s %s\n' "$(echo $s | cut -d/ -f6)" "$(cat $s)"; done | head -8
genpd gcc_ufs_phy_gdsc gcc_ufs_mem_phy_gdsc
clk "ufs_phy_ice_core|ufs_phy_ahb|ufs_phy_axi|ufs_phy_unipro|gcc_gpll4 "
a=$(awk '$3=="sda"{print $4" reads "$8" writes"}' /proc/diskstats); sleep 10; b=$(awk '$3=="sda"{print $4" reads "$8" writes"}' /proc/diskstats)
echo "sda I/O over 10 s: before [$a] after [$b]"
echo "flight recorder: $(systemctl is-active y700-flightrec 2>/dev/null) (experiment: a line every 1 s, fdatasync every 5 lines; idle: every 10 s / 6 lines, ~1 min - since 2026-10-17, flightrec/src/main.rs:16-22; the old Python recorder synced every 5 s)"

hdr "5a. LPASS macros / soundwire (section 5a): macros autosuspend in 100 ms unless a soundwire master or an open PCM holds them"
for d in $P/*.codec $P/*soundwire* /sys/bus/soundwire/devices/*; do [ -e "$d/power/runtime_status" ] && rpm "${d##*/}" "$d"; done
echo "open PCMs:"; grep -H . /proc/asound/card0/pcm*/sub0/status 2>/dev/null | grep -v closed | cut -c1-120
echo "holders of /dev/snd/pcm*:"; fuser -v /dev/snd/pcm* 2>&1 | grep -v "^$" | head -6
echo "pipewire nodes running:"; "${U[@]}" pw-cli ls Node 2>/dev/null | grep -B6 'state = "running"' | grep -E 'node.name|state' | head -12
echo "qcom_stats adsp: $(tr '\n' ' ' < $D/qcom_stats/adsp 2>/dev/null) island: $(tr '\n' ' ' < $D/qcom_stats/adsp_island 2>/dev/null)"
clk "LPASS_|fsgen"

hdr "5b. RTC (section 5b): 61 events/25 min were most likely failed rtc_set_time() from CONFIG_RTC_SYSTOHC + chrony rtcsync"
awk 'NR==1 || /rtc@6100/' $D/wakeup_sources 2>/dev/null
cat /proc/driver/rtc 2>/dev/null | grep -E "alrm_time|alrm_date|alarm_IRQ|alrm_pending|update IRQ|periodic IRQ"
echo "wakealarm: '$(rd /sys/class/rtc/rtc0/wakealarm)'  holders of /dev/rtc0: $(fuser /dev/rtc0 2>/dev/null | tr -s ' ')"
echo "chrony.conf rtcsync: $(grep -n '^[[:space:]]*rtcsync' /etc/chrony/chrony.conf 2>/dev/null || echo 'absent')"
echo "chronyc: $(chronyc -n tracking 2>/dev/null | grep -E 'Leap status|Stratum' | tr '\n' ' ')"
if [ "$RTC" -gt 0 ] 2>/dev/null; then
	if mkdir $TRACE 2>/dev/null && [ -d $TRACE/events/rtc ]; then
		echo 0 > $TRACE/tracing_on; : > $TRACE/trace
		for e in rtc_set_time rtc_set_alarm rtc_alarm_irq_enable rtc_timer_fired rtc_timer_enqueue; do echo 1 > $TRACE/events/rtc/$e/enable 2>/dev/null; done
		echo 1 > $TRACE/tracing_on
		echo "-- rtc tracepoints for $RTC s (err=-19 = -ENODEV: the RTC cannot be set; a kworker comm = the kernel's systohc path):"
		sleep "$RTC"
		echo 0 > $TRACE/tracing_on
		grep -v "^#" $TRACE/trace | sed 's/^ *//' | cut -c1-150
		echo "-- $(grep -c rtc_set_time $TRACE/trace) rtc_set_time, $(grep -c rtc_set_alarm $TRACE/trace) rtc_set_alarm, $(grep -c rtc_alarm_irq_enable $TRACE/trace) alarm_irq_enable, $(grep -c rtc_timer_fired $TRACE/trace) timer_fired in $RTC s"
		echo 0 > $TRACE/events/rtc/enable 2>/dev/null; rmdir $TRACE 2>/dev/null
	else
		echo "(tracefs instance not available: is /sys/kernel/tracing mounted?)"
	fi
fi

hdr "6. PCIe (cross-reference to the PCIe task; no debugfs pcie@* here)"
rpm 1c00000.pcie $P/1c00000.pcie
genpd gcc_pcie_0_gdsc gcc_pcie_0_phy_gdsc
clk "pcie_0_aux|pcie_0_phy_aux|pcie_0_phy_rchng|pcie0_pipe_clk|gcc_pcie_0_pipe"

hdr "7. who holds the XO (bi_tcxo is voted in the sleep set too: these block aosd once ss3 is allowed)"
clk "^ *(xo-board|bi_tcxo|bi-tcxo-div2-clk|gcc_gpll0|gcc_gpll0_out_even|gcc_gpll4|gcc_pcie_0_aux_clk_src|gcc_pcie_0_phy_aux_clk_src|gcc_qupv3_wrap3_s5_clk_src|gcc_ufs_phy_ice_core_clk_src|disp_cc_pll0|dsi0vco_clk) "
echo; echo "=== done $(date +%T)"
