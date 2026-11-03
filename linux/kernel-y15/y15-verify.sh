#!/bin/bash
# y15-verify.sh: after the first boot of y15 (7.3.0-tb323fu-t52-y15 = y14 without 1049, plus 1052-1057, on the same
# kernel-t52 base; linux/kernel-y15/NOTES.md). Run as root: bash /root/y15-verify.sh  - before "tb323fu-ctl kernel keep";
# the last line must be ALL PASS.
# = y14-verify.sh with every check kept, the 1049 checks turned into 1052 checks, plus the y15 sections:
#   - build identity: the running kernel IS /usr/local/src/y700-kernel-y15/Image-t52-y15, /proc/config.gz IS its config
#     and equals y14's apart from the two lines that name the build, the loaded iris and ath12k modules and uhid.ko ARE
#     the build's, and the build's patch archive carries 1052-1057 (and 1051, 0620-0622) and no longer 1049;
#   - 1052 (iris requeues a clean NOSHOW decoder buffer itself): /root/vp9-hidden-check.sh (linux/video, the 10-28
#     contract) run with IRIS_NOSHOW_MODE / LIBVA_EXPECT_ERRTS unset must pick mode=recycle for this kernel by itself
#     (first line "vp9-hidden-check: mode=recycle kernel=7.3.0-tb323fu-t52-y15") and end "vp9-hidden-check: PASS" -
#     against the INSTALLED VA driver, which is still 2de1857 (6d03c3f + local 0001) when y15 is first booted: v1.1.x
#     is installed only after y15 is kept (NOTES.md, the coupling); its "clean" case is the runtime evidence (no empty
#     CAPTURE buffer at all in recycle mode). vaapi-check.sh and the libva-v4l2 error-recovery test run as on y14;
#   - 1053 (smp2p): CHECK no "Handover signaled, but it already happened" since boot (v7.3's q6v5 masks the handover
#     interrupt, so y14 had none either: a guard, not the proof); INFO the "q6v5 ready" (adsp) and smp2p-adsp interrupt
#     counts since boot and over 10 s (10-21 diagnostic on 7.3-rc4, same check_ssr(): 273 and 273 in 60 s, every ADSP
#     notification replayed as a rising edge; y15: ready should stay put while smp2p-adsp keeps counting), remoteproc
#     states, and no remoteproc crashed (SoCCP, the other smp2p v2 user, carries pmic_glink / USB-C);
#   - 1054 (uhid): INFO only (CONFIG_UHID, module, /dev/uhid); the race has no reproducer here;
#   - 1055 (ath12k frequency ranges), the checks linux/wifi/5GHZ-ARMADA-594-EVAL.md asks for: CHECK regulatory domain
#     JP on the Wi-Fi phy and HOME_6G connected (nmcli under LC_ALL=C: root's zh_CN locale translates "yes"); INFO networks seen per band, and ping -c 300 -i 0.2 192.168.0.1 (60 s; the EVAL wants
#     0 % loss - compare with y14 before calling a loss a regression; Y15_NO_PING=1 skips it, it also skips off HOME_6G);
#   - 1056 (DT): CHECK exactly one t-power-on-us in the live device tree (/sys/firmware/devicetree/base = the built-in
#     DTB), on the root port whose wifi@0 child is pci17cb,110e, value 80; lspci shows that root port's
#     PortTPowerOnTime=80us (y14 10-23: 0us); INFO the L1.2 threshold / T_PwrOn of both ends, AER lines since boot;
#   - 1057 (AV1 10-bit LINE buffer): /root/av1-10bit-probe.sh against the uninstalled v1.1.1 build, when both exist:
#     CHECK it ran to the end on this kernel and the two 8-bit controls match dav1d; INFO the 10-bit rows (y14: 1/5).
# PASS/FAIL per line, exit 1 on any FAIL. Y10_NO_TOGGLE=1 skips the runtime toggle test of the knob, Y15_NO_RECOVERY=1
# the error-recovery test, Y15_NO_PING=1 the 60 s ping.
# vaapi-check.sh (10-23 version) exits non-zero when a stream fails; its exit status is the check, and a missing
# /root/vaapi-check.sh is a FAIL here. It compares every frame with libavcodec's software decode and decodes two VP9
# show_existing_frame clips. A rare "Failed to destroy decode context 0x6: 38" flake
# (VA_STATUS_ERROR_TIMEDOUT at context destroy, frames still 90/90) was seen on libva-v4l2 ef18ba0 on 10-23 (on the
# first run, then once more in ~90 reruns; none in ~40 decodes on 6d03c3f): if that check is the only FAIL and its
# error line is that one, re-run /root/vaapi-check.sh once before blaming the kernel.
# The toggle test writes 1 then 0 to allow_system_off. With allow_cluster_off=N (the cmdline default) the cluster domains
# never power off, so the system domain is never reached: the toggle changes one flag bit and prints two dmesg lines,
# nothing else (RESEARCH.md 3.3). It refuses to run while allow_cluster_off is Y.
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
REL=7.3.0-tb323fu-t52-y15; OUT=/usr/local/src/y700-kernel-y15; MODS=/usr/local/src/y700-mods-y15/lib/modules/$REL
# iris err-level kernel lines, minus the ones the 1057 probe's sessions logged (saved to $PROBE_ERR right after the
# probe): a 10-bit START failure there is graded by the 1057 INFO, not by the 1052/1051 checks (review, 10-29)
PROBE_ERR=/tmp/y15-verify-probe-iris-err.txt; : > $PROBE_ERR
iris_errs() { dmesg -k -l emerg,alert,crit,err | grep -E "qcom-iris|iris_" | grep -vxFf $PROBE_ERR; }
Y14OUT=/usr/local/src/y700-kernel-y14
ASO=/sys/module/cpuidle_psci_domain/parameters/allow_system_off
ACO=/sys/module/cpuidle_psci_domain/parameters/allow_cluster_off
SYS=/sys/kernel/debug/pm_genpd/power-domain-system/idle_states
BOOT_LINE='CPUidle PSCI: power-domain-system: allow_system_off=N, system domain state in system suspend only (lenovo,baldur quirk, boot)'
Y_LINE='power-domain-system: allow_system_off=Y, system domain state in runtime idle too (parameter written)'
N_LINE='power-domain-system: allow_system_off=N, system domain state in system suspend only (parameter written)'
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
pd_ur() { awk 'NR==2{print $3"/"$4}' $SYS 2>/dev/null; }   # idle_states line 2 = S0: State Time Usage Rejected Above Below Usage_s2idle
chk "running y15: $(uname -r)" '[ "$(uname -r)" = $REL ]'
chk "cmdline: y9's unchanged (allow_cluster_off=0 pinned, NO allow_system_off token, idle_refresh present, no qos_disable)" 'c=$(cat /proc/cmdline); grep -q "cpuidle_psci_domain.allow_cluster_off=0" <<<"$c" && ! grep -q "allow_system_off" <<<"$c" && grep -q "msm.idle_refresh_ms60=500" <<<"$c" && ! grep -q qos_disable <<<"$c"'
chk "panel idle refresh 500/2000" '[ "$(cat /sys/module/msm/parameters/idle_refresh_ms60)" = 500 ] && [ "$(cat /sys/module/msm/parameters/idle_refresh_ms30)" = 2000 ]'
chk "systemctl --failed empty" '[ -z "$(systemctl --failed --no-legend)" ]'
chk "user units: no failed" '[ -z "$("${U[@]}" systemctl --user --failed --no-legend)" ]'
chk "no previous-boot crash (journal -b -1 ended cleanly or absent)" 'journalctl -b -1 -n 50 --no-pager -o cat 2>/dev/null | grep -qE "Journal stopped|reboot.target|Reached target System Reboot" || [ -z "$(journalctl --list-boots -q 2>/dev/null | sed -n 2p)" ]'
# ---- upstream t51: 0132 battmgr charge-current limit sysfs (helper 0.4.2's 9 V bypass uses it). 0131 (dpu modeset
# only when a DSPP is missing) has no cheap runtime probe: watch that night light no longer blanks the panel.
# (y14: both are in the t52 base now, no longer carried by us)
B=/sys/class/power_supply/qcom-battmgr-bat
chk "0132: constant_charge_current writable + constant_charge_current_max > 0 (max $(cat $B/constant_charge_current_max 2>/dev/null) uA)" '[ -w $B/constant_charge_current ] && [ "$(cat $B/constant_charge_current_max)" -gt 0 ]'
# ---- 1043: the allow_system_off knob
chk "PSCI domain topology in OSI mode" 'dmesg | grep -q "CPUidle PSCI: Initialized CPU PM domain topology using OSI mode"'
chk "1043 boot line in dmesg (quirk applied, knob N)" 'dmesg | grep -qF "$BOOT_LINE"'
chk "1043 knob exists, mode 644" '[ -f $ASO ] && [ "$(stat -c %a $ASO)" = 644 ]'
chk "cluster domains refused as before (0118): Rejected > 0 on power-domain-cluster" '[ "$(awk "NR==2{print \$4}" /sys/kernel/debug/pm_genpd/power-domain-cluster/idle_states)" -gt 0 ]'
# y700-cx-auto (linux/power/cx-auto, daily since 10-17) opens both knobs (level E3a) once the screen has been off for
# 30 s on battery and closes them again: after it armed in this boot, the boot-default checks below cannot hold (knobs
# Y, system domain and apss counts > 0) and the toggle test must not run. Then check only that the knobs match its state.
# (10-23: the 02:36 run on y14, before cx-auto armed at 03:04, passed every boot-default check; the 03:59 run failed all
# six of them, cx-auto armed - the reason for this branch.)
cxa=$(journalctl -b -u y700-cx-auto --no-pager -o cat 2>/dev/null | grep -c '^armed ')
if [ "$cxa" -gt 0 ]; then
	echo "SKIP  1043/0118 boot-default checks and toggle test: y700-cx-auto armed $cxa time(s) this boot (journalctl -b -u y700-cx-auto); re-run right after a boot for them"
	if [ -e /var/lib/y700/cx-auto.armed ]; then
		chk "cx-auto armed now: both knobs open (allow_cluster_off $(cat $ACO), allow_system_off $(cat $ASO))" '[ "$(cat $ACO)" = Y ] && [ "$(cat $ASO)" = Y ]'
	else
		chk "cx-auto not armed now: both knobs closed (allow_cluster_off $(cat $ACO), allow_system_off $(cat $ASO))" '[ "$(cat $ACO)" = N ] && [ "$(cat $ASO)" = N ]'
	fi
