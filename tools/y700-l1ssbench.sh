#!/bin/bash
# y700-l1ssbench.sh: is PCIe L1.2 (or any ASPM state of the WCN7860 link) worth anything? Screen-off power ON BATTERY,
# Wi-Fi associated with firmware power save on, one link knob flipped per state, every knob put back before the next
# one, baseline first and last (2026-10-16, linux/power/PCIE-L1SS.md §6). PCI config space only (sysfs link/* and,
# opt-in, setpci on the endpoint); it never opens /sys/kernel/debug/pcie@* (that hung the tablet on 10-15 03:41).
#   0 baseline             1 L1.2 off                 2 L1.1 off (the link may then use L1.0 or L1.2 only)
#   3 L1 off (L0s only)    4 L0s off                  5 Clock PM off              6 baseline again
#   7 LTR experiment, only with LTR_US=<us> set: write LTR_US into the endpoint's LTR Max Snoop / Max No-Snoop
#     Latency registers (nothing on a DT platform programs them, they read 0) and measure; put back afterwards;
#     skipped unless both read 0. 8 = baseline after the restore.
# Reading the log: deltas within +-0.03 W are noise (battery current updates every 5-8 s). "1 L1.2 off" == baseline
# means L1.2 is either never entered or not worth measuring; "2 L1.1 off" shows what the substates buy at all.
# Run by itself, no ssh traffic during the run:
#   systemd-run --unit y700-l1ssbench --collect -E LTR_US=3000 /usr/local/libexec/y700-l1ssbench.sh
#   log: /var/log/y700-l1ssbench.txt (a y700-l1ss-probe snapshot is appended before and after)
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
LOG=/var/log/y700-l1ssbench.txt
EP=${EP:-0000:01:00.0}; LINK=/sys/bus/pci/devices/$EP/link
SETTLE=${SETTLE:-15}; SECS=${SECS:-120}
BAT=/sys/class/power_supply/qcom-battmgr-bat
PROBE=$(dirname "$0")/y700-l1ss-probe.sh; [ -x "$PROBE" ] || PROBE=/usr/local/libexec/y700-l1ss-probe.sh
sample() { sleep "$1"; /usr/local/libexec/y700-powersample.py "$2" "$3" >> $LOG 2>&1; }
note() { echo "$(date +%T) $*" >> $LOG; }
knobs() { local k; for k in clkpm l0s_aspm l1_aspm l1_1_aspm l1_2_aspm; do [ -e $LINK/$k ] && printf '%s=%s ' $k "$(cat $LINK/$k)"; done; }
set_knob() { [ -e "$LINK/$1" ] && echo "$2" > "$LINK/$1"; }
klog() { journalctl -k -q --since="@$1" 2>/dev/null | grep -i -E 'AER|Link Down|link down|ath12k.*(crash|reset|timeout|fail)' | tail -5; }

# --- preconditions -------------------------------------------------------------------------------------------
bat=$(cat $BAT/status 2>/dev/null); cap=$(cat $BAT/capacity 2>/dev/null)
if [ "$bat" != Discharging ] && [ "$FORCE" != 1 ]; then echo "battery is '$bat', not Discharging: unplug (or FORCE=1)" | tee -a $LOG; exit 2; fi
[ -d "$LINK" ] || { echo "no $LINK (ASPM not supported on this link, or wrong EP=)" | tee -a $LOG; exit 2; }
IF=$(iw dev 2>/dev/null | awk '/Interface/{i=$2} /ssid/{print i}' | head -1)
[ -n "$IF" ] || { echo "Wi-Fi is not associated; the whole point is the associated-idle link" | tee -a $LOG; exit 2; }
PS=$(iw dev "$IF" get power_save 2>/dev/null)
command -v setpci >/dev/null || LTR_US=        # no pciutils: silently drop the opt-in state

