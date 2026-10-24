#!/bin/bash
# y12-verify.sh: after the first boot of y12 (= y10-verify.sh + checks for the 1046-1048 A8xx GMU vote fixes). Run as root.
# PASS/FAIL per line, exit 1 on any FAIL. Y10_NO_TOGGLE=1 skips the runtime toggle test of the knob.
# The toggle test writes 1 then 0 to allow_system_off. With allow_cluster_off=N (the cmdline default) the cluster domains
# never power off, so the system domain is never reached: the toggle changes one flag bit and prints two dmesg lines,
# nothing else (RESEARCH.md 3.3). It refuses to run while allow_cluster_off is Y.
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
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
chk "running y12: $(uname -r)" '[ "$(uname -r)" = 7.3.0-rc4-tb323fu-t49-y12 ]'
chk "cmdline: y9's unchanged (allow_cluster_off=0 pinned, NO allow_system_off token, idle_refresh present, no qos_disable)" 'c=$(cat /proc/cmdline); grep -q "cpuidle_psci_domain.allow_cluster_off=0" <<<"$c" && ! grep -q "allow_system_off" <<<"$c" && grep -q "msm.idle_refresh_ms60=500" <<<"$c" && ! grep -q qos_disable <<<"$c"'
chk "panel idle refresh 500/2000" '[ "$(cat /sys/module/msm/parameters/idle_refresh_ms60)" = 500 ] && [ "$(cat /sys/module/msm/parameters/idle_refresh_ms30)" = 2000 ]'
chk "systemctl --failed empty" '[ -z "$(systemctl --failed --no-legend)" ]'
chk "user units: no failed" '[ -z "$("${U[@]}" systemctl --user --failed --no-legend)" ]'
chk "no previous-boot crash (journal -b -1 ended cleanly or absent)" 'journalctl -b -1 -n 50 --no-pager -o cat 2>/dev/null | grep -qE "Journal stopped|reboot.target|Reached target System Reboot" || [ -z "$(journalctl --list-boots -q 2>/dev/null | sed -n 2p)" ]'
# ---- upstream t51: 0132 battmgr charge-current limit sysfs (helper 0.4.2's 9 V bypass uses it). 0131 (dpu modeset
# only when a DSPP is missing) has no cheap runtime probe: watch that night light no longer blanks the panel.
B=/sys/class/power_supply/qcom-battmgr-bat
chk "0132: constant_charge_current writable + constant_charge_current_max > 0 (max $(cat $B/constant_charge_current_max 2>/dev/null) uA)" '[ -w $B/constant_charge_current ] && [ "$(cat $B/constant_charge_current_max)" -gt 0 ]'
# ---- 1043: the allow_system_off knob
chk "PSCI domain topology in OSI mode" 'dmesg | grep -q "CPUidle PSCI: Initialized CPU PM domain topology using OSI mode"'
chk "1043 boot line in dmesg (quirk applied, knob N)" 'dmesg | grep -qF "$BOOT_LINE"'
chk "1043 knob exists, mode 644" '[ -f $ASO ] && [ "$(stat -c %a $ASO)" = 644 ]'
chk "1043 knob default N" '[ "$(cat $ASO)" = N ]'
chk "0118 knob N (cmdline)" '[ "$(cat $ACO)" = N ]'
chk "system domain never attempted since boot: S0 Usage/Rejected = 0/0 (got $(pd_ur))" '[ "$(pd_ur)" = 0/0 ]'
chk "cluster domains refused as before (0118): Rejected > 0 on power-domain-cluster" '[ "$(awk "NR==2{print \$4}" /sys/kernel/debug/pm_genpd/power-domain-cluster/idle_states)" -gt 0 ]'
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
up_h=$(awk '{printf "%.1f", $1 / 3600}' /proc/uptime); fenced=$(dmesg -k | grep -c "delay in fenced register write")
echo "INFO  GMU 'delay in fenced register write': $fenced in $up_h h = $(awk -v n=$fenced -v h=$up_h 'BEGIN {printf "%.1f", (h > 0 ? n / h : 0)}')/h (y10 baseline: 82 in ~5 h = ~16/h; dev_err_ratelimited, so a lower bound)"
# my first dedicated check, kept next to the reviewer's (10-16): the vote-table builders' other complaints
chk "no RPMh vote-table build errors (Available levels / BCM aux size / truncated)" '! dmesg | grep -qE "not found in the RPMh list|Available levels:|invalid BCM .* aux data size|is being truncated"'
echo; echo "config diff vs intent (olddefconfig survivors):"; zcat /proc/config.gz | grep -E "^CONFIG_(UCLAMP_TASK|CPU_IDLE_GOV_TEO|RCU_LAZY|RCU_NOCB_CPU_DEFAULT_ALL|DEFAULT_HUNG_TASK_TIMEOUT|ARM_PSCI_CPUIDLE_DOMAIN)=" ; zcat /proc/config.gz | grep -E "^CONFIG_(SCHED_CACHE|KSM|CORESIGHT|ANDROID_BINDER_IPC|AUDIT|COMPAT|KEXEC|SERIAL_8250|PREEMPT_RT)=" && echo "  ^ should be absent"
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
