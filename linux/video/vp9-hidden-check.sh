#!/bin/bash
# Hidden VP9 frames through the VA-API driver (qcom-va-driver, formerly libva-v4l2), with injected faults: ROOT on the
# tablet.   bash vp9-hidden-check.sh [driver-dir]
# (driver-dir: an uninstalled build such as /usr/local/src/libva-v4l2/build; default the installed driver.)
# Output contract (linux/kernel-y15's y15-verify.sh and libva-v4l2-update.sh read it): the FIRST line is exactly
#   vp9-hidden-check: mode=<gray|errts|recycle|unknown> kernel=<uname -r>
# the LAST line is exactly "vp9-hidden-check: PASS" or "vp9-hidden-check: FAIL", and the exit status is 0 / 1 with it.
# Why: the driver submits a hidden VP9 frame (show_frame=0, an alt-ref) as a superframe "hidden frame + 1-byte
# show_existing_frame of the slot it refreshed" (src/vp9.cpp). Iris (HFI gen2) decodes the hidden half into a NOSHOW
# picture, then the picture from the show_existing half, both under the superframe's timestamp. What userspace sees of
# the NOSHOW picture depends on the kernel - the NOSHOW mode:
#   gray     y13 and older: an empty CAPTURE buffer flagged V4L2_BUF_FLAG_ERROR with timestamp 0 (matches no picture)
#   errts    y14 (1051 = radxa patches/0004, error buffers keep their timestamp): the same buffer with the picture's
#            timestamp. A driver without a fix grays every hidden frame (6d03c3f 10-23, v1.1.1 10-28: 7 of 7 here);
#            local patch 0001 (now linux/video/libva-v4l2-patches/retired/) took it as the expected no-show buffer.
#   recycle  y15 on (1052 = radxa patches/0005): the kernel requeues a clean NOSHOW buffer itself; userspace sees only
#            the picture. A NOSHOW with a decode error still comes back empty + ERROR with its timestamp, and so does a
#            buffer the kernel failed to requeue. Upstream (v1.1.1) relies on this; 0001 is harmless there.
# Mode: IRIS_NOSHOW_MODE=gray|errts|recycle wins; else LIBVA_EXPECT_ERRTS=0|1 (the older switch) = gray|errts; else
# uname -r's -yN suffix (N <= 13 gray, 14 errts, >= 15 recycle); any other release FAILs and asks for IRIS_NOSHOW_MODE.
# Clip: /root/iris-restart/vp9-p0.webm (made by linux/kernel-y7/vaapi-check.sh: 90 packets, 97 frames, 7 hidden).
# Shims: upstream's tests/decoder/error-completion.c (error buffers) and surface-storage.cpp (persistent exports,
# IRIS_TEST_STORAGE=export) from /usr/local/src/libva-v4l2 (both unchanged in v1.1.1), plus drop-picture.c below, which
# turns the n-th CAPTURE buffer of one token into an ignored empty buffer: "the picture never came".
# Cases (each: ffmpeg rc 0, no "timeout" in its log; "gray" = count of "replaced damaged picture"; "empty" = CAPTURE
# buffers the driver traced with used=0 and without V4L2_BUF_FLAG_LAST):
#   clean, clean-export        90 frames, gray 0. errts: no-show buffers matched = hidden frames (needs 0001);
#                              gray: none matched; recycle: none matched and no empty CAPTURE buffer at all (the
#                              evidence that the kernel recycles NOSHOW buffers: gray mode also matches none, but
#                              there every hidden frame brings an empty buffer)
#   error-hidden(-export)      error-completion on the first hidden token's CAPTURE buffers: gray 1 in every mode. It
#                              hits the NOSHOW buffer and the picture on errts, the picture only on gray and recycle
#                              (0001 then takes that empty picture for the no-show buffer and grays it when the next
#                              picture returns or from its 1 s fallback; v1.1.1 grays it at once)
#   error-visible              the same on the next (visible) token: gray 1
#   drop-hidden(-export)       errts only: the first hidden token's picture never comes (2nd CAPTURE buffer of the
#                              token): gray 1 (0001: when the next picture returns; export: from the 1 s fallback,
#                              "no picture after no-show"). SKIP in gray mode (no matched no-show buffer to start from;
#                              error-hidden covers those paths there) and in recycle mode: the picture is then the
#                              token's only buffer, and a picture lost without any buffer is unrecoverable by design in
#                              every driver (0001's fallbacks start from a matched no-show buffer, v1.1.1 has none:
#                              the surface waits for the 5 s "surface sync timeout"). The kernel never does that in
#                              recycle mode (a failed requeue comes back as an ERROR buffer with the timestamp, which
#                              error-hidden covers). IRIS_VP9_DROP_PROBE=1 runs it anyway in recycle mode (1st buffer)
#                              and prints what happened, without a verdict.
#   corrupt-arf(-export)       real firmware: the first hidden frame's data cut to half. Only rc 0 and no timeout are
#                              required (the firmware decides what it reports); gray / no-show counts are printed.
# Expected to PASS in recycle mode with both 2de1857 (6d03c3f + 0001) and v1.1.1 (35eff37); in errts mode only with
# 0001; in gray mode with both.
# Exit 1 on any FAIL. IRIS_VAAPI_DEBUG=1 is set for every run (counts come from its trace lines). Every run reads the
# frames back (hwdownload), as a player does: that calls vaSyncSurface, where surface-storage.so checks that a persistent
# surface kept its DMA-BUF ("verified persistent surface=" - with plain -f null FFmpeg never syncs and it prints nothing).
set -u
DRV=${1:-}; SRC=/usr/local/src/libva-v4l2/tests/decoder; CLIP=/root/iris-restart/vp9-p0.webm
u=user; uid=$(id -u $u)
# ---- NOSHOW mode (the same block in libva-v4l2-update.sh, vp9-hidden-check.sh and chrome-vp9-check.sh)
noshow_mode() {   # sets kr, mode (gray|errts|recycle, else unknown and returns 1) and why
	local n
	kr=$(uname -r); mode=; why=
	if [ -n "${IRIS_NOSHOW_MODE:-}" ]; then mode=$IRIS_NOSHOW_MODE; why="IRIS_NOSHOW_MODE=$mode"
	elif [ -n "${LIBVA_EXPECT_ERRTS:-}" ]; then
		why="LIBVA_EXPECT_ERRTS=$LIBVA_EXPECT_ERRTS"
		case $LIBVA_EXPECT_ERRTS in 0) mode=gray ;; 1) mode=errts ;; esac
	elif [[ $kr =~ -y([0-9]+)$ ]]; then
		n=$((10#${BASH_REMATCH[1]})); why="$kr is y$n"
		if [ $n -le 13 ]; then mode=gray; elif [ $n -eq 14 ]; then mode=errts; else mode=recycle; fi
	else why="$kr has no -yN suffix"; fi
	case $mode in gray|errts|recycle) return 0 ;; esac
	mode=unknown; return 1
}
noshow_mode; mok=$?
echo "vp9-hidden-check: mode=$mode kernel=$kr"
die() { echo "FAIL  $*"; echo "vp9-hidden-check: FAIL"; exit 1; }
[ $mok = 0 ] || die "cannot tell the kernel's NOSHOW mode ($why): set IRIS_NOSHOW_MODE=gray|errts|recycle"
[ -s $CLIP ] || die "missing $CLIP (run /root/vaapi-check.sh once, it generates it)"
[ -z "$DRV" ] || [ -s "$DRV/v4l2_drv_video.so" ] || die "no v4l2_drv_video.so in $DRV"
for f in error-completion.c surface-storage.cpp; do
	[ -s $SRC/$f ] || die "missing $SRC/$f (upstream moved its test shims: update this script)"
