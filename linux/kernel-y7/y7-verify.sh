#!/bin/bash
# Post-reboot checks for the trial kernel y7 (run as root on the tablet). Diagnostic, not strictly read-only:
# it sends a 30 s ping and loads the ntsync and exfat modules (modprobe) to prove they exist.
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
echo "== t49 features"
echo "zram: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
modprobe ntsync 2>&1; ls -l /dev/ntsync 2>&1
modprobe exfat 2>&1; grep -w exfat /proc/filesystems
ls -l /sys/kernel/btf/vmlinux 2>&1 | cut -c1-80
echo "mglru: $(cat /sys/kernel/mm/lru_gen/enabled 2>&1)  yama ptrace_scope: $(cat /proc/sys/kernel/yama/ptrace_scope 2>&1)"
echo "lsm: $(cat /sys/kernel/security/lsm 2>&1)"
grep -E "CONFIG_(NTSYNC|ZRAM_BACKEND_ZSTD|DEBUG_INFO_BTF)=" /boot/config-$(uname -r) 2>/dev/null || zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_(NTSYNC|ZRAM_BACKEND_ZSTD)="
echo "== y7: iris bitstream-port restart (1030-1033; y5: every --restart line FAILs, y6: the HEVC ones still FAIL)"
bash /root/iris-restart/iris-restart-run.sh 2>&1 | grep -E "RESULT|^== "
echo "== FEX guest rootfs"; systemctl is-active y700-guestos.service; findmnt -n -o SOURCE,FSTYPE /usr/share/guestos/fex-mesa
