#!/bin/bash
# y700-offbench.sh: screen-off power, one suspect switched off at a time (2026-10-15, owner: "只考虑降低熄屏
# 下的功耗"). ON BATTERY, display off for the whole run; every knob is put back before the next state, so each
# line is an independent delta from the baseline (which is measured first and last to show drift):
#   0 baseline      1 USB controller runtime PM allowed (power/control=auto; it had never suspended)
#   2 Bluetooth off 3 Tailscale down    4 Wi-Fi off (rfkill)    5 tb323fu-helperd stopped    6 baseline again
# Everything is restored at the end (trap) and after each state. Run by itself:
#   systemd-run --unit y700-offbench --collect /usr/local/libexec/y700-offbench.sh    (log: /var/log/y700-offbench.txt)
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
LOG=/var/log/y700-offbench.txt
SETTLE=${SETTLE:-12}; SECS=${SECS:-75}
USB=/sys/bus/platform/devices/a600000.usb
sample() { sleep "$1"; /usr/local/libexec/y700-powersample.py "$2" "$3" >> $LOG 2>&1; }
note() { echo "$(date +%T) $*" >> $LOG; }
usb_ctl() { for d in $USB $USB/*.usb $USB/*dwc3*; do [ -e "$d/power/control" ] && echo "$1" > "$d/power/control"; done; }
usb_state() { echo "usb $(cat $USB/power/runtime_status)$( [ -e $USB/a600000.usb/power/runtime_status ] && echo "/core $(cat $USB/a600000.usb/power/runtime_status)")"; }
usb0=$(cat $USB/power/control)
bt0=$("${U[@]}" bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2}')
ts0=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["BackendState"])' 2>/dev/null)
restore() {
	usb_ctl "$usb0"
	[ "$bt0" = yes ] && "${U[@]}" bluetoothctl power on >/dev/null 2>&1
	rfkill unblock wifi
	[ "$ts0" = Running ] && tailscale up --timeout=30s >/dev/null 2>&1
	systemctl start tb323fu-helperd.service
	"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
	[ -n "$INH" ] && { pkill -P "$INH" 2>/dev/null; kill "$INH" 2>/dev/null; }
	note "restored: usb control=$(cat $USB/power/control), bt $("${U[@]}" bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2}'), wifi $(rfkill list wifi | grep -c 'blocked: yes') blocked, tailscale $(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["BackendState"])' 2>/dev/null), helperd $(systemctl is-active tb323fu-helperd)"
}
trap restore EXIT; trap 'exit 1' INT TERM
"${U[@]}" kde-inhibit --power --screenSaver sleep 1500 >/dev/null 2>&1 </dev/null & INH=$!
{ echo; echo "=== $(date '+%F %T') offbench: usb control=$usb0 ($(usb_state)), bt $bt0, tailscale $ts0, $(cat /sys/class/power_supply/qcom-battmgr-bat/status) $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%"; } >> $LOG
"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
sample 20 "$SECS" "0 baseline (screen off)"

usb_ctl auto; sleep 3; note "usb: $(usb_state)"
sample "$SETTLE" "$SECS" "1 USB runtime PM auto"
usb_ctl "$usb0"; sleep 2; note "usb back: $(usb_state)"

"${U[@]}" bluetoothctl power off >/dev/null 2>&1
sample "$SETTLE" "$SECS" "2 Bluetooth off"
[ "$bt0" = yes ] && "${U[@]}" bluetoothctl power on >/dev/null 2>&1

tailscale down >/dev/null 2>&1
sample "$SETTLE" "$SECS" "3 Tailscale down"
[ "$ts0" = Running ] && tailscale up --timeout=30s >/dev/null 2>&1

rfkill block wifi
sample "$SETTLE" "$SECS" "4 Wi-Fi off"
rfkill unblock wifi; sleep 15      # NM reassociates, Tailscale finds its path again

systemctl stop tb323fu-helperd.service
sample "$SETTLE" "$SECS" "5 helperd stopped"
systemctl start tb323fu-helperd.service

sample "$SETTLE" "$SECS" "6 baseline again"
note "done"
