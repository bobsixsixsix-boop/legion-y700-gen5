#!/bin/bash
# y20-verify.sh: after the first boot of y20 (7.3.0-tb323fu-t52-y20 = y19's source with CONFIG_HID_MAGICMOUSE=m: the
# in-tree Magic Mouse 2 driver for the owner's mouse; linux/kernel-y20/NOTES.md, README「Magic 键鼠」). Run as root:
# bash /root/y20-verify.sh
# - in trial start 1, before "tb323fu-ctl kernel keep", at least 4 min after boot (y16's SDI check below:
# y700-dumpmode-off acts at 3 min); the last line must be ALL PASS. SKIP lines are checks that need the Magic Mouse or
# the Magic Keyboard connected (not failures: connect the device and run again, or check by hand as the line says).
# Checks:
#   - build identity: the running kernel IS /usr/local/src/y700-kernel-y20/Image-t52-y20, /proc/config.gz IS its config
#     and equals y19's (and y18's) apart from CONFIG_HID_MAGICMOUSE=m, y17's apart from that, the hung-task panic and the
#     CMDLINE; its patch archive EQUALS y19's byte for byte (no source change); the loaded iris and ath12k modules ARE the
#     build's;
#   - y20's change at run time: /lib/modules/<rel>/kernel/drivers/hid/hid-magicmouse.ko exists, is in-tree and is what
#     modinfo -n / modprobe -n resolve; no out-of-tree copy for this release under /usr/local/lib/y700-extra-modules/;
#     the transition files (linux/owner-devices/) are installed; running /usr/local/sbin/y700-extra-modules hid-magicmouse
#     (what the udev rule does on a mouse "add" event) ends with the module loaded UNTAINTED (no "(O)" in /proc/modules:
#     the kernel's own module, not an insmod of the out-of-tree build) and scroll_acceleration=Y (hid_magicmouse.conf);
#     with the mouse connected its hid device is bound to magicmouse; with the keyboard connected hid_apple fnmode is 2;
#   - y18's seven at run time, as y19-verify.sh checked them (0144 panel size and scale, 0148 console_suspend, DP-1,
#     dwc3-qcom, type-c, mmc0, the pen input device);
#   - zram B, the hung-task sysctls, the initramfs and the root checks, y16's checks (SDI, watchdog0), health: as y19.
# INFO lines: DP-1 status, the HS-PHY L2 warnings, mmc0 cards, hung-task lines (0), y700-dp-source's lines this boot and
# the type-c power role (a USB-C monitor may be on the port: README「USB-C 外接屏」expects "[source] sink" with DP-1 connected).
# The init's kmsg lines carry "baldur:", which journalctl -o cat strips (it is their syslog identifier): read with
# -o short --no-hostname, where they are "... baldur:  fsck ..." and the kernel's "... kernel: EXT4-fs (sda15): ...".
# Side effect: hid_magicmouse gets loaded if it was not (exactly what pairing the mouse does); nothing else is written.
# PASS/FAIL/SKIP per line, exit 1 on any FAIL.
export LC_ALL=C
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
REL=7.3.0-tb323fu-t52-y20; OUT=/usr/local/src/y700-kernel-y20; MODS=/usr/local/src/y700-mods-y20/lib/modules/$REL
Y17OUT=/usr/local/src/y700-kernel-y17; Y18OUT=/usr/local/src/y700-kernel-y18; Y19OUT=/usr/local/src/y700-kernel-y19
Y17_INIT_SHA=b450a91a698592773f22f091c3061992d8df4c02240ca35365d9a7b5e37990ce   # kbuild-y17.sh's and kbuild-y20.sh's pin
E2S=/usr/sbin/e2fsck.static
WD=/sys/class/watchdog/watchdog0
HOME_P=$(getent passwd user | cut -d: -f6)
# the two command lines (kbuild-y20.sh): y17's and y18's = y19's = y20's = the same minus no_console_suspend
Y17_CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
Y20_DELTA="> CONFIG_HID_MAGICMOUSE=m"   # y20's one config change (kbuild-y20.sh)
EXPECTED_DELTA="< CONFIG_BOOTPARAM_HUNG_TASK_PANIC=1
< CONFIG_CMDLINE=\"$Y17_CMDLINE\"
> CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0
> CONFIG_CMDLINE=\"$CMDLINE\"
$Y20_DELTA"
MMKO=/lib/modules/$REL/kernel/drivers/hid/hid-magicmouse.ko
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
skip() { printf 'SKIP  %s\n' "$1"; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
up=$(cut -d. -f1 /proc/uptime)
[ "$up" -ge 240 ] || { echo "uptime ${up}s: run this at least 4 min after boot (y700-dumpmode-off acts at 3 min)"; exit 1; }
chk "running y20: $(uname -r)" '[ "$(uname -r)" = $REL ]'
chk "cmdline: y9's tokens (download_mode=full, allow_cluster_off=0, idle_refresh), NO allow_system_off, NO no_console_suspend (0148)" 'c=$(cat /proc/cmdline); grep -q "qcom_scm.download_mode=full" <<<"$c" && grep -q "cpuidle_psci_domain.allow_cluster_off=0" <<<"$c" && ! grep -q "allow_system_off" <<<"$c" && grep -q "msm.idle_refresh_ms60=500" <<<"$c" && ! grep -q "no_console_suspend" <<<"$c"'
chk "systemctl --failed empty" '[ -z "$(systemctl --failed --no-legend)" ]'
chk "user units: no failed" '[ -z "$("${U[@]}" systemctl --user --failed --no-legend)" ]'
chk "no previous-boot crash (journal -b -1 ended cleanly or absent)" 'journalctl -b -1 -n 50 --no-pager -o cat 2>/dev/null | grep -qE "Journal stopped|reboot.target|Reached target System Reboot" || [ -z "$(journalctl --list-boots -q 2>/dev/null | sed -n 2p)" ]'
# ---- the build itself: what runs is what kbuild-y20.sh built
chk "the running kernel is $OUT/Image-t52-y20 (uname -v '$(uname -v)' is in that image)" 'strings $OUT/Image-t52-y20 | grep -qxF "$(uname -v)"'
chk "/proc/config.gz is the build's config-t52-y20" 'zcat /proc/config.gz | cmp -s - $OUT/config-t52-y20'
cfg_cmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#"; }
chk "the running config has CONFIG_HID_MAGICMOUSE=m" 'zcat /proc/config.gz | grep -qx CONFIG_HID_MAGICMOUSE=m'
chk "the running config equals y19's ($Y19OUT/config-t52-y19) apart from CONFIG_HID_MAGICMOUSE=m" '[ "$(diff <(cfg_cmp < $Y19OUT/config-t52-y19) <(zcat /proc/config.gz | cfg_cmp) | grep "^[<>]" | sort)" = "$Y20_DELTA" ]'
chk "the running config equals y18's ($Y18OUT/config-t52-y18) apart from that line" '[ "$(diff <(cfg_cmp < $Y18OUT/config-t52-y18) <(zcat /proc/config.gz | cfg_cmp) | grep "^[<>]" | sort)" = "$Y20_DELTA" ]'
chk "the running config equals y17's ($Y17OUT/config-t52-y17) apart from that, BOOTPARAM_HUNG_TASK_PANIC and CMDLINE" '[ "$(diff <(cfg_cmp < $Y17OUT/config-t52-y17) <(zcat /proc/config.gz | cfg_cmp) | grep "^[<>]" | sort)" = "$EXPECTED_DELTA" ]'
chk "the build's patch archive equals y19's byte for byte (y20 changed no source): not y18's, carries 0144, no nt36xxx.c" 'cmp -s $OUT/y700-y20.patch $Y19OUT/y700-y19.patch && ! cmp -s $OUT/y700-y20.patch $Y18OUT/y700-y18.patch && grep -qF ".width_mm = 118," $OUT/y700-y20.patch && ! grep -q "nt36xxx.c" $OUT/y700-y20.patch'
chk "the build ended with KFULL_OK (/root/y700-kernel-y20.log)" '[ "$(tail -1 /root/y700-kernel-y20.log)" = KFULL_OK ]'
iris_ko=$(modinfo -n qcom_iris 2>/dev/null); ath_ko=$(modinfo -n ath12k 2>/dev/null)
chk "the loaded iris module is the y20 build's ($iris_ko)" 'lsmod | grep -q "^qcom_iris " && cmp -s "$iris_ko" $MODS/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko'
chk "the loaded ath12k module is the y20 build's ($ath_ko)" 'lsmod | grep -q "^ath12k " && cmp -s "$ath_ko" $MODS/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko'
# ---- y20's change: the Magic Mouse driver is the kernel's own module (README「Magic 键鼠」, linux/owner-devices/)
chk "hid-magicmouse.ko in this kernel's module set ($MMKO), in-tree, and the build's copy" '[ -f $MMKO ] && [ "$(modinfo -F intree $MMKO)" = Y ] && cmp -s $MMKO $MODS/kernel/drivers/hid/hid-magicmouse.ko'
chk "modinfo -n / modprobe -n resolve hid_magicmouse to it (depmod knows it: y700-extra-modules takes its modprobe branch)" '[ "$(modinfo -n hid_magicmouse)" = $MMKO ] && modprobe -q -n hid_magicmouse'
chk "its alias covers the Magic Mouse 2 over Bluetooth (hid:b0005g*v0000004Cp00000269)" 'modinfo -F alias $MMKO | grep -qxF "hid:b0005g*v0000004Cp00000269"'
chk "no out-of-tree hid-magicmouse for $REL (/usr/local/lib/y700-extra-modules/$REL absent; y19's directory may stay until it is trashed)" '[ ! -e /usr/local/lib/y700-extra-modules/$REL ]'
chk "the transition files are installed: 90-y700-magicmouse.rules, y700-extra-modules (x), hid_magicmouse.conf, hid_apple.conf" 'grep -q "y700-extra-modules hid-magicmouse" /etc/udev/rules.d/90-y700-magicmouse.rules && [ -x /usr/local/sbin/y700-extra-modules ] && grep -qx "options hid_magicmouse scroll_acceleration=1" /etc/modprobe.d/hid_magicmouse.conf && grep -qx "options hid_apple fnmode=2" /etc/modprobe.d/hid_apple.conf'
chk "y700-extra-modules hid-magicmouse exits 0 and leaves the module loaded (what the udev rule does on a mouse add event)" '/usr/local/sbin/y700-extra-modules hid-magicmouse && [ -d /sys/module/hid_magicmouse ]'
chk "the loaded hid_magicmouse is the kernel's own: untainted (no (O) in /proc/modules, empty /sys/module/hid_magicmouse/taint)" 'grep -q "^hid_magicmouse " /proc/modules && ! grep "^hid_magicmouse " /proc/modules | grep -q "(O" && [ -z "$(cat /sys/module/hid_magicmouse/taint)" ]'
chk "hid_magicmouse scroll_acceleration=Y (/etc/modprobe.d/hid_magicmouse.conf, read by modprobe)" '[ "$(cat /sys/module/hid_magicmouse/parameters/scroll_acceleration)" = Y ]'
mice=$(ls -d /sys/bus/hid/devices/*:004C:0269.* /sys/bus/hid/devices/*:05AC:0269.* 2>/dev/null)
if [ -n "$mice" ]; then
	for d in $mice; do chk "Magic Mouse 2 $(basename $d) is bound to magicmouse (driver: $(basename "$(readlink $d/driver 2>/dev/null)" 2>/dev/null))" '[ "$(basename "$(readlink $d/driver)")" = magicmouse ]'; done
else
	skip "Magic Mouse 2 not connected: its hid device's driver not checked (connect it, then readlink /sys/bus/hid/devices/*:004C:0269.*/driver must end in /magicmouse; the daily checklist item「Magic 鼠标驱动」checks the same)"
fi
if [ -e /sys/module/hid_apple/parameters/fnmode ]; then
	chk "hid_apple fnmode 2 (Magic Keyboard: F-keys are F-keys; /etc/modprobe.d/hid_apple.conf), got $(cat /sys/module/hid_apple/parameters/fnmode)" '[ "$(cat /sys/module/hid_apple/parameters/fnmode)" = 2 ]'
else
	skip "hid_apple not loaded (Magic Keyboard not connected): fnmode not checked (connect it, then cat /sys/module/hid_apple/parameters/fnmode must say 2)"
fi
# -q: without it an empty match prints "-- No entries --" on stdout, which would count as one line (README「每日体检」, systemd 259)
dps=$(journalctl -q -b -t y700-dp-source --no-pager -o cat)
echo "INFO  y700-dp-source lines this boot: $(printf '%s' "$dps" | grep -c .) (last: $(printf '%s' "$dps" | tail -n1)); type-c port0 power_role: $(cat /sys/class/typec/port0/power_role 2>/dev/null) (with a DP monitor on the port: [source] sink; since 169be84 tb323fu-usb-port runs y700-dp-source as ExecStartPost at boot, so no hand run is needed, README「USB-C 外接屏」)"
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
echo "INFO  dwc3-qcom 'HS-PHY not in L2' lines this boot: $(journalctl -k -b --no-pager -o cat | grep -c "HS-PHY not in L2") (3 every boot since y7: not y20's)"
chk "mmc0 host present (0152's sd core)" 'ls /sys/class/mmc_host/ | grep -q "^mmc0$"'
echo "INFO  mmc0: $(journalctl -k -b --no-pager -o cat | grep -m1 -E "^mmc0: .*cards" || echo "no card line")"
# ---- the initramfs: y17's init and the static e2fsck, in the cpio that is in the Image
chk "the build's initramfs /init is the repo's linux/kernel-y17/init (sha256 ${Y17_INIT_SHA:0:12}...)" '[ "$(sha256sum < $OUT/initramfs.d/init | cut -c1-64)" = $Y17_INIT_SHA ]'
chk "its list names /bin/e2fsck once" '[ "$(grep -c "^file /bin/e2fsck " $OUT/initramfs.list)" = 1 ]'
chk "the cpio's init and bin/e2fsck are y17's init and $E2S (unpacked)" 'rm -rf /tmp/y20v-cpio && mkdir /tmp/y20v-cpio && (cd /tmp/y20v-cpio && zcat $OUT/initramfs.cpio.gz | busybox cpio -i -d init bin/e2fsck) && [ "$(sha256sum < /tmp/y20v-cpio/init | cut -c1-64)" = $Y17_INIT_SHA ] && cmp -s /tmp/y20v-cpio/bin/e2fsck $E2S'
rm -rf /tmp/y20v-cpio
chk "e2fsck-static unchanged since install (dpkg --verify) and static (no INTERP)" '[ -z "$(dpkg --verify e2fsck-static)" ] && ! readelf -lW $E2S | grep -q INTERP'
chk "that cpio is inside the running Image" 'python3 -I -c "import sys; d = open(sys.argv[1], \"rb\").read(); sys.exit(0 if len(d) > 1024 and d in open(sys.argv[2], \"rb\").read() else 1)" $OUT/initramfs.cpio.gz $OUT/Image-t52-y20'
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
chk "touch + pen input devices (t52's pen code: 0153 dropped since y19)" 'grep -q NVTCapacitiveTouchScreen /proc/bus/input/devices && grep -q NVTCapacitivePen /proc/bus/input/devices'
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
# ---- zram B (11-04, the owner's choice; README「内核 y19」, linux/zram/): the generator read the new conf at boot
mt=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 )); ds=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
chk "zram0 disksize $ds = MemTotal $mt within 2 MiB (zram-size = ram: MemTotal in MiB)" '[ $(( ds > mt ? ds - mt : mt - ds )) -lt 2097152 ]'
chk "zram0 is the only swap, priority 100 (/proc/swaps)" '[ "$(tail -n +2 /proc/swaps | grep -c .)" = 1 ] && awk "\$1 == \"/dev/zram0\" {found = 1; if (\$5 != 100) bad = 1} END {exit (!found || bad)}" /proc/swaps'
chk "/etc/systemd/zram-generator.conf is the repo's linux/zram file: zram-size = ram, zstd, priority 100" 'grep -qx "zram-size = ram" /etc/systemd/zram-generator.conf && grep -qx "compression-algorithm = zstd" /etc/systemd/zram-generator.conf && grep -qx "swap-priority = 100" /etc/systemd/zram-generator.conf'   # (no "! grep ram / 2": the conf's own comment says "was ram / 2"; -x on the directive is the check)
chk "vm.swappiness 100, vm.page-cluster 0 (got $(cat /proc/sys/vm/swappiness)/$(cat /proc/sys/vm/page-cluster)), set by /etc/sysctl.d/90-y700-zram.conf" '[ "$(cat /proc/sys/vm/swappiness)" = 100 ] && [ "$(cat /proc/sys/vm/page-cluster)" = 0 ] && grep -qx "vm.swappiness = 100" /etc/sysctl.d/90-y700-zram.conf && grep -qx "vm.page-cluster = 0" /etc/sysctl.d/90-y700-zram.conf'
chk "systemd-zram-setup@zram0 active" 'systemctl is-active -q systemd-zram-setup@zram0.service'
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