else
chk "1043 knob default N" '[ "$(cat $ASO)" = N ]'
chk "0118 knob N (cmdline)" '[ "$(cat $ACO)" = N ]'
chk "system domain never attempted since boot: S0 Usage/Rejected = 0/0 (got $(pd_ur))" '[ "$(pd_ur)" = 0/0 ]'
chk "qcom_stats apss still 0 (nothing changed by default)" 'grep -q "Count: *0$" /sys/kernel/debug/qcom_stats/apss'
if [ "${Y10_NO_TOGGLE:-0}" = 1 ]; then
	echo "SKIP  1043 toggle test (Y10_NO_TOGGLE=1)"
elif [ "$(cat $ACO 2>/dev/null)" != N ]; then
	ko "1043 toggle test refused: allow_cluster_off is '$(cat $ACO 2>/dev/null)', not N (a toggle would then really open the system state)"
else
	before=$(pd_ur)
	y0=$(dmesg | grep -cF "$Y_LINE"); n0=$(dmesg | grep -cF "$N_LINE")
	echo 1 > $ASO; v1=$(cat $ASO); y1=$(dmesg | grep -cF "$Y_LINE")
	echo 0 > $ASO; v0=$(cat $ASO); n1=$(dmesg | grep -cF "$N_LINE")
	chk "1043 toggle: write 1 -> reads Y, one new 'runtime idle too (parameter written)' line" '[ "$v1" = Y ] && [ "$y1" = $((y0 + 1)) ]'
	chk "1043 toggle: write 0 -> reads N, one new 'system suspend only (parameter written)' line" '[ "$v0" = N ] && [ "$n1" = $((n0 + 1)) ]'
	chk "1043 toggle: system domain untouched (Usage/Rejected $before -> $(pd_ur))" '[ "$(pd_ur)" = "$before" ]'
	chk "1043 toggle: no WARNING/BUG/Oops in the last 100 kernel lines" '! dmesg | tail -100 | grep -qE "WARNING:|BUG:|Oops|Call trace"'
