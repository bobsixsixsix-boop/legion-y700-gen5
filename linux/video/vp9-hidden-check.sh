#!/bin/bash
# Hidden VP9 frames through libva-v4l2, with injected faults: ROOT on the tablet.   bash vp9-hidden-check.sh [driver-dir]
# (driver-dir: an uninstalled build such as /usr/local/src/libva-v4l2/build; default the installed driver.)
# Why: libva-v4l2 submits a hidden VP9 frame (show_frame=0, an alt-ref) as a superframe "hidden frame + 1-byte
# show_existing_frame of the slot it refreshed" (src/vp9.cpp). Iris answers the hidden half with an empty NOSHOW buffer
# flagged V4L2_BUF_FLAG_ERROR, then the picture. Since kernel y14 (1051) that error buffer carries the picture's
# timestamp; local patch linux/video/libva-v4l2-patches/0001 takes it as the expected no-show buffer instead of graying
# the picture, and still grays a hidden picture when a further error buffer comes for it, when a later picture returns
# first, or (a client blocked in vaSyncSurface, e.g. Chrome's persistent exports) when the picture has not followed
# within 1 s. Upstream's board tests (decoder/error-recovery.py) cover only HEVC; this covers those VP9 paths.
# Clip: /root/iris-restart/vp9-p0.webm (made by linux/kernel-y7/vaapi-check.sh: 90 packets, 97 frames, 7 hidden).
# Shims: upstream's tests/decoder/error-completion.c (error buffers) and surface-storage.cpp (persistent exports,
# IRIS_TEST_STORAGE=export) from /usr/local/src/libva-v4l2, plus drop-picture.c below, which turns the n-th CAPTURE
# buffer of one token into an ignored empty buffer: "the picture never came".
# Cases (each: ffmpeg rc 0, no "timeout" in its log; "gray" = count of "replaced damaged picture"):
#   clean, clean-export        90 frames, gray 0; no-show buffers matched = hidden frames on y14 (1051), 0 on y13
#   error-hidden(-export)      error-completion on the first hidden token's CAPTURE buffers: gray 1
#   error-visible              the same on the next (visible) token: gray 1 (path unchanged by 0001)
#   drop-hidden(-export)       y14 only: the first hidden token's picture never comes: gray 1 (local: when the next
#                              picture returns; export: from the 1 s fallback, "no picture after no-show")
#   corrupt-arf(-export)       real firmware: the first hidden frame's data cut to half. Only rc 0 and no timeout are
#                              required (the firmware decides what it reports); gray / no-show counts are printed.
# On y13 (no 1051) the NOSHOW buffer has timestamp 0 and matches nothing: error-hidden then hits the picture's own
# buffer, which 0001 takes as the no-show one, so error-hidden(-export) exercise the "picture never came" paths there.
# Exit 1 on any FAIL. IRIS_VAAPI_DEBUG=1 is set for every run (counts come from its trace lines). Every run reads the
# frames back (hwdownload), as a player does: that calls vaSyncSurface, where surface-storage.so checks that a persistent
# surface kept its DMA-BUF ("verified persistent surface=" - with plain -f null FFmpeg never syncs and it prints nothing).
set -u
DRV=${1:-}; SRC=/usr/local/src/libva-v4l2/tests/decoder; CLIP=/root/iris-restart/vp9-p0.webm
u=user; uid=$(id -u $u)
kr=$(uname -r)
if [ -n "${LIBVA_EXPECT_ERRTS:-}" ]; then errts=$LIBVA_EXPECT_ERRTS
elif [[ $kr =~ -y([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -le 13 ]; then errts=0
else errts=1; fi
[ -s $CLIP ] || { echo "FAIL  missing $CLIP (run /root/vaapi-check.sh once, it generates it)"; exit 1; }
[ -z "$DRV" ] || [ -s "$DRV/v4l2_drv_video.so" ] || { echo "FAIL  no v4l2_drv_video.so in $DRV"; exit 1; }
T=$(mktemp -d /tmp/vp9-hidden.XXXXXX) || exit 1; trap 'rm -rf "$T"' EXIT; chmod 755 "$T"
cat >$T/drop-picture.c <<'C'
// IRIS_TEST_DROP_TOKEN=<token>, IRIS_TEST_DROP_NTH=<n, default 2>: the n-th CAPTURE buffer dequeued with that token
// comes back empty, unflagged and with timestamp 0, which libva-v4l2 ignores (and requeues): its picture never came.
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
[ $ok = 1 ] || { cat $T/cc.log; echo "FAIL  cannot build the shims"; exit 1; }
ffmpeg -v error -nostdin -i $CLIP -c:v copy -f ivf $T/clean.ivf || { echo "FAIL  cannot remux $CLIP"; exit 1; }
# hidden tokens (token = 1-based position among the frames FFmpeg hands to VA: superframes split, show_existing frames
# excluded - libva-v4l2's next_token_ starts at 1), and corrupt.ivf = the first hidden frame cut to half its size
python3 -I - $T/clean.ivf $T/corrupt.ivf >$T/info <<'PY' || { echo "FAIL  cannot parse $CLIP"; exit 1; }
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
echo "kernel $kr, error-timestamp patch expected: $errts; driver: ${DRV:-installed}; clip: $nh hidden frames (tokens $hidden); corrupt-arf: $corrupt"
fail=0
run() {   # run <case> <clip> [VAR=value ...]: decode as the desktop user, then set rc ms frames gray noshow nopic tmo
	local name=$1 in=$2; shift 2
	local e=(XDG_RUNTIME_DIR=/run/user/$uid IRIS_VAAPI_DEBUG=1)
	[ -z "$DRV" ] || e+=(LIBVA_DRIVER_NAME=v4l2 LIBVA_DRIVERS_PATH=$DRV)
	local t0=$(date +%s%N)
	runuser -u $u -- timeout 60 env "${e[@]}" "$@" ffmpeg -hide_banner -nostdin -hwaccel vaapi \
		-hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi -i $in -vf hwdownload,format=nv12 		-fps_mode passthrough -f null - >$T/$name.log 2>&1
	rc=$?; ms=$((($(date +%s%N) - t0) / 1000000))
	frames=$(grep -o 'frame= *[0-9]*' $T/$name.log | tail -1 | tr -dc 0-9)
	gray=$(grep -c 'replaced damaged picture' $T/$name.log); noshow=$(grep -c 'no-show CAPTURE' $T/$name.log)
	nopic=$(grep -c 'no picture after no-show' $T/$name.log); tmo=$(grep -ci timeout $T/$name.log)
	echo "  $name: rc $rc, ${ms} ms, frames ${frames:-?}, gray $gray, no-show matched $noshow, no-picture fallback $nopic, timeout lines $tmo"
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
if [ $errts = 1 ]; then expect clean "every hidden frame's no-show buffer matched ($noshow of $nh)" '[ $noshow = $nh ]'
else expect clean "no no-show buffer matched (timestamp 0 without 1051; $noshow)" '[ $noshow = 0 ]'; fi
run clean-export $T/clean.ivf "${X[@]}"
expect clean-export "rc 0, 90 frames, no gray, no timeout, persistent surfaces used" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 0 ] && [ $tmo = 0 ] && grep -q "verified persistent surface=" $T/clean-export.log'
run error-hidden $T/clean.ivf LD_PRELOAD=$T/error.so "${ERR[@]}" IRIS_TEST_ERROR_FIRST=$H
expect error-hidden "error buffers on hidden token $H: rc 0, 90 frames, exactly 1 gray, no timeout" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ]'
run error-hidden-export $T/clean.ivf LD_PRELOAD=$T/error.so:$T/storage.so IRIS_TEST_STORAGE=export "${ERR[@]}" IRIS_TEST_ERROR_FIRST=$H
expect error-hidden-export "the same with persistent exports: exactly 1 gray, no timeout" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ]'
run error-visible $T/clean.ivf LD_PRELOAD=$T/error.so "${ERR[@]}" IRIS_TEST_ERROR_FIRST=$((H + 1))
expect error-visible "error buffer on visible token $((H + 1)): rc 0, 90 frames, exactly 1 gray, no timeout" \
	'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ]'
if [ $errts = 1 ]; then
	run drop-hidden $T/clean.ivf LD_PRELOAD=$T/drop.so IRIS_TEST_DROP_TOKEN=$H
	expect drop-hidden "picture of hidden token $H never comes: rc 0, 90 frames, exactly 1 gray, no timeout" \
		'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $tmo = 0 ] && grep -q dropped $T/drop-hidden.log'
	run drop-hidden-export $T/clean.ivf LD_PRELOAD=$T/drop.so:$T/storage.so IRIS_TEST_STORAGE=export IRIS_TEST_DROP_TOKEN=$H
	expect drop-hidden-export "the same with persistent exports: 1 gray from the 1 s fallback, no timeout" \
		'[ $rc = 0 ] && [ "$frames" = 90 ] && [ $gray = 1 ] && [ $nopic = 1 ] && [ $tmo = 0 ]'
else echo "SKIP  drop-hidden(-export): needs the kernel error-timestamp patch (error-hidden covers these paths here)"; fi
run corrupt-arf $T/corrupt.ivf
expect corrupt-arf "real damaged hidden frame ($corrupt): rc 0, no timeout" '[ $rc = 0 ] && [ $tmo = 0 ]'
run corrupt-arf-export $T/corrupt.ivf "${X[@]}"
expect corrupt-arf-export "the same with persistent exports: rc 0, no timeout" '[ $rc = 0 ] && [ $tmo = 0 ]'
[ $fail = 0 ] && echo "vp9-hidden-check: PASS" || echo "vp9-hidden-check: FAIL"
exit $fail
