#!/bin/bash
# Post-reboot checks for a trial kernel (run as root on the tablet). Read-only apart from a 30 s ping.
u=user; uid=$(id -u $u)
asuser() { runuser -u $u -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "$@"; }
echo "== kernel";  uname -r; uptime
echo "== failed units"; systemctl --failed --no-legend; asuser systemctl --user --failed --no-legend
echo "== dmesg err/warn: $(dmesg -l err,warn | wc -l) lines; notable:"
dmesg -l err,warn | grep -iE "ssbd|sigreturn|gmu|hfi|a6xx|adreno|BUG|Oops|WARNING|Call trace" | head -15
echo "== ssbd_sigreturn"; dmesg | grep -i ssbd | head -3; grep -o "ssbd_sigreturn=[^ ]*" /proc/cmdline
echo "== wifi"; nmcli -t -f NAME,DEVICE con show --active | grep -v ':lo$'
iw dev wlp1s0 link | grep -E "SSID|freq|signal|tx bitrate"
gw=$(ip -4 route show default dev wlp1s0 | awk '{print $3; exit}')
[ -n "$gw" ] && ping -q -c 30 -i 1 "$gw" | tail -2
echo "== sound"; cat /proc/asound/cards; dmesg | grep -iE "version magic|deferred probe pending" | head -5
/usr/libexec/tb323fu/tb323fu-speaker-gain status 2>&1 | tail -3
asuser pactl get-default-sink; asuser pactl list sinks short | cut -f2
echo "== vaapi"; asuser vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -cE "VAProfile.*VAEntrypointVLD"
echo "== kernel slot"; tb323fu-ctl kernel status 2>&1 | head -6