fi
chk "1043 knob not left open" '[ "$(cat $ASO)" = N ]'
fi
# ---- config intentions (unchanged from y9)
chk "RCU callbacks offloaded (nocb all)" 'dmesg | grep -q "Offload RCU callbacks from CPUs: 0-7"'
chk "uclamp sysctl exists" '[ -e /proc/sys/kernel/sched_util_clamp_min_rt_default ]'
chk "teo governor available" 'grep -q teo /sys/devices/system/cpu/cpuidle/available_governors'
chk "SCHED_CACHE gone" '[ ! -e /sys/kernel/debug/sched/llc_balancing ]'
chk "KSM gone" '[ ! -e /sys/kernel/mm/ksm ]'
chk "binder gone" '! grep -q binder /proc/filesystems'
chk "coresight/stm not loaded" '! lsmod | grep -qE "^(coresight|stm_)"'
chk "no fake ttyS" '! ls /dev/ttyS0 2>/dev/null && ! dmesg | grep -q "8250/16550 driver"'
chk "hung task timeout 180" '[ "$(cat /proc/sys/kernel/hung_task_timeout_secs)" = 180 ]'
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
# (no "exit 1" inside chk's eval: it ran in this shell and killed the script after 56 PASS lines on the first y10 run)
chk "control centre + autobright user services" 'all=1; for u in y700-control-center y700-autobright; do "${U[@]}" systemctl --user is-active $u >/dev/null || all=0; done; [ $all = 1 ]'
# the HUD overlay unit stays DISABLED by design (README "y700-hud-overlay": the owner objected to it autostarting;
# the control-centre tile start/stops it), so only its presence is checked, not its state
chk "hud overlay user unit installed (disabled by design)" '"${U[@]}" systemctl --user list-unit-files y700-hud-overlay.service --no-legend | grep -q y700-hud-overlay'
chk "kwin keyboard gate effect loaded" '"${U[@]}" busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects isEffectLoaded s y700_oskgate | grep -q true'
chk "ssh + sudo path fine (AUDIT=n)" 'sudo -n -u user true'
# ---- y12: 1046-1048 (A8xx GMU vote tables). Strings = drm/msm v7.3-rc4 (adreno/a6xx_gmu.c, a6xx_hfi.c, a6xx_gpu.c,
# a8xx_gpu.c, adreno_gpu.c, msm_gpu.c; clk/qcom/gdsc.c). msm is built in: errors read "<drv> <dev>: [drm:<func>] *ERROR* ..."
# (no "[msm]"); GMU = "platform 3d6c000.gmu", GPU = "adreno 3d00000.gpu", DRM = "msm_dpu 9801000.display-controller".
# dmesg -k = kernel records only (baldur's echo of early warnings and other /dev/kmsg writers are user facility).
# y10 baseline: only "delay in fenced register write" (82 in the first ~5 h of the 10-16 12:52 boot).
# (y14: these files are unchanged between v7.3-rc4 and v7.3, NOTES.md)
D=/sys/class/devfreq/3d00000.gpu
gpu_err() { dmesg -k -l emerg,alert,crit,err | grep -v "baldur: " | grep -E "3d6c000\.gmu|3d00000\.gpu|\[drm:(a6xx|a8xx|adreno)_" | grep -vE "delay in fenced register write|Adding to iommu group|supply vdd(cx)? not found|bound 3d00000\.gpu|loaded qcom/[a-z0-9_]+\.(fw|bin|mbn) from"; }
chk "GMU firmware loaded ($(dmesg -k | grep -o 'GMU firmware v[0-9.]*' | head -1); y10: v5.3.33) and GPU bound" 'dmesg -k | grep -q "\[drm\] Loaded GMU firmware v" && dmesg -k | grep -q "bound 3d00000.gpu (ops a3xx_ops)"'
chk "boot GPU self-test passed (baldur's submit ran with the y12 GMU tables)" 'dmesg | grep -q "GPU EXECUTED OUR COMMANDS"'
chk "no RPMh arc lookup failure ('[Mx ]Level N not found in the RPMh list'; Mx = a GPU level above the top MX corner, which only series patch 6 (not taken) clamps)" '! dmesg -k | grep -qE "Level [0-9]+ not found in the RPMh list"'
chk "no GMU/HFI failure (fw init, HFI start/ack/error, OOB, RSC, slumber, watchdog, fenced write fail)" '! dmesg -k | grep -qE "GMU firmware initialization timed out|Unable to start the HFI queues|Timeout waiting for GMU OOB set|Message [A-Z0-9_]+ id [0-9]+ (timed out waiting for response|returned error)|HFI response queue is unexpectedly empty|GMU firmware (error|fault)|Unable to send message [A-Z0-9_]+ id|Unable to power (on|off) the GPU RSC|GPU RSC sequence stuck|The GMU did not go into slumber|Unable to slumber GMU|GMU watchdog expired|GMU AHB bus error|GMU fence error|fenced register write \(0x[0-9a-f]+\) fail|irq fence poll timeout"'
chk "no GPU hang/fault/recovery or GX power-up failure since boot" '! dmesg -k | grep -qE "hangcheck (detected gpu lockup|recover)|\*\*\* (gpu )?fault: |gpu fault ring|CP Fault|timeout waiting (for GPU to idle|to drain ringbuffer)|gpu hw init failed|(CP|RBBM|UCHE) \| |SW fuse violation|cx gdsc didn.t collapse|(gpu_cc_cx|gx_clkctl_gx)_gdsc status stuck"'
chk "no other err-level kernel line from the GPU/GMU (catch-all; listed below)" '[ -z "$(gpu_err)" ]'
gpu_err | head -20 | sed "s/^/      /"
chk "GPU devfreq: simple_ondemand, 160 and 1200 MHz OPPs listed (max_freq now $(( $(cat $D/max_freq 2>/dev/null || echo 0) / 1000000 )) MHz)" '[ "$(cat $D/governor)" = simple_ondemand ] && grep -qw 160000000 $D/available_frequencies && grep -qw 1200000000 $D/available_frequencies'
echo "INFO  GPU OPPs with residency since boot (MHz): $(awk -F: '/^[ *]*[0-9]+:/ {sub(/^[ *]+/, "", $1); n = split($2, t, " "); if (t[n] > 0) printf "%d ", $1 / 1000000}' $D/trans_stat 2>/dev/null)(826-1050 are rarely visited in normal use: their new votes are the least exercised)"
# the rate from the unrounded seconds (10-29: dividing by the rounded hours printed 0.0/h, then 10.0/h, in the first 6 min)
up_s=$(awk '{print int($1)}' /proc/uptime); up_h=$(awk -v s=$up_s 'BEGIN {printf "%.1f", s / 3600}'); fenced=$(dmesg -k | grep -c "delay in fenced register write")
echo "INFO  GMU 'delay in fenced register write': $fenced in $up_h h = $(awk -v n=$fenced -v s=$up_s 'BEGIN {printf "%.1f", (s > 0 ? n * 3600 / s : 0)}')/h (y10 baseline: 82 in ~5 h = ~16/h; dev_err_ratelimited, so a lower bound)"
# my first dedicated check, kept next to the reviewer's (10-16): the vote-table builders' other complaints
chk "no RPMh vote-table build errors (Available levels / BCM aux size / truncated)" '! dmesg | grep -qE "not found in the RPMh list|Available levels:|invalid BCM .* aux data size|is being truncated"'
# ---- 1052 (iris: a clean NOSHOW capture buffer - a hidden VP9 / AV1 reference picture - is requeued inside the driver
# instead of reaching userspace as an empty error buffer; replaces y13/y14's 1049, whose empty-PSC_LAST case its new
# condition covers) and 1050 (dpu: GAMMA_LUT blob must be DPU_GAMMA_LUT_SIZE entries). vaapi-check.sh decodes each of
# its streams to the end (the EOS / drain LAST buffer), frame-exact, the VP9 -sef clips showing every hidden frame
# (an AV1 clip with hidden references too once the driver lists AV1); vp9-hidden-check.sh is the probe for the
# recycling itself. No script here seeks or changes resolution mid-stream: those 1052 paths are NOTES.md's manual
# tests. 1050 only rejects malformed blobs, so the check is that KWin's normal commits (night light writes a
# full-size LUT) still go through: no atomic-commit failures in this boot's KWin log.
chk "1052: iris has no err-level kernel lines since boot" '[ -z "$(iris_errs)" ]'
echo "INFO  VA driver installed: $(cat /root/libva-v4l2.installed 2>/dev/null || echo 'no marker /root/libva-v4l2.installed') (y15 is verified with 2de1857 = 6d03c3f + 0001; v1.1.x only after keep, NOTES.md)"
if [ -f /root/vaapi-check.sh ]; then
	# its own output (one line per stream + PASS/FAIL) goes to the screen; the exit status decides
	vc_out=$(bash /root/vaapi-check.sh 2>&1); vc_rc=$?
	echo "$vc_out" | sed "s/^/      /"
	grep -q '^AV1: ' <<<"$vc_out" || echo "INFO  /root/vaapi-check.sh predates 10-28 (no 'AV1:' line, so no AV1 hidden-reference clip even with an AV1 driver): scp the current linux/kernel-y7/vaapi-check.sh there and compare sha256"
	chk "1052/1051: vaapi-check.sh: its streams (7; 8 with an AV1 driver) decode in hardware, frame-exact against software decode, no iris-vaapi line (exit status $vc_rc)" '[ "$vc_rc" = 0 ]'
	[ "$vc_rc" = 0 ] || echo "      (a lone 'Failed to destroy decode context ...: 38' is a known rare libva-v4l2 flake: re-run bash /root/vaapi-check.sh once before blaming the kernel)"
	[ "$vc_rc" = 0 ] || ! grep -q 'replaced damaged picture' <<<"$vc_out" || echo "      (gray substitutions on the VP9 clips' hidden-frame tokens: on y15 the kernel should not hand a clean NOSHOW buffer out at all - see vp9-hidden-check below; installed driver: $(cat /root/libva-v4l2.installed 2>/dev/null || echo 'no marker'))"
