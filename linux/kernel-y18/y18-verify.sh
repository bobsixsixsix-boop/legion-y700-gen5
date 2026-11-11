#!/bin/bash
# y18-verify.sh: after the first boot of y18 (7.3.0-tb323fu-t52-y18 = y17 + upstream kernel-t58 0144, 0147-0153, no
# no_console_suspend, hung tasks reported not panicked; linux/kernel-y18/NOTES.md). Run as root: bash /root/y18-verify.sh
# - in trial start 1, before "tb323fu-ctl kernel keep", at least 4 min after boot (y16's SDI check below:
# y700-dumpmode-off acts at 3 min); the last line must be ALL PASS.
# Checks:
#   - build identity: the running kernel IS /usr/local/src/y700-kernel-y18/Image-t52-y18, /proc/config.gz IS its config
#     and equals y17's apart from exactly the hung-task panic and the CMDLINE, its patch archive is NOT y17's and carries
#     0144 / 0153, the loaded iris and ath12k modules ARE the build's;
#   - the eight at run time, as far as this tablet can show them without a USB-C monitor, a microSD card or a pen:
#     0144 KWin sees the panel as 118 x 190 mm and keeps scale 1.9 (the saved output config), Xwayland 1.9 and Xft.dpi
#     182 untouched; 0148 printk's console_suspend is Y (no no_console_suspend on the cmdline); DP-1 connector, dwc3-qcom,
#     type-c, mmc0 host all present (0147/0149-0152's code paths exist, idle); the pen input device still registers (0153);
#   - the config: hung_task_panic 0, hung_task_timeout_secs 180, softlockup_panic 1 (kbuild-y18.sh's BOOTPARAM lines);
#   - the initramfs and the root checks exactly as y17-verify.sh (y17's init, the static e2fsck, two e2fsck runs);
#   - y16-verify.sh's checks as they were (1058's SDI line, watchdog0, health).
# INFO lines: DP-1 status, the HS-PHY L2 warnings (3 per boot since y7, not y18's), mmc0 cards, hung-task lines (0).
# The init's kmsg lines carry "baldur:", which journalctl -o cat strips (it is their syslog identifier): read with
# -o short --no-hostname, where they are "... baldur:  fsck ..." and the kernel's "... kernel: EXT4-fs (sda15): ...".
# PASS/FAIL per line, exit 1 on any FAIL.
export LC_ALL=C
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
REL=7.3.0-tb323fu-t52-y18; OUT=/usr/local/src/y700-kernel-y18; MODS=/usr/local/src/y700-mods-y18/lib/modules/$REL
Y17OUT=/usr/local/src/y700-kernel-y17
Y17_INIT_SHA=b450a91a698592773f22f091c3061992d8df4c02240ca35365d9a7b5e37990ce   # kbuild-y17.sh's and kbuild-y18.sh's pin
E2S=/usr/sbin/e2fsck.static
WD=/sys/class/watchdog/watchdog0
HOME_P=$(getent passwd user | cut -d: -f6)
# the two command lines (kbuild-y18.sh): y17's and y18's = the same minus no_console_suspend
Y17_CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
EXPECTED_DELTA="< CONFIG_BOOTPARAM_HUNG_TASK_PANIC=1
< CONFIG_CMDLINE=\"$Y17_CMDLINE\"
> CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0
> CONFIG_CMDLINE=\"$CMDLINE\""
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
up=$(cut -d. -f1 /proc/uptime)
[ "$up" -ge 240 ] || { echo "uptime ${up}s: run this at least 4 min after boot (y700-dumpmode-off acts at 3 min)"; exit 1; }
chk "running y18: $(uname -r)" '[ "$(uname -r)" = $REL ]'
chk "cmdline: y9's tokens (download_mode=full, allow_cluster_off=0, idle_refresh), NO allow_system_off, NO no_console_suspend (0148)" 'c=$(cat /proc/cmdline); grep -q "qcom_scm.download_mode=full" <<<"$c" && grep -q "cpuidle_psci_domain.allow_cluster_off=0" <<<"$c" && ! grep -q "allow_system_off" <<<"$c" && grep -q "msm.idle_refresh_ms60=500" <<<"$c" && ! grep -q "no_console_suspend" <<<"$c"'
chk "systemctl --failed empty" '[ -z "$(systemctl --failed --no-legend)" ]'
chk "user units: no failed" '[ -z "$("${U[@]}" systemctl --user --failed --no-legend)" ]'
chk "no previous-boot crash (journal -b -1 ended cleanly or absent)" 'journalctl -b -1 -n 50 --no-pager -o cat 2>/dev/null | grep -qE "Journal stopped|reboot.target|Reached target System Reboot" || [ -z "$(journalctl --list-boots -q 2>/dev/null | sed -n 2p)" ]'
# ---- the build itself: what runs is what kbuild-y18.sh built
chk "the running kernel is $OUT/Image-t52-y18 (uname -v '$(uname -v)' is in that image)" 'strings $OUT/Image-t52-y18 | grep -qxF "$(uname -v)"'
chk "/proc/config.gz is the build's config-t52-y18" 'zcat /proc/config.gz | cmp -s - $OUT/config-t52-y18'
cfg_cmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#"; }
chk "the running config equals y17's ($Y17OUT/config-t52-y17) apart from BOOTPARAM_HUNG_TASK_PANIC and CMDLINE" '[ "$(diff <(cfg_cmp < $Y17OUT/config-t52-y17) <(zcat /proc/config.gz | cfg_cmp) | grep "^[<>]" | sort)" = "$EXPECTED_DELTA" ]'
chk "the build's patch archive is not y17's and carries 0144 and 0153" '! cmp -s $OUT/y700-y18.patch $Y17OUT/y700-y17.patch && grep -qF ".width_mm = 118," $OUT/y700-y18.patch && grep -qF "pen_tilt_x = -(int8_t)point_data[74];" $OUT/y700-y18.patch'
chk "the build ended with KFULL_OK (/root/y700-kernel-y18.log)" '[ "$(tail -1 /root/y700-kernel-y18.log)" = KFULL_OK ]'
iris_ko=$(modinfo -n qcom_iris 2>/dev/null); ath_ko=$(modinfo -n ath12k 2>/dev/null)
chk "the loaded iris module is the y18 build's ($iris_ko)" 'lsmod | grep -q "^qcom_iris " && cmp -s "$iris_ko" $MODS/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko'
chk "the loaded ath12k module is the y18 build's ($ath_ko)" 'lsmod | grep -q "^ath12k " && cmp -s "$ath_ko" $MODS/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko'
# ---- the two config changes at run time
chk "0148: printk console_suspend is Y (consoles suspend; no suspend-console switch, fbcon leaves the DP config alone)" '[ "$(cat /sys/module/printk/parameters/console_suspend)" = Y ]'
chk "hung tasks: panic 0, timeout 180 s, soft lockup still panics ($(cat /proc/sys/kernel/hung_task_panic)/$(cat /proc/sys/kernel/hung_task_timeout_secs)/$(cat /proc/sys/kernel/softlockup_panic))" '[ "$(cat /proc/sys/kernel/hung_task_panic)" = 0 ] && [ "$(cat /proc/sys/kernel/hung_task_timeout_secs)" = 180 ] && [ "$(cat /proc/sys/kernel/softlockup_panic)" = 1 ]'
echo "INFO  hung-task lines this boot: $(journalctl -k -b --no-pager -o cat | grep -cE "blocked for more than|hung_task") (expected 0; a USB disk gone under I/O would now only print one)"
# ---- 0144: KWin's view of the panel, and the scaling that must not move with it
pm() { "${U[@]}" kscreen-doctor -j 2>/dev/null | python3 -I -c '
import json, sys
o = [x for x in json.load(sys.stdin)["outputs"] if x.get("connected") and "DSI" in x.get("name", "")]
if len(o) != 1: sys.exit(1)
print(o[0]["sizeMM"]["width"], o[0]["sizeMM"]["height"], o[0]["scale"])'; }
pmv=$(pm)
chk "0144: kscreen-doctor sees the DSI panel as 118 x 190 mm at scale 1.9 (got '$pmv')" '[ "$pmv" = "118 190 1.9" ]'
chk "Xwayland scale 1.9 in kwinrc, Xft.dpi 182 in $HOME_P/.Xresources (unchanged)" '[ "$("${U[@]}" kreadconfig6 --file kwinrc --group Xwayland --key Scale)" = 1.9 ] && grep -qxE "Xft\.dpi: *182" $HOME_P/.Xresources'
# ---- 0147/0149-0152: the code paths exist and are idle (a monitor / a card would exercise them: NOTES.md 风险与怎么测)
chk "DP-1 connector registered (0150/0151's driver bound)" 'ls /sys/class/drm/ | grep -q -- "-DP-1$"'
echo "INFO  DP-1 status: $(cat /sys/class/drm/card*-DP-1/status 2>/dev/null | tr '\n' ' ')(disconnected without a monitor)"
echo "INFO  dwc3-qcom 'HS-PHY not in L2' lines this boot: $(journalctl -k -b --no-pager -o cat | grep -c "HS-PHY not in L2") (3 every boot since y7: not y18's)"
chk "mmc0 host present (0152's sd core)" 'ls /sys/class/mmc_host/ | grep -q "^mmc0$"'
echo "INFO  mmc0: $(journalctl -k -b --no-pager -o cat | grep -m1 -E "^mmc0: .*cards" || echo "no card line")"
# ---- the initramfs: y17's init and the static e2fsck, in the cpio that is in the Image
chk "the build's initramfs /init is the repo's linux/kernel-y17/init (sha256 ${Y17_INIT_SHA:0:12}...)" '[ "$(sha256sum < $OUT/initramfs.d/init | cut -c1-64)" = $Y17_INIT_SHA ]'
chk "its list names /bin/e2fsck once" '[ "$(grep -c "^file /bin/e2fsck " $OUT/initramfs.list)" = 1 ]'
chk "the cpio's init and bin/e2fsck are y17's init and $E2S (unpacked)" 'rm -rf /tmp/y18v-cpio && mkdir /tmp/y18v-cpio && (cd /tmp/y18v-cpio && zcat $OUT/initramfs.cpio.gz | busybox cpio -i -d init bin/e2fsck) && [ "$(sha256sum < /tmp/y18v-cpio/init | cut -c1-64)" = $Y17_INIT_SHA ] && cmp -s /tmp/y18v-cpio/bin/e2fsck $E2S'
rm -rf /tmp/y18v-cpio
chk "e2fsck-static unchanged since install (dpkg --verify) and static (no INTERP)" '[ -z "$(dpkg --verify e2fsck-static)" ] && ! readelf -lW $E2S | grep -q INTERP'
chk "that cpio is inside the running Image" 'python3 -I -c "import sys; d = open(sys.argv[1], \"rb\").read(); sys.exit(0 if len(d) > 1024 and d in open(sys.argv[2], \"rb\").read() else 1)" $OUT/initramfs.cpio.gz $OUT/Image-t52-y18'
# ---- this boot's checks of the root (the init's kmsg lines; README "内核 y17")
K=$(journalctl -k -b --no-pager -o short --no-hostname)
ln1() { grep -nE "$1" <<<"$K" | head -n1 | cut -d: -f1; }
sw=$(grep -E " baldur: +switching to root " <<<"$K" | tail -n1)
rdev=$(sed -nE 's/.* switching to root [^ ]+ on (\/dev\/[^ ]+) \(.*/\1/p' <<<"$sw"); rd=${rdev#/dev/}
chk "the init switched to a root ($rdev) and / is that device ($(findmnt -no SOURCE /))" '[ -n "$rdev" ] && [ "$(findmnt -no SOURCE /)" = "$rdev" ]'
fst=$(grep -E " baldur: +fsck [^ ]+ \($rdev\): e2fsck " <<<"$K")
fre=$(grep -E " baldur: +fsck [^ ]+ \($rdev\): exit [0-9]+ \(" <<<"$K")
chk "two e2fsck runs on $rdev this boot: journal-only first, then the full one" '[ "$(grep -c . <<<"$fst")" = 2 ] && sed -n 1p <<<"$fst" | grep -qF -- "e2fsck -p -E journal_only," && sed -n 2p <<<"$fst" | grep -qF "e2fsck -p,"'
chk "both exited 0 or 1: $(sed -E 's/.*\): (exit .*)/\1/' <<<"$fre" | tr '\n' ';')" '[ "$(grep -c . <<<"$fre")" = 2 ] && ! grep -vqE "\): exit [01] \((clean|errors fixed)\), [0-9]+ s$" <<<"$fre"'
j=$(ln1 " baldur: +fsck [^ ]+ \($rdev\): exit "); f=$(grep -nE " baldur: +fsck [^ ]+ \($rdev\): exit " <<<"$K" | tail -n1 | cut -d: -f1)
m=$(ln1 " kernel: EXT4-fs \($rd\): mounted "); t=$(ln1 " baldur: +kernel [^ ]+ on trial: start [0-9]+ of [0-9]+ "); s=$(ln1 " baldur: +switching to root ")
chk "order: journal-only check before $rd's first mount, trial start counted before the full check, full check before the switch (lines $j < $m, $t < $f < $s)" '[ -n "$j" ] && [ -n "$m" ] && [ -n "$t" ] && [ -n "$f" ] && [ -n "$s" ] && [ $j -lt $m ] && [ $t -lt $f ] && [ $f -lt $s ]'
chk "none of the 10-31/11-01 trouble this boot (remount,rw refused, start not counted, not mounting read-only, no e2fsck, orphan list cleared)" '! grep -qE "EXT4-fs \($rd\): (Couldn.t remount RDWR|Errors on filesystem, clearing orphan list)| baldur: .*(start not counted|does not mount read-only|no e2fsck in this image)" <<<"$K"'
chk "no ext4 complaint about $rd after the full check" '[ -n "$f" ] && ! tail -n +$f <<<"$K" | grep -qE "EXT4-fs error \(device $rd\)|EXT4-fs \($rd\): .*(with errors|error count|orphan)"'
echo "INFO  before the full check: $(head -n ${f:-0} <<<"$K" | grep -cE "EXT4-fs \($rd\): warning: mounting fs with errors") 'mounting fs with errors' line(s) (expected 0 now: y17's first boot cleared the mark)"
st=$(tune2fs -l "$rdev" 2>/dev/null)
chk "$rd: Filesystem state clean, no FS Error count (tune2fs -l)" 'grep -qE "^Filesystem state: +clean$" <<<"$st" && ! grep -q "^FS Error count:" <<<"$st"'
echo "INFO  /var/log/baldur-fsck.log: $(grep -c "^== boot " /var/log/baldur-fsck.log 2>/dev/null || echo 0) run(s) logged, $(stat -c %s /var/log/baldur-fsck.log 2>/dev/null || echo 0) bytes"
# ---- y16's checks (y16-verify.sh): 1058 at run time, CONFIG_WATCHDOG_SYSFS, health
dl=$(cat /sys/module/qcom_scm/parameters/download_mode 2>/dev/null)
sdi=$(journalctl -k -b --no-pager -o cat | grep -F "download mode off, SDI disable: ")
chk "download_mode is off ($dl; y700-dumpmode-off, 3 min after boot)" '[ "$dl" = off ]'
chk "1058: the kernel disabled SDI when download mode went off ($(printf '%s\n' "$sdi" | grep -c .) line(s): '$(printf '%s' "$sdi" | head -1)')" '[ -n "$sdi" ] && ! grep -vqE "SDI disable: 0$" <<<"$sdi"'
# the driver's own lines only: the initramfs init writes "<1>baldur: ... qcom_scm download_mode ..." to kmsg every boot
chk "no err-level qcom_scm kernel line this boot" '[ -z "$(journalctl -k -b -p err --no-pager -o cat | grep -E "^qcom_scm[ :]")" ]'
chk "watchdog0 is qcom_wdt ($(cat $WD/identity 2>/dev/null))" '[ "$(cat $WD/identity)" = qcom_wdt ]'
chk "watchdog0 active, timeout 30 s (state $(cat $WD/state 2>/dev/null), timeout $(cat $WD/timeout 2>/dev/null))" '[ "$(cat $WD/state)" = active ] && [ "$(cat $WD/timeout)" = 30 ]'
echo "INFO  watchdog0 bootstatus $(cat $WD/bootstatus 2>/dev/null) (32 = the last reset was a watchdog bite), nowayout $(cat $WD/nowayout 2>/dev/null), timeleft $(cat $WD/timeleft 2>/dev/null || echo n/a)"
chk "memlat devfreq present" '[ -e /sys/class/devfreq/ddr/cur_freq ] && [ -e /sys/class/devfreq/llcc/cur_freq ]'
chk "memlat poll 1 s (udev)" '[ "$(cat /sys/class/devfreq/ddr/polling_interval)" = 1000 ]'
# Wi-Fi
chk "ath12k is the in-tree y700-1041 build" '[ "$(cat /sys/module/ath12k/version 2>/dev/null)" = y700-1041 ]'
chk "wifi connected" 'nmcli -t -f DEVICE,STATE device | grep -q "^wlp1s0:connected"'
chk "wifi power save on" 'iw dev wlp1s0 get power_save | grep -q on'
chk "tailscale running" 'tailscale status --json | grep -q "\"BackendState\": \"Running\""'
# the owner's hardware
chk "display on, panel nt36523 bound" 'grep -q On /sys/class/drm/card*-DSI-1/dpms && ls /sys/bus/mipi-dsi/drivers/panel-novatek-nt36523/*-* >/dev/null 2>&1 || ls /sys/bus/mipi-dsi/drivers/*nt36523*/ | grep -q dsi'
chk "touch + pen input devices (0153 leaves the pen device registered)" 'grep -q NVTCapacitiveTouchScreen /proc/bus/input/devices && grep -q NVTCapacitivePen /proc/bus/input/devices'
chk "haptics (2x aw86927)" '[ "$(grep -c aw86927-haptics /proc/bus/input/devices)" = 2 ]'
chk "uinput" '[ -e /dev/uinput ]'
chk "sound card + aw882xx amps" 'grep -q "TB323FU\|LENOVO" /proc/asound/cards && lsmod | grep -q snd_soc_aw882xx'
chk "speaker gain helper happy" '"${U[@]}" /usr/libexec/tb323fu/tb323fu-speaker-gain status | grep -q "aw_dev_0_volume 21"'
chk "cameras bound (camss + 2 sensors)" 'lsmod | grep -q qcom_camss && lsmod | grep -q s5kjns && lsmod | grep -q gc08a8'
chk "video decoder iris" 'ls /dev/video* >/dev/null && lsmod | grep -q "^iris\|qcom_iris"'
chk "bluetooth powered" '"${U[@]}" bluetoothctl show | grep -q "Powered: yes"'
chk "usb gadget usb0 + ttyGS0" '[ -e /sys/class/net/usb0 ] && [ -e /dev/ttyGS0 ]'
# dual-role port: with no cable the role is "device" and no xHCI root hub exists (same on y7: lsusb empty)
chk "usb controller bound (dwc3-qcom, 0149) + role switch" 'ls /sys/bus/platform/drivers/dwc3-qcom/ | grep -q usb && cat /sys/class/usb_role/*/role | grep -qE "device|host|none"'
chk "type-c ucsi (0147)" 'ls /sys/class/typec/ | grep -q port'
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
