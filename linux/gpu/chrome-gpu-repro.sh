#!/bin/bash
# Reproduce / bisect the Chrome GPU hang (Adreno 840 "hangcheck recover", 2026-10-14) in a throw-away
# profile. Run as root on the tablet: chrome-gpu-repro.sh <variant> [url] [seconds]
#   base    = the desktop entry's flags (VA-API features, --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy)
#   plain   = no flags of ours at all (only --ozone-platform=wayland): what stock Chrome does
#   nofinch = base + --enable-benchmarking (every server-side field trial in its default group: tells a
#             Finch-flipped feature from a driver/kernel problem; same binary, sudden onset points there)
#   noforce = base minus --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy
#   novaapi = base minus the VA-API --enable-features list
#   zink    = base, GL through zink on the tb323fu Turnip (MESA_LOADER_DRIVER_OVERRIDE=zink)
#   seed    = base, but the throw-away profile starts with a copy of the owner's "Local State" (it carries
#             the downloaded variations seed): a fresh profile has no seed on its first run, so if base
#             does not hang and seed does, a server-side field trial is the trigger
#   desktop = exactly the desktop entry's Exec flags, i.e. base + --enable-wayland-ime
#             --wayland-text-input-version=3 (Chrome talks text-input-v3, so a focused field brings up
#             the on-screen keyboard, whose exclusive zone resizes the window)
#   profile = desktop flags on a full copy of the owner's profile (tmpfs, deleted afterwards; the
#             Singleton* locks are left out so it does not hand off to a running Chrome)
#   cache   = base, profile seeded with copies of the owner's GPU caches (GPUPersistentCache,
#             Default/GPUCache, Default/DawnGraphiteCache, Default/DawnWebGPUCache): a poisoned cached
#             shader/program would hang the GPU on every start whatever the page
# Prints how many GPU hangs the kernel logged and how many guilty context resets Chrome reported.
# WARNING: every hang resets the GPU for everybody: KWin redraws (the screen flashes), other GL/Vulkan
# programs lose their context. Warn whoever is using the tablet before running it.
set -u
variant=${1:?variant: base|plain|nofinch|noforce|novaapi|zink|seed|cache|desktop|profile}; url=${2:-https://www.wikipedia.org}; secs=${3:-15}
feat='--enable-features=WebRtcPipeWireCamera,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecoder,AcceleratedVideoEncoder,VaapiVideoDecoder,VaapiVideoEncodeAccelerator,VaapiIgnoreDriverChecks,PlatformHEVCDecoderSupport'
force='--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy'
envx=""
case $variant in
	base)    flags="$feat $force" ;;
	plain)   flags="" ;;
	nofinch) flags="$feat $force --enable-benchmarking" ;;
	noforce) flags="$feat" ;;
	novaapi) flags="$force" ;;
	zink)    flags="$feat $force"; envx="MESA_LOADER_DRIVER_OVERRIDE=zink" ;;
	seed|cache) flags="$feat $force" ;;
	desktop|profile) flags="--enable-wayland-ime --wayland-text-input-version=3 $feat $force" ;;
	*) echo "unknown variant $variant" >&2; exit 2 ;;
esac
flags="$flags ${EXTRA:-}"    # e.g. EXTRA=--start-maximized (the owner's window is maximized)
prof=$(sudo -u user mktemp -d /tmp/y700-chrome-repro.XXXXXX)
[ "$variant" = seed ] && sudo -u user cp "/home/user/.config/google-chrome/Local State" "$prof/Local State"
if [ "$variant" = profile ]; then
	sudo -u user cp -a /home/user/.config/google-chrome/. "$prof/"
	rm -f "$prof"/Singleton*
fi
if [ "$variant" = cache ]; then
	src=/home/user/.config/google-chrome
	sudo -u user mkdir -p "$prof/Default"
	for d in GPUPersistentCache Default/GPUCache Default/DawnGraphiteCache Default/DawnWebGPUCache; do
		[ -e "$src/$d" ] && sudo -u user cp -a "$src/$d" "$prof/$d"
	done
fi
log=$prof.log
t0=$(date '+%Y-%m-%d %H:%M:%S')
echo "variant=$variant extra=${EXTRA:-} url=$url secs=$secs profile=$prof start=$t0"
sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
	VK_ICD_FILENAMES=/var/lib/tb323fu/mesa/icd/turnip.json VK_DRIVER_FILES=/var/lib/tb323fu/mesa/icd/turnip.json $envx \
	/opt/google/chrome/chrome --user-data-dir="$prof" --no-first-run --no-default-browser-check \
	--ozone-platform=wayland $flags "$url" >"$log" 2>&1 &
pid=$!
# DURING = a command (run as root) 6 s after the start, e.g. bring the on-screen keyboard up and down
[ -n "${DURING:-}" ] && { sleep 6; bash -c "$DURING"; } &
sleep "$secs"
# save the first GPU crash state before it expires (devcoredump keeps one for 5 minutes)
for d in /sys/class/devcoredump/devcd*; do
	[ -e "$d/data" ] || continue
	head -c 400 "$d/data" | grep -q '^comm:' || continue    # GPU crash state (the DPU dump has no comm:)
	mkdir -p /root/gpu-crash; cp "$d/data" "/root/gpu-crash/$(date +%m%d-%H%M%S)-$variant-$(basename "$d").txt"
done
kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null
hangs=$(journalctl -k --since "$t0" --no-pager | grep -c "hangcheck recover")
journalctl -k --since "$t0" --no-pager -o short-precise | grep "hangcheck recover" | awk '{print "  hang at", $3}'
guilty=$(grep -c 'GUILTY_CONTEXT_RESET' "$log")
renderer=$(grep -m1 -oE 'GL_RENDERER[^,]*|zink[^)]*\)' "$log")
echo "RESULT variant=$variant extra=${EXTRA:-} hangs=$hangs chrome_guilty=$guilty ${renderer:+renderer=$renderer}"
rm -rf "$prof"
