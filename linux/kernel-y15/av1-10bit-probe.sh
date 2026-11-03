#!/bin/bash
# av1-10bit-probe.sh - Track A discriminating experiment (run as root on the
# Y700, kernel y14 or y15, with the qcom-va-driver v1.1.1 test build).
#
# Question: which internal buffer does the Kaanapali firmware reject when
# HFI_CMD_START fails with "insufficient resources" for AV1 10-bit, and does
# the stream's superblock size decide pass/fail as the fitted LINE-buffer
# model predicts?
#
# What it changes on the system (all temporary):
#   * files under $WORK (default /tmp/av1probe);
#   * one dynamic_debug site, iris_hfi_gen2_flush_debug_queue, switched to +p
#     so the firmware's own log reaches dmesg; restored on exit;
#   * marker lines written to /dev/kmsg.
# It does not read debugfs or registers, reload modules, install anything,
# start systemd units or touch the network.
#
# Usage: bash av1-10bit-probe.sh            (full matrix, ~2-4 minutes)
#        WORK=/tmp/x FRAMES=5 bash av1-10bit-probe.sh
set -u

WORK=${WORK:-/tmp/av1probe}
BUILD=${BUILD:-/root/qva-av1test/build}
FRAMES=${FRAMES:-5}
ORIG=${ORIG:-/tmp/av1each}
CONTROL=/proc/dynamic_debug/control
SITE=iris_hfi_gen2_flush_debug_queue
RUN=$(date +%s)

if [ "$(id -u)" != 0 ]; then
	echo "run as root (dmesg, /dev/kmsg and $CONTROL need it)" >&2
	exit 1
fi
for tool in ffmpeg sha256sum dmesg timeout; do
	command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
DRIVER=$(find "$BUILD" -name v4l2_drv_video.so -print -quit 2>/dev/null)
if [ -z "$DRIVER" ]; then
	echo "v4l2_drv_video.so not found under $BUILD" >&2
	exit 1
fi
DRIVER_DIR=$(dirname "$DRIVER")
mkdir -p "$WORK"
SUMMARY=$WORK/summary.txt
: > "$SUMMARY"

say() {
	echo "$*" | tee -a "$SUMMARY"
}

# Firmware log on, restored on exit.
DDBG_WAS=""
if [ -w "$CONTROL" ]; then
	# Line format: <file>:<line> [<module>]<function> =<flags> "<format>"
	DDBG_WAS=$(grep -m1 "$SITE =" "$CONTROL" | sed -n 's/.* =\([^ ]*\) .*/\1/p')
	if echo "func $SITE +p" > "$CONTROL"; then
		say "dynamic_debug: $SITE +p (was =${DDBG_WAS:-unknown})"
	else
		say "dynamic_debug: could not enable $SITE; no firmware log this run"
	fi
else
	say "dynamic_debug: $CONTROL not writable; no firmware log this run"
fi
restore() {
	if [ -w "$CONTROL" ]; then
		case "$DDBG_WAS" in
		*p*) ;;
		*) echo "func $SITE -p" > "$CONTROL" 2>/dev/null ;;
		esac
	fi
}
trap restore EXIT

say "kernel: $(uname -r)"
say "driver: $DRIVER_DIR"
say "ffmpeg: $(ffmpeg -nostdin -hide_banner -version 2>/dev/null | head -n 1)"
say "libaom: $(dpkg-query -W 'libaom*' 2>/dev/null | tr '\t\n' '= ')"
say ""

# The decode command mirrors tests/decoder/av1.py (v1.1.1), minus the dump.
decode() {
	local ivf=$1 ffraw=$2 out=$3 log=$4
	local unset_args=(-u LD_PRELOAD)
	local name
	for name in $(compgen -e | grep '^V4L2_TEST_'); do
		unset_args+=(-u "$name")
	done
	env "${unset_args[@]}" LIBVA_DRIVER_NAME=v4l2 LIBVA_DRIVERS_PATH="$DRIVER_DIR" \
		IRIS_VAAPI_DEBUG=1 timeout 60 \
		ffmpeg -nostdin -hide_banner -v verbose -hwaccel vaapi \
		-hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
		-c:v av1 -i "$ivf" -vf "hwdownload,format=$ffraw" \
		-fps_mode passthrough -f rawvideo -y "$out" < /dev/null > "$log" 2>&1
}

superblock() {
	ffmpeg -nostdin -hide_banner -v info -i "$1" -c copy -bsf:v trace_headers -f null - 2>&1 |
		sed -n 's/.*use_128x128_superblock[^=]*= *\([01]\).*/\1/p' | head -n 1
}