else
	ko "1052: /root/vaapi-check.sh missing (copy linux/kernel-y7/vaapi-check.sh there)"
fi
# 1052 at run time: hidden VP9 frames through the installed VA driver with injected faults (linux/video/vp9-hidden-check.sh,
# ~15 s). Its mode comes from uname -r here (-y15 -> recycle): both override variables are removed from its environment.
if [ -f /root/vp9-hidden-check.sh ]; then
	vh_out=$(env -u IRIS_NOSHOW_MODE -u LIBVA_EXPECT_ERRTS bash /root/vp9-hidden-check.sh 2>&1); vh_rc=$?
	echo "$vh_out" | sed "s/^/      /"
	vh_first=$(head -1 <<<"$vh_out"); vh_last=$(tail -1 <<<"$vh_out")
	chk "1052: vp9-hidden-check.sh chose mode=recycle for this kernel by itself (first line: $vh_first)" '[ "$vh_first" = "vp9-hidden-check: mode=recycle kernel=$REL" ]'
	chk "1052: vp9-hidden-check.sh PASS in recycle mode on the installed driver: no empty CAPTURE buffer for a clean hidden frame, gray only when really damaged, never a sync timeout (exit status $vh_rc)" '[ "$vh_rc" = 0 ] && [ "$vh_last" = "vp9-hidden-check: PASS" ]'
	case "$vh_first" in "vp9-hidden-check: mode="*) ;; *) echo "      (no 'vp9-hidden-check: mode=...' first line: /root/vp9-hidden-check.sh predates the 10-28 contract - copy the current linux/video/vp9-hidden-check.sh there)" ;; esac
	# recycle mode has never run on any kernel before y15, and 2de1857's PASS there is reasoning only (NOTES.md): say
	# how to tell 1052 from the installed driver's local 0001 before anyone rolls the kernel back for this line
	[ "$vh_rc" = 0 ] || echo "      (first real run of recycle mode: see WHICH case failed above before blaming 1052. clean / clean-export with empty CAPTURE or no-show matched > 0 = the kernel handed NOSHOW buffers out (1052). Only error-hidden(-export) failing = suspect the installed driver's local 0001 (it takes the injected empty ERROR picture for a no-show buffer): rerun against the uninstalled v1.1.1 build, bash /root/vp9-hidden-check.sh /root/qva-av1test/build - it passing there clears 1052. NOTES.md, run order step 8)"
else
	ko "1052: /root/vp9-hidden-check.sh missing (copy linux/video/vp9-hidden-check.sh there)"
