#!/bin/bash
# offmeasure.sh TAG: screen-off measurement for the wakeup-reduction A/B (2026-10-16). ON BATTERY.
#   display off -> 20 s settle -> y700-wakeups 30 s (tracefs, saved) -> y700-powersample 90 s -> display on.
# Run through systemd-run so a dropped ssh session cannot take the restore path down with it:
#   systemd-run --unit y700-offmeasure --collect /root/offmeasure.sh before-dropins
# Results: /root/wk-<TAG>.txt (+ .trace), power line appended to /var/log/y700-offbench.txt (offbench format).
set -u
TAG=${1:?tag}
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
LOG=/var/log/y700-offbench.txt
INH=
restore() { trap - EXIT; "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; [ -n "$INH" ] && { pkill -P "$INH" 2>/dev/null; kill "$INH" 2>/dev/null; }; echo "$(date +%T) offmeasure $TAG done, display $(cat /sys/class/drm/card*-DSI-1/dpms | head -1)" | tee -a "$LOG"; }
trap restore EXIT; trap 'exit 1' INT TERM
st=$(cat /sys/class/power_supply/qcom-battmgr-bat/status)
{ echo; echo "=== $(date '+%F %T') offmeasure $TAG on $(uname -r), $st $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%, $(iw dev wlp1s0 link 2>/dev/null | grep SSID | tr -d '\t'), aco=$(cat /sys/module/cpuidle_psci_domain/parameters/allow_cluster_off) aso=$(cat /sys/module/cpuidle_psci_domain/parameters/allow_system_off)"; } >> "$LOG"
[ "$st" = Discharging ] || echo "WARN: not discharging ($st) - power line meaningless" | tee -a "$LOG"
"${U[@]}" kde-inhibit --power --screenSaver sleep 400 >/dev/null 2>&1 </dev/null & INH=$!
"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
sleep 20
[ "$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)" = Off ] || { echo "ABORT: display not off" | tee -a "$LOG"; exit 2; }
python3 /root/y700-wakeups.py 30 --timer-list --save "/root/wk-$TAG.trace" > "/root/wk-$TAG.txt" 2>&1
echo "wakeups: $(grep -m1 -iE "idle exits|cpu_idle|wakeups/s|per second" "/root/wk-$TAG.txt" | cut -c1-160)" >> "$LOG"
/usr/local/libexec/y700-powersample.py 90 "$TAG (screen off)" >> "$LOG" 2>&1
tail -3 "$LOG"
