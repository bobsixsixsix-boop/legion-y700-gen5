#!/bin/bash
# y12-gpu-stress.sh [SECONDS]: exercise the high GPU OPPs on y12 before `kernel keep` (VISIBLE: ~1 min of a muted
# fullscreen clip with mpv's heaviest scalers and frame interpolation). ROOT. 2026-10-16, from the y12 review: the new
# 1048 dependency votes matter most at 826-1200 MHz, which normal use (upthreshold 80) rarely visits.
# GPU profile "performance" (floor 461 MHz) for the run, restored afterwards. Per second: GPU cur_freq. After: every new
# kernel line since the start that matches the y12-verify failure strings, plus y12-verify's dmesg checks.
set -u
T=${1:-45}
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
GPU=/sys/class/devfreq/3d00000.gpu
prof0=$(tb323fu-ctl gpu 2>/dev/null | awk '/^  Profile:/ {print $2}'); [ -z "$prof0" ] && prof0=balanced
n0=$(dmesg -k | wc -l); MPV=
restore() { trap - EXIT; [ -n "$MPV" ] && kill $MPV 2>/dev/null; tb323fu-ctl gpu profile "$prof0" >/dev/null 2>&1; echo "restored GPU profile $prof0 ($(cat $GPU/min_freq)-$(cat $GPU/max_freq))"; }
trap restore EXIT; trap 'exit 1' INT TERM
cp /root/vt/hevc.mp4 /tmp/y700-ab-hevc.mp4; chmod 644 /tmp/y700-ab-hevc.mp4
tb323fu-ctl gpu profile performance >/dev/null 2>&1
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
"${U[@]}" mpv --fs --ao=null --hwdec=vaapi --vo=gpu --gpu-api=opengl --loop-file=inf --no-osc --osd-level=0 \
	--scale=ewa_lanczossharp --cscale=ewa_lanczossharp --dscale=mitchell --video-sync=display-resample --interpolation \
	--tscale=oversample --deband=yes --deband-iterations=4 --input-ipc-server=/tmp/y700-stress.sock /tmp/y700-ab-hevc.mp4 >/dev/null 2>&1 &
sleep 3; MPV=$(pgrep -u user -f "y700-stress.sock" | head -1)
declare -A H; mx=0
for s in $(seq $T); do f=$(( $(cat $GPU/cur_freq) / 1000000 )); H[$f]=$(( ${H[$f]:-0} + 1 )); [ $f -gt $mx ] && mx=$f; sleep 1; done
echo "GPU cur_freq over $T s (MHz: seconds): $(for k in $(printf '%s\n' "${!H[@]}" | sort -n); do printf '%s:%s ' $k ${H[$k]}; done)  max $mx"
kill $MPV 2>/dev/null; MPV=
# restore the profile BEFORE verifying: the helper's "performance" profile also turns Wi-Fi power save off (by design),
# which y12-verify reports as "FAIL wifi power save on" (10-16 18:2x, the first two stress runs)
tb323fu-ctl gpu profile "$prof0" >/dev/null 2>&1; sleep 2
echo "new kernel lines since the start: $(( $(dmesg -k | wc -l) - n0 ))"
dmesg -k | tail -n +$((n0 + 1)) | grep -iE "gmu|hfi|rpmh|adreno|a6xx|a8xx|gpu|hang|fault|recover|fenced|gdsc" | head -20 | sed 's/^/  /'
bash /root/y12-verify.sh 2>/dev/null | grep -E "^FAIL|GMU|RPMh|hang|err-level|fenced|ALL PASS|SOME FAILED"   # FAIL lines too (10-16: one transient FAIL right after the first run)
