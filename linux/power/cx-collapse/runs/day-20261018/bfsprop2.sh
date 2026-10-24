#!/bin/bash
# 2026-10-18 13:10: after the reboot the owner's Chrome (restored at login from the patched com.google.Chrome launcher)
# has WaylandExternalBeginFrameSource in the browser's --enable-features, but its GPU process's --enable-features
# (which Chrome rebuilds from the browser's feature list) lacks it - while this morning's throwaway Chrome
# (bfstest.sh, only that one feature) passed it on. Which part of the owner's launch drops it? Throwaway profiles
# under /tmp/bfsp, each in its own user unit (stopping the unit takes the whole process tree): launch, wait, read
# the GPU process's --enable-features, stop. Waits for the screen to be off first so no window pops up in front of
# the owner. Output: /root/bfsprop-HHMM.txt
# bfsprop2 (13:14): bfsprop.sh found the owner's Local State + Variations* files are what drop it. Which of the two,
# and does the switch still work (screen-off compositor wakeups on a page that changes text every second)?
export LC_ALL=C
OUT=/root/bfsprop2-$(date +%H%M).txt
U=user
UENV="XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
FEAT=WaylandExternalBeginFrameSource
LIST=WebRtcPipeWireCamera,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecoder,AcceleratedVideoEncoder,VaapiVideoDecoder,VaapiVideoEncodeAccelerator,VaapiIgnoreDriverChecks,PlatformHEVCDecoderSupport,$FEAT
OWNER="--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3 --enable-features=$LIST --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy"
PAGE=${PAGE:-about:blank}
COMMON="--no-first-run --no-default-browser-check --password-store=basic --disable-sync --disable-component-update"

dpms() { for c in /sys/class/drm/card*-*; do [ "$(cat $c/status 2>/dev/null)" = connected ] && cat $c/dpms; done | head -1; }
u() { sudo -u $U env $UENV "$@"; }

run() {  # name, extra systemd-run args, binary, chrome args...
	local v=$1 sr=$2 bin=$3; shift 3
	local dir=/tmp/bfsp/$v
	[ -d $dir ] || install -d -o $U $dir
	u systemd-run --user --quiet --collect --unit=y700-bfsp-$v $sr $bin --user-data-dir=$dir "$@" $COMMON $PAGE
	sleep 12
	local cg=$(u systemctl --user show -P ControlGroup y700-bfsp-$v) g="" feats=""
	for p in $(cat /sys/fs/cgroup$cg/cgroup.procs 2>/dev/null); do
		tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -e '--type=gpu-process' && g=$p
	done
	feats=$(tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | grep -o -e '--enable-features=[^ ]*' | head -1)
	case "$feats" in *$FEAT*) r=HAS;; "") r="NO-GPU-PROCESS?";; *) r=MISSING;; esac
	echo "$v: gpu=$g $r   $feats"
	if [ -n "$MEASURE" ] && [ -n "$g" ]; then
		local t=$(grep -l "^VizCompositorTh" /proc/$g/task/*/comm 2>/dev/null | head -1 | xargs -r dirname)
		local a=$(awk '/_ctxt_switches/ {s += $2} END {print s + 0}' $t/status); sleep $MEASURE
		local b=$(awk '/_ctxt_switches/ {s += $2} END {print s + 0}' $t/status)
		echo "    VizCompositorTh $(awk -v a=$a -v b=$b -v s=$MEASURE 'BEGIN {printf "%.1f", (b - a) / s}')/s over ${MEASURE} s  dpms=$(dpms)"
	fi
	u systemctl --user stop y700-bfsp-$v 2>/dev/null; sleep 2
}

{
echo "bfsprop2 $(date '+%F %T')  $(/opt/google/chrome/chrome --version 2>/dev/null)  dpms=$(dpms)"
if [ "$(dpms)" != Off ]; then echo "screen on - nothing run"; exit 0; fi
G=/home/$U/.config/google-chrome
mkdir -p /tmp/bfsp; chmod 755 /tmp/bfsp
echo '<!doctype html><title>tick</title><p id=t></p><script>setInterval(() => t.textContent = new Date().toISOString(), 1000)</script>' > /tmp/bfsp/tick.html
chmod 644 /tmp/bfsp/tick.html
d=/tmp/bfsp/lsonly; install -d -o $U $d; cp -p "$G/Local State" $d/
run lsonly "--setenv=MESA_LOADER_DRIVER_OVERRIDE=zink" /usr/bin/google-chrome-stable $OWNER
d=/tmp/bfsp/seedonly; install -d -o $U $d; cp -p $G/Variations* $d/
run seedonly "--setenv=MESA_LOADER_DRIVER_OVERRIDE=zink" /usr/bin/google-chrome-stable $OWNER
PAGE=file:///tmp/bfsp/tick.html; MEASURE=30
for v in both-flag both-noflag; do
	d=/tmp/bfsp/$v; install -d -o $U $d; cp -p "$G/Local State" $G/Variations* $d/
done
run both-flag "--setenv=MESA_LOADER_DRIVER_OVERRIDE=zink" /usr/bin/google-chrome-stable $OWNER
run both-noflag "--setenv=MESA_LOADER_DRIVER_OVERRIDE=zink" /usr/bin/google-chrome-stable ${OWNER/,$FEAT/}
d=/tmp/bfsp/fresh-flag; install -d -o $U $d
run fresh-flag "--setenv=MESA_LOADER_DRIVER_OVERRIDE=zink" /usr/bin/google-chrome-stable $OWNER
echo "done $(date +%T)  dpms=$(dpms)  leftover units: $(u systemctl --user list-units 'y700-bfsp-*' --no-legend | wc -l)"
rm -rf /tmp/bfsp
} > $OUT 2>&1