fi
# 1057 at run time (AV1 10-bit LINE buffer): /root/av1-10bit-probe.sh (linux/kernel-y15/av1-10bit-probe.sh, ~1 min)
# against the UNINSTALLED v1.1.1 test build in /root/qva-av1test/build (the installed 2de1857 driver lists no AV1).
# CHECK the two 8-bit controls (START ok, identical to dav1d: 1057 must not touch 8-bit); INFO the five 10-bit rows -
# y14 on 10-29 started only c1080p10-sb64; 5/5 is 1057 working, a START failure left is no regression against y14.
if [ -f /root/av1-10bit-probe.sh ] && [ -d /root/qva-av1test/build ]; then
	AP=/tmp/av1probe/summary.txt; rm -f $AP   # no rows left from an earlier run to grade
	iris_pre=$(dmesg -k -l emerg,alert,crit,err | grep -cE "qcom-iris|iris_")
	bash /root/av1-10bit-probe.sh >/dev/null 2>&1; ap_rc=$?
	dmesg -k -l emerg,alert,crit,err | grep -E "qcom-iris|iris_" | tail -n +$((iris_pre + 1)) > $PROBE_ERR
	grep -E '^c[0-9]' $AP | sed "s/^/      /"
	chk "1057: av1-10bit-probe.sh ran to the end on this kernel (exit status $ap_rc; summary says kernel: $REL)" '[ "$ap_rc" = 0 ] && grep -qx "kernel: $REL" $AP'
	chk "1057: AV1 8-bit controls start and match dav1d (c720p8-sb64, c1080p8-sb128)" '[ "$(grep -cE "^c(720p8-sb64|1080p8-sb128) .*exit=0 .*dav1d=identical" $AP)" = 2 ]'
	echo "INFO  1057: AV1 10-bit rows that start and match dav1d: $(grep -cE '^c[0-9]+p10-sb[0-9]+ .*exit=0 .*dav1d=identical' $AP)/5 (y14: 1/5; 5/5 = the LINE-buffer fix works)"
	echo "INFO  1057: iris err-level kernel lines during the probe: $(wc -l < $PROBE_ERR) (y14: a 'session error' series per failed 10-bit START; the 1052/1051 iris checks leave these out)"
else
	echo "INFO  1057: /root/av1-10bit-probe.sh or /root/qva-av1test/build missing: AV1 10-bit not probed"
