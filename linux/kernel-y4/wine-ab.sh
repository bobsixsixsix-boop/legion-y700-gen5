#!/bin/bash
# Same-boot A/B on y4: Wine cmd.exe loop as is (SSBS=1 thanks to 0540) vs forced into y3's state via
# prctl(PR_SPEC_STORE_BYPASS, DISABLE) (ssbd-run wrapper from ssbd-bench.sh). Run wine-ssbs-test.sh first (prefix).
P="/home/user/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files"; PFX=/tmp/y700-ssbs/pfx
N=${1:-600000}
W() { taskset -c 7 $PRE runuser -u user -- env WINEPREFIX=$PFX WINEDEBUG=-all WINESERVER="$P/bin-arm64/wineserver" \
	WINELOADER="$P/bin-arm64/wine" DISPLAY= WAYLAND_DISPLAY= HOME=/home/user "$P/bin-arm64/wine" "$@"; }
# a loop that did not finish (Wine failed to start, crashed) must not become a short "fast" sample
t() { local s e; s=$(date +%s.%N); W cmd /c "for /L %i in (1,1,$N) do @rem" >/dev/null 2>&1 || { echo "FAILED(exit $?)"; return; }; e=$(date +%s.%N); echo "$e - $s" | bc; }
W cmd /c echo warm >/dev/null 2>&1
echo "cpu7 $(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq) kHz, $(uname -r)"
for i in 1 2 3 4 5; do
	PRE=; a=$(t); PRE=/root/ssbd-bench/ssbd-run; b=$(t)
	echo "loop $N: SSBS=1 ${a}s | forced SSBS=0 (y3 state) ${b}s"
done
runuser -u user -- env WINEPREFIX=$PFX "$P/bin-arm64/wineserver" -k 2>/dev/null; true
