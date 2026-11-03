#!/bin/bash
# y16-verify.sh: after the first boot of y16 (7.3.0-tb323fu-t52-y16 = y15 plus 1058, CONFIG_WATCHDOG_SYSFS=y, the
# kernel-t54 initramfs init; linux/kernel-y16/NOTES.md). Run as root: bash /root/y16-verify.sh  - before
# "tb323fu-ctl kernel keep", at least 4 min after boot (y700-dumpmode-off switches download mode off 3 min after boot;
# 1058 acts only then); the last line must be ALL PASS. The gate for keep is the run in trial start 1: after the
# deliberate watchdog-bite test (start 2) "no previous-boot crash" fails by design.
# y16 changes one function of qcom_scm.c, one config line and the initramfs init, so this checks:
#   - build identity: the running kernel IS /usr/local/src/y700-kernel-y16/Image-t52-y16, /proc/config.gz IS its config
#     and equals y15's apart from the lines that name the build and CONFIG_WATCHDOG_SYSFS=y, the loaded iris and ath12k
#     modules ARE the build's, the build's patch archive carries 1058 and its initramfs /init is t54's;
#   - 1058: download_mode reads off, and this boot's kernel log has "download mode off, SDI disable: 0" (the SCM call's
#     result; probe logs nothing about SDI, so before y16 there was no such line at all) and no other result;
#   - WATCHDOG_SYSFS: /sys/class/watchdog/watchdog0 is qcom_wdt, active (systemd RuntimeWatchdogSec=30 keeps it open)
#     with a 30 s timeout; INFO bootstatus (32 = WDIOF_CARDRESET: qcom_wdt saw at probe that the last reset was a
#     watchdog bite - the planned bite test checks exactly that);
#   - the health part of y15-verify.sh as it was (devices, Wi-Fi, services; lines 120-154 there).
# Not repeated: y15-verify.sh's feature tests of 1043 and 1050-1057 (decodes, error recovery, 60 s ping, AV1 probe) -
# y16~1 IS branch y15 (the same commits; y15 passed them on 10-29) and 1058 touches none of their files; and its
# debugfs reads (pm_genpd, qcom_stats): new code reads no debugfs (README, tablet rules).
# PASS/FAIL per line, exit 1 on any FAIL.
export LC_ALL=C
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
REL=7.3.0-tb323fu-t52-y16; OUT=/usr/local/src/y700-kernel-y16; MODS=/usr/local/src/y700-mods-y16/lib/modules/$REL
Y15OUT=/usr/local/src/y700-kernel-y15; UP=/usr/local/src/tb323fu-linux-t54
WD=/sys/class/watchdog/watchdog0
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
up=$(cut -d. -f1 /proc/uptime)
[ "$up" -ge 240 ] || { echo "uptime ${up}s: run this at least 4 min after boot (y700-dumpmode-off acts at 3 min)"; exit 1; }
chk "running y16: $(uname -r)" '[ "$(uname -r)" = $REL ]'
chk "cmdline: y9's unchanged (download_mode=full at boot, allow_cluster_off=0 pinned, NO allow_system_off token, idle_refresh present)" 'c=$(cat /proc/cmdline); grep -q "qcom_scm.download_mode=full" <<<"$c" && grep -q "cpuidle_psci_domain.allow_cluster_off=0" <<<"$c" && ! grep -q "allow_system_off" <<<"$c" && grep -q "msm.idle_refresh_ms60=500" <<<"$c"'
chk "systemctl --failed empty" '[ -z "$(systemctl --failed --no-legend)" ]'
chk "user units: no failed" '[ -z "$("${U[@]}" systemctl --user --failed --no-legend)" ]'
chk "no previous-boot crash (journal -b -1 ended cleanly or absent)" 'journalctl -b -1 -n 50 --no-pager -o cat 2>/dev/null | grep -qE "Journal stopped|reboot.target|Reached target System Reboot" || [ -z "$(journalctl --list-boots -q 2>/dev/null | sed -n 2p)" ]'
# ---- the build itself: what runs is what kbuild-y16.sh built from the pinned tree (Y16_TREE: y15 + 1058)
chk "the running kernel is $OUT/Image-t52-y16 (uname -v '$(uname -v)' is in that image)" 'strings $OUT/Image-t52-y16 | grep -qxF "$(uname -v)"'
chk "/proc/config.gz is the build's config-t52-y16" 'zcat /proc/config.gz | cmp -s - $OUT/config-t52-y16'
cfg_cmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#"; }
chk "the running config equals y15's ($Y15OUT/config-t52-y15) apart from LOCALVERSION / INITRAMFS_SOURCE and CONFIG_WATCHDOG_SYSFS=y" '[ "$(diff <(cfg_cmp < $Y15OUT/config-t52-y15) <(zcat /proc/config.gz | cfg_cmp) | grep "^[<>]")" = "> CONFIG_WATCHDOG_SYSFS=y" ]'
chk "the build ended with KFULL_OK (/root/y700-kernel-y16.log)" '[ "$(tail -1 /root/y700-kernel-y16.log)" = KFULL_OK ]'
iris_ko=$(modinfo -n qcom_iris 2>/dev/null); ath_ko=$(modinfo -n ath12k 2>/dev/null)
chk "the loaded iris module is the y16 build's ($iris_ko)" 'lsmod | grep -q "^qcom_iris " && cmp -s "$iris_ko" $MODS/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko'
chk "the loaded ath12k module is the y16 build's ($ath_ko)" 'lsmod | grep -q "^ath12k " && cmp -s "$ath_ko" $MODS/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko'
P=$OUT/y700-y16.patch
chk "1058 in the build: set_download_mode() calls qcom_scm_disable_sdi() when download mode goes off" 'grep -qE "^\+[[:space:]]+if \(download_mode == QCOM_DLOAD_NODUMP\) \{$" $P && grep -qE "^\+[[:space:]]+ret = qcom_scm_disable_sdi\(\);$" $P'
chk "the build's initramfs /init is kernel-t54's ($UP/kernel/initramfs/init, a9b1d5f)" 'cmp -s $OUT/initramfs.d/init $UP/kernel/initramfs/init && grep -q "does not mount read-only" $OUT/initramfs.d/init'
# ---- 1058 at run time
dl=$(cat /sys/module/qcom_scm/parameters/download_mode 2>/dev/null)
sdi=$(journalctl -k -b --no-pager -o cat | grep -F "download mode off, SDI disable: ")
chk "download_mode is off ($dl; y700-dumpmode-off, 3 min after boot)" '[ "$dl" = off ]'
chk "1058: the kernel disabled SDI when download mode went off ($(printf '%s\n' "$sdi" | grep -c .) line(s): '$(printf '%s' "$sdi" | head -1)')" '[ -n "$sdi" ] && ! grep -vqE "SDI disable: 0$" <<<"$sdi"'
# the driver's own lines only: the initramfs init writes "<1>baldur: ... qcom_scm download_mode ..." to kmsg every boot
chk "no err-level qcom_scm kernel line this boot" '[ -z "$(journalctl -k -b -p err --no-pager -o cat | grep -E "^qcom_scm[ :]")" ]'
# ---- CONFIG_WATCHDOG_SYSFS: the attributes of the hardware watchdog systemd keeps open
chk "watchdog0 is qcom_wdt ($(cat $WD/identity 2>/dev/null))" '[ "$(cat $WD/identity)" = qcom_wdt ]'
chk "watchdog0 active, timeout 30 s (state $(cat $WD/state 2>/dev/null), timeout $(cat $WD/timeout 2>/dev/null))" '[ "$(cat $WD/state)" = active ] && [ "$(cat $WD/timeout)" = 30 ]'
echo "INFO  watchdog0 bootstatus $(cat $WD/bootstatus 2>/dev/null) (32 = the last reset was a watchdog bite), nowayout $(cat $WD/nowayout 2>/dev/null), timeleft $(cat $WD/timeleft 2>/dev/null || echo n/a)"
# ---- health (y15-verify.sh lines 120-154, unchanged)
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
# (no "exit 1" inside chk's eval: it ran in this shell and killed the script after 56 PASS lines on the first y10 run)
chk "control centre + autobright user services" 'all=1; for u in y700-control-center y700-autobright; do "${U[@]}" systemctl --user is-active $u >/dev/null || all=0; done; [ $all = 1 ]'
# the HUD overlay unit stays DISABLED by design (README "y700-hud-overlay": the owner objected to it autostarting;
# the control-centre tile start/stops it), so only its presence is checked, not its state
chk "hud overlay user unit installed (disabled by design)" '"${U[@]}" systemctl --user list-unit-files y700-hud-overlay.service --no-legend | grep -q y700-hud-overlay'
chk "kwin keyboard gate effect loaded" '"${U[@]}" busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects isEffectLoaded s y700_oskgate | grep -q true'
chk "ssh + sudo path fine (AUDIT=n)" 'sudo -n -u user true'
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