# --- saved state and restore ---------------------------------------------------------------------------------
declare -A K0
for k in clkpm l0s_aspm l1_aspm l1_1_aspm l1_2_aspm; do [ -e $LINK/$k ] && K0[$k]=$(cat $LINK/$k); done
restore_knobs() {   # aspm.c: writing 1 to l1_aspm does not clear the substates' disable bits, so write their files too
	local k; for k in l1_aspm l1_1_aspm l1_2_aspm l0s_aspm clkpm; do [ -n "${K0[$k]}" ] && echo "${K0[$k]}" > $LINK/$k; done
}
# LTR Max Snoop (low 16) | Max No-Snoop (high 16) as one dword at ECAP_LTR+4 ("some devices only support dword access", aspm.c)
ltr_off=$(lspci -s $EP -vv 2>/dev/null | sed -n 's/.*Capabilities: \[\([0-9a-f]*\) v[0-9]*\] Latency Tolerance Reporting.*/\1/p' | head -1)
ltr_reg() { printf '%x' $((0x$ltr_off + 4)); }
ltr_read() { [ -n "$ltr_off" ] && setpci -s $EP "$(ltr_reg).L" 2>/dev/null; }
ltr_encode() {   # us -> dword; LatencyScale n = 2^(5n) ns, LatencyValue 10 bits, rounded up; same value for both fields
	local ns=$(( $1 * 1000 )) s v="" unit
	for s in 0 1 2 3 4 5; do unit=$(( 1 << (5*s) )); if (( ns <= 1023 * unit )); then v=$(( (ns + unit - 1) / unit )); break; fi; done
	[ -z "$v" ] && { s=5; v=1023; }
	local w=$(( v | (s << 10) )); printf '%08x' $(( w | (w << 16) ))
}
ltr_write() {   # PCIe 6.18: program the ceiling while LTR is disabled; 5.5.4: L1.2 must be off while LTR is off
	local dc2; set_knob l1_2_aspm 0
	dc2=$(setpci -s $EP CAP_EXP+28.W)
	setpci -s $EP CAP_EXP+28.W="$(printf '%04x' $((0x$dc2 & ~0x400)))"   # DevCtl2 LTR Enable off
	setpci -s $EP "$(ltr_reg).L=$1"
	setpci -s $EP CAP_EXP+28.W="$dc2"                                    # LTR Enable back as it was
	set_knob l1_2_aspm "${K0[l1_2_aspm]:-1}"
}
LTR_CHANGED=; ltr0=
restore() {
	restore_knobs
	[ -n "$LTR_CHANGED" ] && ltr_write "$ltr0"
	"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
	[ -n "$INH" ] && { pkill -P "$INH" 2>/dev/null; kill "$INH" 2>/dev/null; }
	note "restored: $(knobs)ltr=$(ltr_read)"
}
trap restore EXIT; trap 'exit 1' INT TERM

# --- run -----------------------------------------------------------------------------------------------------
"${U[@]}" kde-inhibit --power --screenSaver sleep 1800 >/dev/null 2>&1 </dev/null & INH=$!
{ echo; echo "=== $(date '+%F %T') l1ssbench: battery $bat $cap%, $IF $PS, knobs: $(knobs)LTR_US=${LTR_US:-unset} ltr=$(ltr_read) SECS=$SECS"; } >> $LOG
[ -x "$PROBE" ] && "$PROBE" >> $LOG 2>&1
"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1

state() {   # label knob value: flip one knob, measure, put everything back
	local t0; t0=$(date +%s)
	set_knob "$2" "$3"; sleep 1
	note "$1: $(knobs)"
	sample "$SETTLE" "$SECS" "$1"
	local ev; ev=$(klog "$t0"); [ -n "$ev" ] && note "kernel log during '$1': $ev"
	restore_knobs; sleep 1
}
sample 20 "$SECS" "0 baseline (screen off)"
state "1 L1.2 off"           l1_2_aspm 0
state "2 L1.1 off"           l1_1_aspm 0
state "3 L1 off (L0s only)"  l1_aspm   0
state "4 L0s off"            l0s_aspm  0
state "5 ClockPM off"        clkpm     0
sample "$SETTLE" "$SECS" "6 baseline again"

if [ -n "$LTR_US" ]; then
	ltr0=$(ltr_read)
	if [ -z "$ltr_off" ]; then note "7 LTR: endpoint has no LTR capability, skipped"
	elif [ "$ltr0" != 00000000 ]; then note "7 LTR: EP max latencies already programmed ($ltr0), skipped"
	else
		t0=$(date +%s); new=$(ltr_encode "$LTR_US")
		ltr_write "$new"; LTR_CHANGED=1
		note "7 LTR max $LTR_US us: wrote $new, readback $(ltr_read), $(knobs)"
		sleep 5
		ev=$(klog "$t0")
		if [ -n "$ev" ]; then
			note "7 LTR: kernel complained right after programming, restoring: $ev"
			ltr_write "$ltr0"; LTR_CHANGED=
		else
			sample "$(( SETTLE > 5 ? SETTLE - 5 : 0 ))" "$SECS" "7 LTR max $LTR_US us"
			ev=$(klog "$t0"); [ -n "$ev" ] && note "kernel log during '7 LTR': $ev"
			ltr_write "$ltr0"; LTR_CHANGED=
			note "7 LTR restored: $(ltr_read)"
			sample "$SETTLE" "$SECS" "8 baseline after LTR restore"
		fi
	fi
fi
[ -x "$PROBE" ] && "$PROBE" >> $LOG 2>&1
note done
