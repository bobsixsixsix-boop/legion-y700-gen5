#!/bin/bash
# log UCSI connector status + roles every 0.2 s, plus typec/usb_role uevents, for $1 seconds
dur=${1:-120}
out=/root/plugmon-$(date +%H%M%S)
d=/sys/kernel/debug/usb/ucsi/pmic_glink.ucsi.0
timeout $dur udevadm monitor -k -s usb_role -s typec -s power_supply > $out.uevents 2>&1 &
end=$(( $(date +%s) + dur ))
prev=""
while [ $(date +%s) -lt $end ]; do
  exec 9>/run/y700-usb-port.lock; flock 9
  printf 0x10012 > $d/command 2>/dev/null; r1=$(cat $d/response)
  printf 0x20012 > $d/command 2>/dev/null; r2=$(cat $d/response)
  flock -u 9; exec 9>&-
  v1=$(( 0x${r1: -8} )); v2=$(( 0x${r2: -8} ))
  dec() { local v=$1; echo "op=$(( (v>>16)&7 )) conn=$(( (v>>19)&1 )) prov=$(( (v>>20)&1 )) flags=0x$(printf %x $(( (v>>21)&0xff ))) type=$(( (v>>29)&7 ))"; }
  line="c1[$(dec $v1)] c2[$(dec $v2)] role=$(cat /sys/class/usb_role/a600000.usb-role-switch/role) p0=$(cat /sys/class/typec/port0/power_operation_mode) usbtype=$(grep -o '\[[A-Z_]*\]' /sys/class/power_supply/qcom-battmgr-usb/usb_type) online=$(cat /sys/class/power_supply/qcom-battmgr-usb/online) g9=$(lsusb | grep -c 3537:1136) bat=$(cat /sys/class/power_supply/qcom-battmgr-bat/status)"
  if [ "$line" != "$prev" ]; then echo "$(date +%T.%N | cut -c1-12) $line"; prev=$line; fi
  sleep 0.2
done > $out.status
wait
echo "$out"
