#!/bin/bash
# measure battery current + USB input at each refresh rate
KS() { su - user -c "export XDG_RUNTIME_DIR=/run/user/\$(id -u) WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus; kscreen-doctor $*" >/dev/null 2>&1; }
B=/sys/class/power_supply
for m in 2 1 3 4 2; do
  KS output.DSI-1.mode.$m; sleep 15
  sb=0; si=0; n=0; f0=0; f6=0
  for i in $(seq 20); do
    sb=$((sb + $(cat $B/qcom-battmgr-bat/current_now))); si=$((si + $(cat $B/qcom-battmgr-usb/current_now)))
    f0=$((f0 + $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)/1000)); n=$((n+1)); sleep 1
  done
  v=$(cat $B/qcom-battmgr-bat/voltage_now)
  echo "mode $m: bat $((sb/n/1000)) mA @ $((v/1000)) mV, usb in $((si/n/1000)) mA, avg little-cpu $((f0/n)) MHz"
done