# Run one decode between /dev/kmsg markers and report what the firmware said.
probe() {
	local name=$1 ivf=$2 depth=$3 predict=$4 ref=${5:-}
	local ffraw=nv12 log=$WORK/$name.ffmpeg.log out=$WORK/$name.raw
	local kmsg=$WORK/$name.kmsg rc sb errs attach match
	[ "$depth" = 10 ] && ffraw=p010le
	sb=$(superblock "$ivf")
	echo "av1probe $RUN: begin $name" > /dev/kmsg
	decode "$ivf" "$ffraw" "$out" "$log"
	rc=$?
	sleep 1
	echo "av1probe $RUN: end $name" > /dev/kmsg
	dmesg | sed -n "/av1probe $RUN: begin $name\$/,/av1probe $RUN: end $name\$/p" > "$kmsg"
	errs=$(grep -c 'session error' "$kmsg")
	attach=$(grep -E 'Attach Internal|insufficient memory|calculated|Start error|vDec_' "$kmsg" |
		head -n 4 | sed 's/^\[[^]]*\] //' | tr '\n' '|')
	match=n/a
	if [ -n "$ref" ] && [ -s "$out" ]; then
		if [ "$(sha256sum < "$out")" = "$(sha256sum < "$ref")" ]; then
			match=identical
		else
			match=DIFFERENT
		fi
	fi
	rm -f "$out"
	say "$(printf '%-18s sb128=%-2s exit=%-4s session_errors=%-4s dav1d=%-10s predict=%s' \
		"$name" "${sb:-?}" "$rc" "$errs" "$match" "$predict")"
	[ -n "$attach" ] && say "    firmware: $attach"
	grep -m 3 -E 'session error' "$kmsg" | sed 's/^/    kmsg: /' | tee -a "$SUMMARY"
	return 0
}

# name width height depth sb-size prediction-under-H1
# The 720p and 1080p SB128 10-bit rows are the ones the model says fail.
# 1080p SB64 vs SB128 holds everything else constant; 720p SB64 failing
# while 1080p SB64 passes rules out "128x128 superblocks alone break it".
MATRIX="
c720p8-sb64 1280 720 8 64 start-ok
c720p10-sb64 1280 720 10 64 START-FAIL
c720p10-sb128 1280 720 10 128 START-FAIL
c1080p8-sb128 1920 1080 8 128 start-ok
c1080p10-sb64 1920 1080 10 64 start-ok
c1080p10-sb128 1920 1080 10 128 START-FAIL
c1440p10-sb128 2560 1440 10 128 start-ok(thin)
"

say "== synthetic matrix (realtime, ${FRAMES} frames, lag 0, no hidden frames)"
echo "$MATRIX" | while read -r name w h depth sb predict; do
	[ -z "$name" ] && continue
	pix=yuv420p
	ffraw=nv12
	if [ "$depth" = 10 ]; then
		pix=yuv420p10le
		ffraw=p010le
	fi
	ivf=$WORK/$name.ivf
	ref=$WORK/$name.ref
	if ! ffmpeg -nostdin -hide_banner -v error -f lavfi \
		-i "testsrc2=size=${w}x${h}:rate=30,format=$pix" -frames:v "$FRAMES" \
		-c:v libaom-av1 -usage realtime -cpu-used 8 -crf 30 -b:v 0 -g 30 \
		-lag-in-frames 0 -row-mt 1 -threads 4 -aom-params "sb-size=$sb" \
		-f ivf -y "$ivf" > "$WORK/$name.encode.log" 2>&1; then
		say "$name: encode failed, see $WORK/$name.encode.log"
		continue
	fi
	if ! ffmpeg -nostdin -hide_banner -v error -c:v libdav1d -i "$ivf" -pix_fmt "$ffraw" \
		-f rawvideo -y "$ref" > "$WORK/$name.reference.log" 2>&1; then
		say "$name: dav1d reference failed, see $WORK/$name.reference.log"
		ref=""
	fi
	probe "$name" "$ivf" "$depth" "$predict" "$ref"
	rm -f "$ref"
done

say ""
say "== original av1.py streams, if still present under $ORIG (START only)"
for item in 1080p10:START-FAIL tiles10:START-FAIL still10:START-FAIL \
	4k10:start-ok 1080p10-lookahead:start-ok; do
	case_name=${item%%:*}
	ivf=$ORIG/$case_name/av1-$case_name.ivf
	if [ -f "$ivf" ]; then
		probe "orig-$case_name" "$ivf" 10 "${item#*:}"
	else
		say "orig-$case_name: $ivf not present, skipped"
	fi
done

say ""
say "Logs: $WORK/<case>.ffmpeg.log and $WORK/<case>.kmsg; summary: $SUMMARY"
