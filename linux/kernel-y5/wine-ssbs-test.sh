#!/bin/bash
# Run as root on the tablet. Uses Proton 11.0 (ARM64)'s wine in a throw-away prefix (as user) to
#  1) time a CPU-bound cmd.exe loop (Wine's own arm64 code), 2) snapshot SSBS of the wine threads mid-run.
# y3: expect every wine thread SSBS=0; y4 (armada 0540 + SM8850 MIDR): SSBS=1 and a faster loop.
set -u
P="/home/user/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files"
D=/tmp/y700-ssbs; PFX=$D/pfx   # wine refuses a prefix whose parent the user does not own
N=${1:-300000}
W() { taskset -c 7 runuser -u user -- env WINEPREFIX=$PFX WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
	WINESERVER="$P/bin-arm64/wineserver" WINELOADER="$P/bin-arm64/wine" \
	DISPLAY= WAYLAND_DISPLAY= HOME=/home/user "$P/bin-arm64/wine" "$@"; }
uname -r
install -d -o user -g user $D
if [ ! -d $PFX ]; then
	W wineboot -i >/dev/null 2>&1 && echo "prefix created" || { echo "wineboot failed"; rm -rf $PFX; }
fi
W cmd /c echo wine-ok 2>&1 | tail -1
for i in 1 2 3; do
	s=$(date +%s.%N); W cmd /c "for /L %i in (1,1,$N) do @rem" >/dev/null 2>&1; e=$(date +%s.%N)
	echo "cmd loop $N: $(echo "$e - $s" | bc) s"
done
# keep one wine process alive and peek at its threads
W cmd /c "for /L %i in (1,1,$((N * 20))) do @rem" >/dev/null 2>&1 &
sleep 2
pids=$(pgrep -u user -f 'cmd\.exe|services\.exe|winedevice\.exe' | tr '\n' ' ')
bash /root/ssbs-peek.sh $pids
for p in $(pgrep -u user -f 'wineserver|cmd\.exe|services\.exe'); do   # y5: does Proton's wine use /dev/ntsync?
	echo "pid $p $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-40): ntsync fds=$(ls -l /proc/$p/fd 2>/dev/null | grep -c ntsync)"
done
wait
runuser -u user -- env WINEPREFIX=$PFX "$P/bin-arm64/wineserver" -k 2>/dev/null
true
