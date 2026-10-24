#!/bin/bash
# 06:32 one-shot collection after y700-wakewatch: results, unit state, night run sizes, current power state
export LC_ALL=C
echo "== $(date +%T) uptime $(cut -d. -f1 /proc/uptime) s"
echo "== wakewatch.txt"; cat /root/runs/postboot-20261018/wakewatch.txt
echo "== unit"; systemctl show y700-wakewatch -p ActiveState -p Result 2>&1 | tr '\n' ' '; echo
echo "== cx-auto"; /usr/local/libexec/y700-cx-auto --status 2>&1
echo "== dpms $(cat /sys/class/drm/card*-DSI-1/dpms | head -1)  bat $(cat /sys/class/power_supply/qcom-battmgr-bat/status) $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%"
echo "== inhibitions"
sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
	busctl --user call org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/PolicyAgent org.kde.Solid.PowerManagement.PolicyAgent ListInhibitions 2>&1 | head
echo "== night runs"; ls -d /root/runs/*-20261018-* 2>/dev/null | while read -r d; do echo "$(du -sk "$d" | cut -f1)K $d: $(ls "$d" | tr '\n' ' ')"; done