fi
chk "1052: still no iris err-level kernel lines after the decodes (the probe's own left out)" '[ -z "$(iris_errs)" ]'
# 1050 can only make an atomic check fail with EINVAL (a GAMMA_LUT blob of the wrong length), so that is the CHECK.
# Other failures come and go with use and are INFO: "设备或资源忙" (EBUSY, a commit while a flip is pending) and
# "权限不够" were in y13 / y14 boots too (3 / 2 per boot), and y15's first came during normal use (10-29).
# KWin logs strerror in its own zh_CN locale, hence 无效的参数.
kw_log=$("${U[@]}" journalctl --user -b -u plasma-kwin_wayland --no-pager -o cat 2>/dev/null | grep -iE "atomic (test|commit).*fail|failed to commit|drmModeAtomicCommit.*(Invalid argument|EINVAL)")
kw_fail=$(grep -c . <<<"$kw_log"); kw_inval=$(grep -ciE "Invalid argument|EINVAL|无效的参数" <<<"$kw_log")
chk "1050: KWin had no atomic test/commit rejected as invalid this boot (EINVAL; got $kw_inval)" '[ "$kw_inval" = 0 ]'
echo "INFO  1050: KWin atomic test/commit failures this boot: $kw_fail$([ "$kw_fail" = 0 ] || echo " ($(sed 's/.*failed: //' <<<"$kw_log" | sort | uniq -c | awk '{n = $1; $1 = ""; printf "%s%s x%d", s, substr($0, 2), n; s = "; "}'))") (EBUSY / 权限不够 come and go with use; y13 / y14 boots: 3 / 2)"
echo "INFO  vblank timeouts this boot: $(dmesg -k | grep -c 'vblank wait timed out\|vblank timeout') (0204 is held back for this; y12 boots: 0 / 314 / 502 / 10)"
# ==== y15 ====
# ---- the build itself: what runs is what kbuild-y15.sh built from the pinned tree (Y15_TREE: t52-base + 27 commits)
chk "the running kernel is $OUT/Image-t52-y15 (uname -v '$(uname -v)' is in that image)" 'strings $OUT/Image-t52-y15 | grep -qxF "$(uname -v)"'
chk "/proc/config.gz is the build's config-t52-y15" 'zcat /proc/config.gz | cmp -s - $OUT/config-t52-y15'
cfg_cmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#"; }
chk "the running config equals y14's ($Y14OUT/config-t52-y14) apart from LOCALVERSION / INITRAMFS_SOURCE" 'diff <(zcat /proc/config.gz | cfg_cmp) <(cfg_cmp < $Y14OUT/config-t52-y14)'
chk "the build ended with KFULL_OK (/root/y700-kernel-y15.log)" '[ "$(tail -1 /root/y700-kernel-y15.log)" = KFULL_OK ]'
iris_ko=$(modinfo -n qcom_iris 2>/dev/null)
chk "the loaded iris module is the y15 build's ($iris_ko)" 'lsmod | grep -q "^qcom_iris " && cmp -s "$iris_ko" $MODS/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko'
# the other two module patches (review, 10-29: only Image and qcom-iris.ko were tied to the build)
ath_ko=$(modinfo -n ath12k 2>/dev/null); uhid_ko=$(modinfo -n uhid 2>/dev/null)
chk "1055: the loaded ath12k module is the y15 build's ($ath_ko)" 'lsmod | grep -q "^ath12k " && cmp -s "$ath_ko" $MODS/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko'
chk "1054: the uhid module on disk is the y15 build's ($uhid_ko)" 'cmp -s "$uhid_ko" $MODS/kernel/drivers/hid/uhid.ko'
# the build's patch archive (git diff t52-base y15) carries the GMU/HFI patches, 1051 and 1052-1057, and not 1049; the
# lines above tie it to what runs. 0621 has no runtime trace (it only acts when a GMU timeout meets a fault devcoredump).
P=$OUT/y700-y15.patch
chk "0620/0621/0622 in the build: HFI irq clears only CM3_FAULT, GMU waits bounded to 2 s (x2), HFI mask before GMU boot" 'grep -qE "^\+[[:space:]]+A6XX_GMU_GMU2HOST_INTR_INFO_CM3_FAULT;" $P && [ "$(grep -cE "^\+[[:space:]]+msecs_to_jiffies\(2000\)\)\)" $P)" = 2 ] && grep -qE "^\+[[:space:]]+gmu_write\(gmu, REG_A6XX_GMU_GMU2HOST_INTR_MASK, ~0\);" $P'
chk "1051 in the build: the error branch passes buf->timestamp on instead of 0" 'grep -qE "^-[[:space:]]+vb2->timestamp = 0;" $P && grep -qE "^\+[[:space:]]+vb2->timestamp = buf->timestamp;" $P'
chk "1049 not in the build (y15 drops it)" '! grep -qF "HFI_BUF_FW_FLAG_LAST | HFI_BUF_FW_FLAG_PSC_LAST" $P'
chk "1052 in the build: NOSHOW buffers requeued, NOSHOW->ERROR mapping gone, LAST buffers exempt from the empty check" 'grep -qE "^\+[[:space:]]+return iris_hfi_gen2_requeue_output_buffer\(inst, buf\);" $P && grep -qE "^-[[:space:]]+if \(inst_hfi_gen2->hfi_frame_info\.picture_type & HFI_GEN2_PICTURE_NOSHOW\)$" $P && grep -qE "^\+[[:space:]]+!\(buf->flags & V4L2_BUF_FLAG_LAST\)\) \{" $P'
chk "1053 in the build: smp2p resets inbound state only on restart" 'grep -qE "^\+[[:space:]]+if \(!restart\)$" $P'
chk "1054 in the build: uhid reads the queue slot under qlock" 'grep -qE "^\+[[:space:]]+ev = uhid->head == uhid->tail \? NULL : uhid->outq\[uhid->tail\];" $P'
chk "1055 in the build: cap.band[] indexed by NL80211_BAND_*" 'grep -qE "^\+.*cap\.band\[NL80211_BAND_2GHZ\]\.phy_id;" $P && grep -qE "^\+.*cap\.band\[NL80211_BAND_5GHZ\]\.phy_id;" $P'
chk "1056 in the build: t-power-on-us = <80> in baldur-wifi.dtsi" 'grep -qE "^\+[[:space:]]+t-power-on-us = <80>;" $P'
chk "1057 in the build: the vpu4x AV1 line size takes ten_bit" 'grep -qE "^\+static u32 hfi_vpu4x_buffer_line_av1d\(" $P && grep -qE "^\+[[:space:]]+return hfi_vpu4x_buffer_line_av1d\(width, height, is_opb, num_vpp_pipes,$" $P'
fdt=$(zcat /proc/config.gz | sed -n 's/^CONFIG_ARM64_BUILTIN_FDT_NAME="\(.*\)"$/\1/p')
chk "1056: the build kept its built-in DTB ($OUT/${fdt##*/}; CONFIG_ARM64_BUILTIN_FDT_NAME=$fdt)" '[ -n "$fdt" ] && [ -s "$OUT/${fdt##*/}" ]'
# ---- 0620-0622 at run time: the GMU's HFI interrupt (only CM3_FAULT is unmasked, after 0622 also during GMU boot)
# is never delivered. A count > 0 means a late HFI reply delivery that 0620's handler had to absorb, or a real CM3
# fault. y13 (same three patches): 0 after 10.5 h and 3 M GPU interrupts.
irq_count() { awk -v n="$1" '$NF == n {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s}' /proc/interrupts; }
chk "0620-0622: GMU HFI interrupt never delivered (hfi count $(irq_count hfi), GPU interrupts $(irq_count gpu-irq))" '[ "$(irq_count hfi)" = 0 ] && [ "$(irq_count gpu-irq)" -gt 0 ]'
chk "GMU interrupt never fired (gmu count $(irq_count gmu); watchdog / AHB / fence errors)" '[ "$(irq_count gmu)" = 0 ]'
# ---- 1051 at run time: upstream libva-v4l2's error-recovery board test (tests/decoder/error-recovery.py, d5df780 on),
# unmodified, as the desktop user against the INSTALLED driver. Its "<depth>-truncated" cases decode an HEVC stream
# with a cut slice: the firmware returns that picture with HFI_INFO_DATA_CORRUPT and V4L2 hands userspace an empty
# error buffer; only with 1051 does it carry the picture's timestamp, so libva-v4l2 can put a gray frame in its place.
# The unmodified upstream test has NO expected-failure handling: without 1051 the 8bit-b0-truncated decode waits for
# the 5 s surface sync timeout (then ~5 s more for the context destroy), ffmpeg exits non-zero, decode()'s
# "assert result.returncode == 0" raises AssertionError, the script dies with a traceback (rc 1) after 11 PASS lines,
# and the 22 cases after it (8bit-b0's two failure-injection cases, all of 10bit-b0 incl. 10bit-b0-truncated, all of
# 8bit-b3) never run. "XFAIL" lines exist only in linux/video/libva-v4l2-update.sh, which runs a REWRITTEN copy of the
# test on y13-or-older kernels (y13 baseline under that wrapper: runs/upstream/20261023-libva-v4l2-6d03c3f-update.log,
# 32 PASS + 2 XFAIL; every non-truncated case passes on y13 with the installed 6d03c3f driver).
# Verdict here: rc 0 (every case ran and passed; 6d03c3f has 34 cases) AND both "PASS <depth>-truncated:" lines.
# The other cases inject V4L2 errors through an LD_PRELOAD shim and check the driver's gray-frame recovery itself; any
# of them failing, or a decode over its 30 s subprocess timeout, also ends the test with rc != 0.
# Iris logs HFI_INFO_DATA_CORRUPT at debug level only, so the err-level iris check is repeated afterwards.
L=/usr/local/src/libva-v4l2; DRV=/usr/local/lib/aarch64-linux-gnu/dri
if [ "${Y15_NO_RECOVERY:-0}" = 1 ]; then
	echo "SKIP  1051 libva-v4l2 error-recovery test (Y15_NO_RECOVERY=1)"
elif [ ! -f $L/tests/decoder/error-recovery.py ] || [ ! -f $DRV/v4l2_drv_video.so ]; then
	ko "1051: no libva-v4l2 error-recovery test to run ($L at $(git -C $L log --oneline -1 2>/dev/null | cut -c1-7) has no tests/decoder/error-recovery.py, or no $DRV/v4l2_drv_video.so): update libva-v4l2 to d5df780 or later first"
