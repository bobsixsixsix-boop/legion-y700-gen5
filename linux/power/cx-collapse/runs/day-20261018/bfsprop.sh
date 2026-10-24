#!/bin/bash
# 2026-10-18 13:10: after the reboot the owner's Chrome (restored at login from the patched com.google.Chrome launcher)
# has WaylandExternalBeginFrameSource in the browser's --enable-features, but its GPU process's --enable-features
# (which Chrome rebuilds from the browser's feature list) lacks it - while this morning's throwaway Chrome
# (bfstest.sh, only that one feature) passed it on. Which part of the owner's launch drops it? Throwaway profiles
# under /tmp/bfsp, each in its own user unit (stopping the unit takes the whole process tree): launch, wait, read
# the GPU process's --enable-features, stop. Waits for the screen to be off first so no window pops up in front of
# the owner. Output: /root/bfsprop-HHMM.txt
export LC_ALL=C
OUT=/root/bfsprop-$(date +%H%M).txt
U=user
UENV="XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
FEAT=WaylandExternalBeginFrameSource
LIST=WebRtcPipeWireCamera,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecoder,AcceleratedVideoEncoder,VaapiVideoDecoder,VaapiVideoEncodeAccelerator,VaapiIgnoreDriverChecks,PlatformHEVCDecoderSupport,$FEAT
OWNER="--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3 --enable-features=$LIST --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy"
COMMON="--no-first-run --no-default-browser-check --password-store=basic --disable-sync --disable-component-update about:blank"

dpms() { for c in /sys/class/drm/card*-*; do [ "$(cat $c/status 2>/dev/null)" = connected ] && cat $c/dpms; done | head -1; }
u() { sudo -u $U env $UENV "$@"; }

run() {  # name, extra systemd-run args, binary, chrome args...
	local v=$1 sr=$2 bin=$3; shift 3
	local dir=/tmp/bfsp/$v
	[ -d $dir ] || install -d -o $U $dir
	u systemd-run --user --quiet --collect --unit=y700-bfsp-$v $sr $bin --user-data-dir=$dir "$@" $COMMON
	sleep 12
	local cg=$(u systemctl --user show -P ControlGroup y700-bfsp-$v) g="" feats=""
	for p in $(cat /sys/fs/cgroup$cg/cgroup.procs 2>/dev/null); do
		tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -e '--type=gpu-process' && g=$p
	done
	feats=$(tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | grep -o -e '--enable-features=[^ ]*' | head -1)
	case "$feats" in *$FEAT*) r=HAS;; "") r="NO-GPU-PROCESS?";; *) r=MISSING;; esac
	echo "$v: gpu=$g $r   $feats"
	u systemctl --user stop y700-bfsp-$v 2>/dev/null; sleep 2
}

{
echo "bfsprop $(date '+%F %T')  $(/opt/google/chrome/chrome --version 2>/dev/null)  dpms=$(dpms)"
for i in $(seq 180); do [ "$(dpms)" = Off ] && break; sleep 10; done
if [ "$(dpms)" != Off ]; then echo "screen stayed on for 30 min - nothing run"; exit 0; fi
echo "screen off at $(date +%T), starting"
run min "" /opt/google/chrome/chrome --ozone-platform=wayland --enable-features=$FEAT
run list "" /opt/google/chrome/chrome --ozone-platform=wayland --enable-features=$LIST
run owner "" /opt/google/chrome/chrome $OWNER
run owner-zink "--setenv=MESA_LOADER_DRIVER_OVERRIDE=zink" /usr/bin/google-chrome-stable $OWNER
# the owner's Local State (+ the variations seed files) in a throwaway dir: is it the profile / Finch seed?
d=/tmp/bfsp/localstate; install -d -o $U $d
cp -p "/home/$U/.config/google-chrome/Local State" /home/$U/.config/google-chrome/Variations* $d/ 2>/dev/null
run localstate "--setenv=MESA_LOADER_DRIVER_OVERRIDE=zink" /usr/bin/google-chrome-stable $OWNER
echo "done $(date +%T)  dpms=$(dpms)  leftover units: $(u systemctl --user list-units 'y700-bfsp-*' --no-legend | wc -l)"
rm -rf /tmp/bfsp
} > $OUT 2>&1
