#!/bin/bash
# Verify the whole stack.  Note what is NOT here: no bare ffmpeg v4l2m2m decode.
# That invocation hangs the codec (uninterruptible, takes the machine with it).
# Usage: 90-verify.sh FILE...   (test clips of 60 s or more; the seek test walks ~25 s forward)
set -u
echo "== 1. the driver advertises the decode-order control (patch applied)? =="
v4l2-ctl -d /dev/video0 --list-ctrls 2>/dev/null | grep -iE 'display_delay' || echo "  MISSING - kernel patch not loaded"

echo "== 2. VA-API =="
vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -E 'Driver version|va_openDriver|VAProfile' | head -14

echo "== 3. hardware decode: every path the apps use, real output, plus seeking (what broke in wiliwili) =="
# mpv negotiates the buffers correctly (the ffmpeg CLI does not); files are given on the command line.
# vo=gpu on the real display: vo=null never exercised the VA-API surface export that stalled on seek.
# "Using hardware decoding" only proves the path was selected, not that it kept decoding: that is what
# the seek test below is for.
fail=0
for f in "$@"; do
  [ -f "$f" ] || continue
  for hw in vaapi vaapi-copy v4l2m2m-copy; do
    printf '  %-28s %-13s ' "$(basename "$f")" "$hw"
    if timeout -s KILL 90 mpv --no-config --ao=null --hwdec=$hw --length=4 --msg-level=all=v "$f" 2>&1 \
        | grep -q 'Using hardware decoding'; then echo "hardware ✓"; else echo "software/stall ✗"; fail=1; fi
  done
  # seek torture: 10 forward/back jumps over the IPC socket. Every seek must be acknowledged by mpv
  # (matching request_id, error "success") and playback must resume after it (time-pos advancing
  # between two reads 0.5 s apart). Any unanswered command, any stall, a killed or non-zero mpv fails
  # the test; the old version ignored the socket entirely and only looked at mpv's exit status.
  printf '  %-28s %-13s ' "$(basename "$f")" "seek x10"
  sock=$(mktemp -u /tmp/mpv-verify.XXXXXX)
  timeout -s KILL 120 mpv --no-config --ao=null --hwdec=vaapi-copy --keep-open=yes --input-ipc-server="$sock" "$f" >/dev/null 2>&1 &
  mpid=$!
  ipc() { printf '%s\n' "$1" | socat -T 2 - "UNIX-CONNECT:$sock" 2>/dev/null; }
  pos() { ipc '{"command":["get_property","time-pos"],"request_id":3}' | grep -o '"data":[0-9.]*' | cut -d: -f2; }
  reason=""
  for i in $(seq 40); do [ -n "$(pos)" ] && break; sleep 0.25; done
  [ -n "$(pos)" ] || reason="no playback position over IPC within 10 s"
  n=0
  while [ -z "$reason" ] && [ $n -lt 10 ]; do
    n=$((n + 1)); d=20; [ $((n % 2)) -eq 0 ] && d=-15
    rid=$((100 + n))
    r=$(ipc "{\"command\":[\"seek\",$d,\"relative\"],\"request_id\":$rid}")
    if ! { [[ $r == *"\"request_id\":$rid"* ]] && [[ $r == *'"error":"success"'* ]]; }; then
      reason="seek $n not acknowledged (${r:-no reply})"; break
    fi
    sleep 0.5; a=$(pos); sleep 0.5; b=$(pos)
    if [ -z "$a" ] || [ -z "$b" ] || ! awk -v a="$a" -v b="$b" 'BEGIN { exit !(b > a) }'; then
      reason="playback did not advance after seek $n (${a:-?} -> ${b:-?})"; break
    fi
  done
  ipc '{"command":["quit"]}' >/dev/null
  wait $mpid 2>/dev/null; rc=$?
  [ -n "$reason" ] || [ $rc -eq 0 ] || reason="mpv exit $rc"
  rm -f "$sock"
  if [ -z "$reason" ]; then echo "ok ✓ (10 seeks acknowledged, playback resumed after each)"; else echo "stalled/killed ✗ ($reason)"; fail=1; fi
done

echo "== 4. hardware encode (VA-API, H.264 / HEVC only - the silicon supports nothing else) =="
if timeout -s KILL 120 ffmpeg -hide_banner -loglevel error -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va \
     -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 4M -y /tmp/vaapi-encode-test.mp4; then
  ls -l /tmp/vaapi-encode-test.mp4
else
  echo "  encode failed"; fail=1
fi
exit $fail