done
T=$(mktemp -d /tmp/vp9-hidden.XXXXXX) || die "mktemp"
trap 'rm -rf "$T"' EXIT; chmod 755 "$T"
cat >$T/drop-picture.c <<'C'
// IRIS_TEST_DROP_TOKEN=<token>, IRIS_TEST_DROP_NTH=<n, default 2>: the n-th CAPTURE buffer dequeued with that token
// comes back empty, unflagged and with timestamp 0, which the driver ignores (and requeues): its picture never came.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <linux/videodev2.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
static int seen;
int ioctl(int fd, unsigned long request, ...) {
    va_list args;
    va_start(args, request);
    void *arg = va_arg(args, void *);
    va_end(args);
    int (*real_ioctl)(int, unsigned long, ...) = dlsym(RTLD_NEXT, "ioctl");
    int result = real_ioctl(fd, request, arg);
    const char *drop = getenv("IRIS_TEST_DROP_TOKEN"), *nth = getenv("IRIS_TEST_DROP_NTH");
    if (result || request != VIDIOC_DQBUF || !drop)
        return result;
    struct v4l2_buffer *buffer = arg;
    if (buffer->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
        return result;
    uint64_t token = (uint64_t)buffer->timestamp.tv_sec * 1000000 + buffer->timestamp.tv_usec;
    if (token != strtoull(drop, NULL, 10) || ++seen != (nth ? atoi(nth) : 2))
        return result;
    buffer->flags &= ~V4L2_BUF_FLAG_ERROR;
    buffer->m.planes[0].bytesused = 0;
    buffer->m.planes[0].data_offset = 0;
    buffer->timestamp = (struct timeval){0};
    fprintf(stderr, "dropped CAPTURE buffer %d of token=%llu\n", seen, (unsigned long long)token);
    return result;
}
C
ok=1
cc -Wall -Wextra -shared -fPIC $SRC/error-completion.c -ldl -o $T/error.so 2>$T/cc.log \
	&& c++ -Wall -Wextra -shared -fPIC $SRC/surface-storage.cpp -ldl -pthread -o $T/storage.so 2>>$T/cc.log \
	&& cc -Wall -Wextra -shared -fPIC $T/drop-picture.c -ldl -o $T/drop.so 2>>$T/cc.log || ok=0
[ $ok = 1 ] || { cat $T/cc.log; die "cannot build the shims"; }
ffmpeg -v error -nostdin -i $CLIP -c:v copy -f ivf $T/clean.ivf || die "cannot remux $CLIP"
# hidden tokens (token = 1-based position among the frames FFmpeg hands to VA: superframes split, show_existing frames
# excluded - the driver's next_token_ starts at 1), and corrupt.ivf = the first hidden frame cut to half its size
python3 -I - $T/clean.ivf $T/corrupt.ivf >$T/info <<'PY' || die "cannot parse $CLIP"
import struct, sys
def frames_of(pkt):
    b = pkt[-1]
    if b & 0xE0 == 0xC0:
        n, mag = (b & 7) + 1, ((b >> 3) & 3) + 1
        size = 2 + mag * n
        if len(pkt) >= size and pkt[-size] == b:
            sizes = [int.from_bytes(pkt[len(pkt) - size + 1 + i * mag:][:mag], 'little') for i in range(n)]
            out, pos = [], 0
            for s in sizes:
                out.append(pkt[pos:pos + s]); pos += s
            return out, mag
    return [pkt], 0
def kind(f):   # 'sef' (show_existing_frame), 'shown' or 'hidden'
    bits = ''.join(format(x, '08b') for x in f[:2])
    assert bits[:2] == '10'
    profile = int(bits[3] + bits[2], 2); i = 4 + (profile == 3)
    if bits[i] == '1': return 'sef'
    return 'shown' if bits[i + 2] == '1' else 'hidden'
data = open(sys.argv[1], 'rb').read()
out, pos, token, hidden, corrupt = [data[:32]], 32, 0, [], ''
while pos < len(data):
    size, pts = struct.unpack_from('<IQ', data, pos); pkt = data[pos + 12:pos + 12 + size]; pos += 12 + size
    frames, mag = frames_of(pkt)
    for i, f in enumerate(frames):
        if kind(f) == 'sef': continue
        token += 1
        if kind(f) == 'hidden':
            hidden.append(token)
            if not corrupt and mag:
                frames[i] = f[:len(f) // 2]
                n = len(frames); marker = 0xC0 | ((mag - 1) << 3) | (n - 1)
                index = bytes([marker]) + b''.join(len(x).to_bytes(mag, 'little') for x in frames) + bytes([marker])
                pkt = b''.join(frames) + index
                corrupt = f'token={token} bytes {len(f)}->{len(f) // 2}'
    out.append(struct.pack('<IQ', len(pkt), pts) + pkt)
open(sys.argv[2], 'wb').write(b''.join(out))
assert hidden and corrupt and hidden[0] + 1 not in hidden
print(' '.join(map(str, hidden))); print(hidden[0]); print(corrupt)
PY
{ read -r hidden; read -r H; read -r corrupt; } <$T/info
nh=$(wc -w <<<"$hidden")
chown -R $u $T; chmod a+r $T/*
echo "NOSHOW mode $mode ($why); driver: ${DRV:-installed}; clip: $nh hidden frames (tokens $hidden); corrupt-arf: $corrupt"
fail=0
run() {   # run <case> <clip> [VAR=value ...]: decode as the desktop user, then set rc ms frames gray noshow nopic empty tmo
	local name=$1 in=$2; shift 2
	local e=(XDG_RUNTIME_DIR=/run/user/$uid IRIS_VAAPI_DEBUG=1)
	[ -z "$DRV" ] || e+=(LIBVA_DRIVER_NAME=v4l2 LIBVA_DRIVERS_PATH=$DRV)
	local t0=$(date +%s%N)
	runuser -u $u -- timeout 60 env "${e[@]}" "$@" ffmpeg -hide_banner -nostdin -hwaccel vaapi \
		-hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi -i $in -vf hwdownload,format=nv12 \
		-fps_mode passthrough -f null - >$T/$name.log 2>&1
	rc=$?; ms=$((($(date +%s%N) - t0) / 1000000))
	frames=$(grep -o 'frame= *[0-9]*' $T/$name.log | tail -1 | tr -dc 0-9)
	gray=$(grep -c 'replaced damaged picture' $T/$name.log); noshow=$(grep -c 'no-show CAPTURE' $T/$name.log)
	nopic=$(grep -c 'no picture after no-show' $T/$name.log); tmo=$(grep -ci timeout $T/$name.log)
	empty=0; local f   # used=0 without V4L2_BUF_FLAG_LAST (0x100000: 0005 still returns an empty LAST at EOS / resolution change)
	for f in $(grep -oE 'CAPTURE index=[0-9]+ used=0 .* flags=[0-9a-f]+' $T/$name.log | sed 's/.*flags=//'); do
		(( (0x$f & 0x100000) == 0 )) && empty=$((empty + 1))
	done
	echo "  $name: rc $rc, ${ms} ms, frames ${frames:-?}, gray $gray, no-show matched $noshow, no-picture fallback $nopic, empty CAPTURE $empty, timeout lines $tmo"
}
expect() {   # expect <case> <description> <condition>
	if eval "$3"; then echo "PASS  $1: $2"; else echo "FAIL  $1: $2"; fail=1
		grep -E 'iris-vaapi: (replaced|completed damaged|no-show|no picture|sync timeout)|injected|dropped|rror|imeout' $T/$1.log | head -12 | sed 's/^/      /'
	fi
}
X=(LD_PRELOAD=$T/storage.so IRIS_TEST_STORAGE=export)
ERR=(IRIS_TEST_ERROR_QUEUE=capture IRIS_TEST_ERROR_COUNT=1)
run clean $T/clean.ivf
expect clean "rc 0, 90 frames, no gray, no timeout" '[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 0 ] && [ $tmo = 0 ]'
case $mode in
	errts) expect clean "every hidden frame's no-show buffer matched ($noshow of $nh)" '[ $noshow = $nh ]' ;;
	gray) expect clean "no no-show buffer matched (timestamp 0 without 1051; $noshow)" '[ $noshow = 0 ]' ;;
	recycle) expect clean "the kernel recycled every NOSHOW buffer: no empty CAPTURE buffer ($empty), no no-show matched ($noshow)" \
		'[ $empty = 0 ] && [ $noshow = 0 ]' ;;
esac
run clean-export $T/clean.ivf "${X[@]}"
expect clean-export "rc 0, 90 frames, no gray, no timeout, persistent surfaces used" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 0 ] && [ $tmo = 0 ] && grep -q "verified persistent surface=" $T/clean-export.log'
[ $mode != recycle ] || expect clean-export "no empty CAPTURE buffer ($empty), no no-show matched ($noshow)" '[ $empty = 0 ] && [ $noshow = 0 ]'
run error-hidden $T/clean.ivf LD_PRELOAD=$T/error.so "${ERR[@]}" IRIS_TEST_ERROR_FIRST=$H
expect error-hidden "error buffers on hidden token $H: rc 0, 90 frames, exactly 1 gray, no timeout" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ]'
run error-hidden-export $T/clean.ivf LD_PRELOAD=$T/error.so:$T/storage.so IRIS_TEST_STORAGE=export "${ERR[@]}" IRIS_TEST_ERROR_FIRST=$H
expect error-hidden-export "the same with persistent exports: exactly 1 gray, no timeout" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ]'
run error-visible $T/clean.ivf LD_PRELOAD=$T/error.so "${ERR[@]}" IRIS_TEST_ERROR_FIRST=$((H + 1))
expect error-visible "error buffer on visible token $((H + 1)): rc 0, 90 frames, exactly 1 gray, no timeout" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ]'
case $mode in
	errts)
		run drop-hidden $T/clean.ivf LD_PRELOAD=$T/drop.so IRIS_TEST_DROP_TOKEN=$H
		expect drop-hidden "picture of hidden token $H never comes: rc 0, 90 frames, exactly 1 gray, no timeout" \
			'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ] && grep -q dropped $T/drop-hidden.log'
		run drop-hidden-export $T/clean.ivf LD_PRELOAD=$T/drop.so:$T/storage.so IRIS_TEST_STORAGE=export IRIS_TEST_DROP_TOKEN=$H
		expect drop-hidden-export "the same with persistent exports: 1 gray from the 1 s fallback, no timeout" \
			'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $nopic = 1 ] && [ $tmo = 0 ]' ;;
	gray) echo "SKIP  drop-hidden(-export): needs the kernel error-timestamp patch (error-hidden covers these paths here)" ;;
	recycle)
		echo "SKIP  drop-hidden(-export): the kernel recycles NOSHOW buffers, a picture lost without any buffer is unrecoverable by design (header)"
		if [ "${IRIS_VP9_DROP_PROBE:-0}" = 1 ]; then
			run drop-hidden-probe $T/clean.ivf LD_PRELOAD=$T/drop.so IRIS_TEST_DROP_TOKEN=$H IRIS_TEST_DROP_NTH=1
			echo "INFO  drop-hidden-probe (no verdict): the only CAPTURE buffer of hidden token $H dropped:"
			grep -E 'dropped|iris-vaapi: (replaced|sync timeout|no picture)|imeout|rror' $T/drop-hidden-probe.log | head -8 | sed 's/^/      /'
		fi ;;
esac
run corrupt-arf $T/corrupt.ivf
expect corrupt-arf "real damaged hidden frame ($corrupt): rc 0, no timeout" '[ $rc = 0 ] && [ $tmo = 0 ]'
run corrupt-arf-export $T/corrupt.ivf "${X[@]}"
expect corrupt-arf-export "the same with persistent exports: rc 0, no timeout" '[ $rc = 0 ] && [ $tmo = 0 ]'
[ $fail = 0 ] && echo "vp9-hidden-check: PASS" || echo "vp9-hidden-check: FAIL"
exit $fail