else
	R=$(mktemp -d /tmp/y15-recovery.XXXXXX); chmod 755 "$R"
	cp $L/tests/decoder/error-recovery.py $L/tests/decoder/error-completion.c $L/tests/decoder/surface-storage.cpp "$R"/
	chown -R user: "$R"
	t0=$(date +%s)
	timeout -k 10 180 "${U[@]}" python3 -I "$R"/error-recovery.py "$R"/out --driver-dir $DRV > "$R"/run.log 2>&1; er_rc=$?
	er_s=$(( $(date +%s) - t0 ))
	echo "INFO  error-recovery.py: libva-v4l2 $(git -C $L log --oneline -1 | cut -c1-7), driver $DRV/v4l2_drv_video.so ($(date -r $DRV/v4l2_drv_video.so '+%m-%d %H:%M')), $(grep -c '^PASS' "$R"/run.log) PASS lines (6d03c3f with 1051: 34) in $er_s s"
	chk "1051: error-recovery.py ran to the end (rc $er_rc; 124 = the 3 min timeout)" '[ "$er_rc" = 0 ]'
	for d in 8bit-b0 10bit-b0; do
		chk "1051: $d-truncated: the firmware-reported corrupt picture became a gray frame, no 5 s stall ($(grep -q "^PASS $d-truncated:" "$R"/run.log && echo "PASS line present" || echo "no PASS line"))" 'grep -q "^PASS $d-truncated:" "$R"/run.log'
	done
	[ "$er_rc" = 0 ] || tail -15 "$R"/run.log | sed "s/^/      /"
	rm -rf "$R"
fi
chk "1051: still no iris err-level kernel lines after the error-recovery test (the 1057 probe's left out)" '[ -z "$(iris_errs)" ]'
# ---- upstream t52's new parts (no external monitor, no UFS fault needed)
DT=/proc/device-tree/soc@0; DPO=$DT/display-subsystem@9800000/displayport-controller@9ad2000/ports/port@1/endpoint
chk "t52 0023: no 'dsiN: pclk=... byteclk=...' info lines any more (y13: ~1000 in 10 h of kmsg)" '! dmesg -k | grep -qE "dsi[0-9]+: pclk="'
chk "t52 0138: the USB3/DP combo PHY is a Type-C mode switch (DT phy@88e8000/mode-switch)" '[ -e $DT/phy@88e8000/mode-switch ]'
chk "t52 0139: dwc3 is a mode switch, DP out has 4 lanes and the HBR3 link-frequencies (DT)" '[ -e $DT/usb@a600000/mode-switch ] && [ "$(stat -c %s $DPO/data-lanes)" = 16 ] && [ "$(stat -c %s $DPO/link-frequencies)" = 32 ]'
chk "t52 0136: dwc3-qcom registered its Type-C mux (/sys/class/typec_mux/a600000.usb-mux)" '[ -e /sys/class/typec_mux/a600000.usb-mux ]'
chk "DP connector present ($(cat /sys/class/drm/card*-DP-1/status 2>/dev/null); a monitor is the only real test of 0133-0139)" '[ -n "$(cat /sys/class/drm/card*-DP-1/status 2>/dev/null)" ]'
chk "t52 0141: UFS up in MCQ mode with ESI (boot lines)" 'dmesg -k | grep -q "1d84000.ufs: ESI configured" && dmesg -k | grep -q "1d84000.ufs: MCQ configured"'
chk "t52 0141: no err-level UFS kernel line since boot (0141 itself only acts after an error-handler host reset)" '! dmesg -k -l emerg,alert,crit,err | grep -qE "ufshcd|1d84000\.ufs|ufs_qcom|ufs-qcom"'
# ---- 1053 (smp2p: inbound state reset only on restart). Field-matched, not regex-matched, lines of /proc/interrupts:
#   "<n>: <per-CPU counts> ipcc <hwirq> Edge smp2p-adsp"                 every ADSP smp2p notification
#   "<n>: <per-CPU counts> smp2p-adsp <bit> Edge q6v5 ready"             the ADSP's ready bit, as q6v5 sees it
irq_tail() {	# <last field> <field before it> <the 5th field from the end, or "-">: summed per-CPU counts of the matching lines
	awk -v a="$1" -v b="$2" -v c="$3" '$NF == a && $(NF - 1) == b && (c == "-" || $(NF - 4) == c) {for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break} END {print s + 0}' /proc/interrupts
}
sa0=$(irq_tail smp2p-adsp Edge -); qr0=$(irq_tail ready q6v5 smp2p-adsp); sleep 10
sa1=$(irq_tail smp2p-adsp Edge -); qr1=$(irq_tail ready q6v5 smp2p-adsp)
dsa=$((sa1 - sa0)); dqr=$((qr1 - qr0))
if [ $dsa = 0 ]; then v="no ADSP notification in the window: inconclusive (sensors idle?)"
elif [ $dqr = 0 ]; then v="consistent with 1053: ADSP notifications no longer replay the ready edge"
elif [ $dqr -ge $dsa ]; then v="ready fired with every notification, as before 1053: 1053 NOT effective?"
else v="ready fired $dqr times: look at it"; fi
echo "INFO  1053: in 10 s smp2p-adsp +$dsa, q6v5 ready (adsp) +$dqr: $v (7.3-rc4, 10-21: 273 and 273 in 60 s)"
echo "INFO  1053: since boot smp2p-adsp $sa1, q6v5 ready (adsp) $qr1 (before 1053 the two grow together; y15: ready should stay near its boot value)"
chk "1053 guard: no 'Handover signaled, but it already happened' since boot (got $(dmesg | grep -c 'Handover signaled, but it already happened'); y14 had none either, v7.3 masks the handover irq)" '[ "$(dmesg | grep -c "Handover signaled, but it already happened")" = 0 ]'
echo "INFO  1053: remoteprocs: $(for r in /sys/class/remoteproc/remoteproc*; do printf '%s=%s ' "$(cat $r/name 2>/dev/null)" "$(cat $r/state 2>/dev/null)"; done)(the SSR path 1053 keeps is not exercised: it needs a remote restart)"
# SoCCP (early_boot, attached at boot) is the other smp2p v2 user; its attach reads the level, not last_value
# (runs/upstream/20261028-deep-read.md, objection 3). Its dependents are checked above: battmgr (0132, battery), ucsi, role switch.
chk "1053: no remoteproc crashed ($(grep -l crashed /sys/class/remoteproc/remoteproc*/state 2>/dev/null | wc -l) in state crashed)" '! grep -qx crashed /sys/class/remoteproc/remoteproc*/state'
# ---- 1054 (uhid: read the output queue under qlock): no reproducer; only what the path is
echo "INFO  1054: CONFIG_UHID=$(zcat /proc/config.gz | sed -n 's/^CONFIG_UHID=//p'), module $(lsmod | grep -q '^uhid ' && echo loaded || echo 'not loaded'), /dev/uhid $([ -e /dev/uhid ] && echo present || echo absent), modprobe -n: '$(modprobe -n -v uhid 2>&1 | head -1)' (used by BlueZ for HID-over-GATT devices)"
# ---- 1055 (ath12k: single-pdev frequency ranges), as linux/wifi/5GHZ-ARMADA-594-EVAL.md asks: JP, HOME_6G, 300 pings
# LC_ALL=C: root's locale on the tablet is zh_CN, and nmcli translates ACTIVE even with -t (10-29: "是:HOME_6G")
on_home6=$(LC_ALL=C nmcli -t -f ACTIVE,SSID dev wifi list --rescan no 2>/dev/null | grep -cx "yes:HOME_6G")
# the Wi-Fi phy's own domain (ath12k registers one), not the global one udev sets: 10-29 'phy#0 / country JP: DFS-JP'
chk "1055: regulatory domain JP on the Wi-Fi phy (iw phy <phy> reg get)" 'iw phy "$(cat /sys/class/net/wlp1s0/phy80211/name 2>/dev/null)" reg get 2>/dev/null | grep -q "^country JP"'
chk "1055: connected to HOME_6G by itself (EVAL)" '[ "$on_home6" -ge 1 ]'
echo "INFO  1055: link: $(iw dev wlp1s0 link 2>/dev/null | grep -E 'SSID|freq|tx bitrate' | tr -s '\t ' ' ' | tr '\n' ';')"
echo "INFO  1055: networks in the cached scan, 2.4 / 5 / 6 GHz: $(nmcli -t -f FREQ dev wifi list --rescan no 2>/dev/null | awk '{f = $1 + 0; if (f < 3000) a++; else if (f < 5925) b++; else c++} END {printf "%d / %d / %d", a, b, c}') (EVAL: all three bands visible; under JP the union of the ranges does not change)"
if [ "${Y15_NO_PING:-0}" = 1 ]; then
	echo "SKIP  1055 ping (Y15_NO_PING=1)"
