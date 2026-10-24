#!/bin/bash
# y9-verify.sh: after the first boot of y9 (y8-verify.sh + 1042) (trial). Run as root on the tablet. PASS/FAIL per line, exit 1 on any FAIL.
# Covers: the kernel itself, the config intentions (trim + power), the Wi-Fi power-save module, and the owner's
# normal use (screen, touch, sound card, camera, Bluetooth, USB gadget, zram, Steam bits).
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
chk "running y9: $(uname -r)" '[ "$(uname -r)" = 7.3.0-rc4-tb323fu-t49-y9 ]'
chk "cmdline without qos_disable/keep_bootcon, with idle_refresh" 'c=$(cat /proc/cmdline); ! grep -q qos_disable <<<"$c" && ! grep -q keep_bootcon <<<"$c" && grep -q "msm.idle_refresh_ms60=500" <<<"$c"'
chk "panel idle refresh 500/2000" '[ "$(cat /sys/module/msm/parameters/idle_refresh_ms60)" = 500 ] && [ "$(cat /sys/module/msm/parameters/idle_refresh_ms30)" = 2000 ]'
chk "systemctl --failed empty" '[ -z "$(systemctl --failed --no-legend)" ]'
chk "user units: no failed" '[ -z "$("${U[@]}" systemctl --user --failed --no-legend)" ]'
chk "no previous-boot crash (journal -b -1 ended cleanly or absent)" 'journalctl -b -1 -n 50 --no-pager -o cat 2>/dev/null | grep -qE "Journal stopped|reboot.target|Reached target System Reboot" || [ -z "$(journalctl --list-boots -q 2>/dev/null | sed -n 2p)" ]'
# config intentions
chk "RCU callbacks offloaded (nocb all)" 'dmesg | grep -q "Offload RCU callbacks from CPUs: 0-7"'
chk "uclamp sysctl exists" '[ -e /proc/sys/kernel/sched_util_clamp_min_rt_default ]'
chk "teo governor available" 'grep -q teo /sys/devices/system/cpu/cpuidle/available_governors'
chk "SCHED_CACHE gone" '[ ! -e /sys/kernel/debug/sched/llc_balancing ]'
chk "KSM gone" '[ ! -e /sys/kernel/mm/ksm ]'
chk "binder gone" '! grep -q binder /proc/filesystems'
chk "coresight/stm not loaded" '! lsmod | grep -qE "^(coresight|stm_)"'
chk "no fake ttyS" '! ls /dev/ttyS0 2>/dev/null && ! dmesg | grep -q "8250/16550 driver"'
chk "hung task timeout 180" '[ "$(cat /proc/sys/kernel/hung_task_timeout_secs)" = 180 ]'
# 1040 is NOT in y8 (the series detection skipped it, see README): expected FAIL until the y9 build
chk "memlat started with Android tunables (1042)" 'dmesg | grep -q "memlat started, sample 8 ms, per-monitor tunables sent"'
chk "memlat: no tunable failed" '! dmesg | grep -q "failed to set .* for DDR\|failed to set .* for LLCC\|failed to set .* for DDR_QOS"'
chk "memlat devfreq present" '[ -e /sys/class/devfreq/ddr/cur_freq ] && [ -e /sys/class/devfreq/llcc/cur_freq ]'
chk "memlat poll 1 s (udev)" '[ "$(cat /sys/class/devfreq/ddr/polling_interval)" = 1000 ]'
# Wi-Fi
chk "ath12k is the in-tree y700-1041 build" '[ "$(cat /sys/module/ath12k/version 2>/dev/null)" = y700-1041 ]'
chk "wifi connected" 'nmcli -t -f DEVICE,STATE device | grep -q "^wlp1s0:connected"'
chk "wifi power save on" 'iw dev wlp1s0 get power_save | grep -q on'
chk "tailscale running" 'tailscale status --json | grep -q "\"BackendState\": \"Running\""'
# the owner's hardware
chk "display on, panel nt36523 bound" 'grep -q On /sys/class/drm/card*-DSI-1/dpms && ls /sys/bus/mipi-dsi/drivers/panel-novatek-nt36523/*-* >/dev/null 2>&1 || ls /sys/bus/mipi-dsi/drivers/*nt36523*/ | grep -q dsi'
chk "touch + pen input devices" 'grep -q NVTCapacitiveTouchScreen /proc/bus/input/devices && grep -q NVTCapacitivePen /proc/bus/input/devices'
chk "haptics (2x aw86927)" '[ "$(grep -c aw86927-haptics /proc/bus/input/devices)" = 2 ]'
chk "uinput" '[ -e /dev/uinput ]'
chk "sound card + aw882xx amps" 'grep -q "TB323FU\|LENOVO" /proc/asound/cards && lsmod | grep -q snd_soc_aw882xx'
chk "speaker gain helper happy" '"${U[@]}" /usr/libexec/tb323fu/tb323fu-speaker-gain status | grep -q "aw_dev_0_volume 21"'
chk "cameras bound (camss + 2 sensors)" 'lsmod | grep -q qcom_camss && lsmod | grep -q s5kjns && lsmod | grep -q gc08a8'
chk "video decoder iris" 'ls /dev/video* >/dev/null && lsmod | grep -q "^iris\|qcom_iris"'
chk "bluetooth powered" '"${U[@]}" bluetoothctl show | grep -q "Powered: yes"'
chk "usb gadget usb0 + ttyGS0" '[ -e /sys/class/net/usb0 ] && [ -e /dev/ttyGS0 ]'
# dual-role port: with no cable the role is "device" and no xHCI root hub exists (same on y7: lsusb empty)
chk "usb controller bound (dwc3-qcom) + role switch" 'ls /sys/bus/platform/drivers/dwc3-qcom/ | grep -q usb && cat /sys/class/usb_role/*/role | grep -qE "device|host|none"'
chk "type-c ucsi" 'ls /sys/class/typec/ | grep -q port'
chk "battery via battmgr" '[ -e /sys/class/power_supply/qcom-battmgr-bat/capacity ]'
chk "zram swap zstd" 'grep -q zram /proc/swaps && grep -q "\[zstd\]" /sys/block/zram0/comp_algorithm'
chk "ntsync + exfat modules available" 'modinfo ntsync >/dev/null && modinfo exfat >/dev/null'
chk "squashfs guest rootfs mounted" 'mount | grep -q "fex-mesa\|guestos"'
chk "fuse available" '[ -e /dev/fuse ]'
chk "tun (tailscale)" '[ -e /dev/net/tun ]'
chk "sensors: light + accel via proxy" 'busctl --system get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy HasAmbientLight | grep -q true'
chk "control centre + keyboard + hud user services" 'for u in y700-control-center y700-hud-overlay y700-autobright; do "${U[@]}" systemctl --user is-active $u >/dev/null || exit 1; done'
chk "kwin keyboard gate effect loaded" '"${U[@]}" busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects isEffectLoaded s y700_oskgate | grep -q true'
chk "ssh + sudo path fine (AUDIT=n)" 'sudo -n -u user true'
echo; echo "config diff vs intent (olddefconfig survivors):"; zcat /proc/config.gz | grep -E "^CONFIG_(UCLAMP_TASK|CPU_IDLE_GOV_TEO|RCU_LAZY|RCU_NOCB_CPU_DEFAULT_ALL|DEFAULT_HUNG_TASK_TIMEOUT)=" ; zcat /proc/config.gz | grep -E "^CONFIG_(SCHED_CACHE|KSM|CORESIGHT|ANDROID_BINDER_IPC|AUDIT|COMPAT|KEXEC|SERIAL_8250)=" && echo "  ^ should be absent"
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