elif [ "$on_home6" -lt 1 ]; then
	echo "SKIP  1055 ping: not on HOME_6G"
else
	pg=$(ping -c 300 -i 0.2 -q 192.168.0.1 2>&1 | grep -E "packet loss|rtt" | tr '\n' ' ')
	echo "INFO  1055: ping -c 300 -i 0.2 192.168.0.1: $pg(EVAL: 0% loss; compare with a y14 run before calling a loss a regression)"
fi
# ---- 1056 (the Wi-Fi root port's T_POWER_ON): the live device tree is the built-in DTB (upstream 0021), so the
# property must be there exactly once, on the root port above the WCN7860, with value 80 (one big-endian cell)
DTB_LIVE=/sys/firmware/devicetree/base
tpo=$(find $DTB_LIVE -name t-power-on-us 2>/dev/null)
chk "1056: exactly one t-power-on-us in the live device tree ($(printf '%s\n' "$tpo" | grep -c .) found: $(printf '%s\n' "$tpo" | sed "s|^$DTB_LIVE||" | tr '\n' ' '))" '[ "$(printf "%s\n" "$tpo" | grep -c .)" = 1 ]'
rpn=$(dirname "$(printf '%s\n' "$tpo" | head -1)")
chk "1056: on the Wi-Fi root port (its wifi@0 child is pci17cb,110e)" '[ "$(tr -d "\0" < "$rpn/wifi@0/compatible" 2>/dev/null)" = pci17cb,110e ]'
chk "1056: value 80 us (cell 0x00000050)" '[ "$(od -An -tx1 "$rpn/t-power-on-us" 2>/dev/null | tr -d " \n")" = 00000050 ]'
# pcie-qcom programs it into the root port's L1SS capability at probe (v7.3, e9769bb17269); read-only lspci, never the
# PCIe debugfs. The root port is the parent of the Wi-Fi function 0000:01:00.0 in sysfs.
rpb=$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/0000:01:00.0)")")
chk "1056: lspci: root port $rpb advertises PortTPowerOnTime=80us (y14, 10-23: 0us)" 'lspci -vvv -s "$rpb" 2>/dev/null | grep -q "PortTPowerOnTime=80us"'
echo "INFO  1056: L1SS root port | Wi-Fi: $(for d in "$rpb" 0000:01:00.0; do lspci -vvv -s $d 2>/dev/null | grep -oE 'PortTPowerOnTime=[0-9]+us|LTR1.2_Threshold=[0-9]+ns|T_PwrOn=[0-9]+us' | tr '\n' ' '; printf '| '; done)(y14, 10-23: LTR1.2_Threshold=76800ns, T_PwrOn=0us on both ends; y15 by aspm.c's formula: 2+4+70+80 = 156 us -> LTR1.2_Threshold=156672ns, T_PwrOn=80us on both ends - only while L1.2 is enabled)"
echo "INFO  1056: AER kernel lines since boot, not counting 'AER: enabled with IRQ': $(dmesg -k | grep 'AER:' | grep -vc 'AER: enabled with IRQ') (what Qualcomm reports for the L1.2 exit without T_POWER_ON)"
echo; echo "config diff vs intent (olddefconfig survivors):"; zcat /proc/config.gz | grep -E "^CONFIG_(UCLAMP_TASK|CPU_IDLE_GOV_TEO|RCU_LAZY|RCU_NOCB_CPU_DEFAULT_ALL|DEFAULT_HUNG_TASK_TIMEOUT|ARM_PSCI_CPUIDLE_DOMAIN)=" ; zcat /proc/config.gz | grep -E "^CONFIG_(SCHED_CACHE|KSM|CORESIGHT|ANDROID_BINDER_IPC|AUDIT|COMPAT|KEXEC|SERIAL_8250|PREEMPT_RT)=" && echo "  ^ should be absent"
echo "the two v7.3 errata lines (new in y14, unchanged in y15; MIDR-matched, nothing on Oryon):"; zcat /proc/config.gz | grep -E "^CONFIG_(ARM64_ERRATUM_3821522|ARM64_WORKAROUND_BROKEN_AMU_CONSTCNT)="
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
