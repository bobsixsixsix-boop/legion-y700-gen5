#!/bin/bash
# Check the y700 libcamera build (autofocus + lens power) on the tablet: ROOT. Read-only, except that it runs cam
# (and with --pipewire one GStreamer client) as the desktop user `user`; item d writes frames to /dev/shm and deletes
# them at the end. Close every camera app first: a streaming camera is busy and its lens is legitimately powered.
#   bash libcamera-af-check.sh [--pipewire] [--no-sharpness]
# Env: CHECK_FRAMES=N (rear frames for b, default 180 = ~6 s at 30 fps)  CHECK_SIZE=WxH (the stream size of b, c and e,
#   default 1280x720; empty = the pipeline default, the full sensor size, slow on the CPU ISP, and no caps filter in
#   e - use it if e fails with not-negotiated)  LIBCAMERA_Y700_LENS_I2C (default 5-000c).
# Items, PASS/FAIL each (INFO and SKIP lines are not judged); the last line is RESULT: PASS|FAIL:
#   a  idle: the rear lens actuator (I2C 5-000c, dw9719 driver, GT9764 VCM) reaches runtime_status "suspended" within
#      5 s, nobody holds its v4l-subdev node open, and the vreg_l6b_2p8 regulator (found by name in
#      /sys/class/regulator; never debugfs) is disabled. A FAIL with pipewire/wireplumber holding the node means they
#      still run the stock libcamera: libcamera-af-install.sh --status, then restart them.
#   b  rear camera, cam --capture=$CHECK_FRAMES --metadata:
#      b1 AfState reaches Focused (2), else the states it went through are printed; b2 FocusAbsolute takes >= 2 values
#      (the lens moved); b3 the lens is runtime-active and the regulator enabled while streaming; b4 runtime-suspended
#      again <= 3 s after cam exits (expected ~1.1 s: the driver's 1 s autosuspend delay, then its ramp down to 0).
#      b4 alone does not prove patch 0005 (process exit closes the node with any libcamera): c2 and e do.
#   c  front camera (gc08a8, no lens), cam --capture=150 --metadata: c1 it streams and reports no AF metadata (the
#      AF patches as published reported AfMode/AfState/FocusAbsolute for lensless cameras too; 0005 stops that);
#      c2 the rear lens is suspended in every sample from 1.5 s after the first front frame (wall clock, seen in cam's
#      output) to the end, although cam's CameraManager enumerated the rear camera too, i.e. CameraLens::init() closed
#      the node again (patch 0005; the stock library keeps it open). The 1.5 s cover the driver's 1 s autosuspend
#      after that enumeration, which happens before the first frame, however slow cam is to start.
#   d  (python3-numpy installed and no --no-sharpness) a 640x480 BGR888 rear capture written as PPM to /dev/shm:
#      var(Laplacian)/mean^2 of the luma for the frames of the scan (before the first Focused) vs after the lock.
#      INFO only, it depends on the scene: point the camera at something with fine detail 20-50 cm away.
#   e  (--pipewire; needs gstreamer1.0-pipewire) the rear camera through PipeWire: gst-launch-1.0 pipewiresrc
#      target-object=<node> num-buffers=150 ! video/x-raw,<CHECK_SIZE> as user. After the client is gone and
#      WirePlumber suspends the node (a few seconds), the lens must be released and suspended within 15 s while
#      pipewire keeps running, i.e. SimplePipelineHandler::stopDevice() closed it in a long-lived process (patch 0005)
#      - the actual leak scenario.
# Raw cam output, libcamera logs and the 0.1 s runtime_status/regulator samples stay in /tmp/libcamera-af-check-<stamp>/.
set -uo pipefail
export LC_ALL=C.UTF-8
LENS_I2C=${LIBCAMERA_Y700_LENS_I2C:-5-000c}; REGNAME=vreg_l6b_2p8
RT=/sys/bus/i2c/devices/$LENS_I2C/power/runtime_status
REAR_MATCH=cci@941b000/i2c-bus@0/camera@56; FRONT_MATCH=cci@941d000/i2c-bus@1/camera@31
FRAMES=${CHECK_FRAMES:-180}; SIZE=${CHECK_SIZE-1280x720}
# the stream size for cam (b, c) and the caps filter for gst-launch-1.0 (e); none with CHECK_SIZE empty
sopt=(); gcaps=()
[ -z "$SIZE" ] || { sopt=(-s "role=viewfinder,width=${SIZE%x*},height=${SIZE#*x}");
	gcaps=('!' "video/x-raw,width=${SIZE%x*},height=${SIZE#*x}"); }
U=(runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000)
CAMENV=('LIBCAMERA_LOG_LEVELS=*:WARN,SimplePipeline:INFO')
pw=0; sharp=1
for a in "$@"; do
	case $a in
	--pipewire) pw=1 ;;
	--no-sharpness) sharp=0 ;;
	*) sed -n '2,5p' "$0"; exit 2 ;;
	esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
W=/tmp/libcamera-af-check-$(date +%Y%m%d-%H%M%S); mkdir -p "$W"
SPID=; SH=
cleanup() {
	[ -n "$SPID" ] && kill "$SPID" 2>/dev/null
	[ -n "$SH" ] && rm -rf "$SH"
	return 0
}
trap cleanup EXIT
results=(); fails=0
res() {
	printf '%-3s %-4s %s\n' "$1" "$2" "$3"
	results+=("$1:$2")
	[ "$2" = FAIL ] && fails=$((fails + 1))
	return 0
}

now() { date +%s.%N; }
plus() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", a + b }'; }
rt() { cat "$RT" 2>/dev/null || echo missing; }
LENS=
for d in /sys/class/video4linux/v4l-subdev*; do
	[ "$(basename "$(readlink -f "$d/device" 2>/dev/null)")" = "$LENS_I2C" ] && { LENS=/dev/${d##*/}; break; }
done
REG=
for d in /sys/class/regulator/regulator.*; do
	[ "$(cat "$d/name" 2>/dev/null)" = "$REGNAME" ] && { REG=$d; break; }
done
regstate() {
	local s=unknown
	[ -n "$REG" ] && s=$(cat "$REG/state" 2>/dev/null || echo unknown)
	echo "$s"
}
# the regulator's use count and consumer links (named <device>-<supply>), to tell a shared supply from a leak
consumers() {
	local l c=
	[ -n "$REG" ] || { echo "regulator not found"; return 0; }
	for l in "$REG"/*; do
		[ -L "$l" ] || continue
		case ${l##*/} in device|subsystem|supplier|of_node) ;; *) c="$c ${l##*/}" ;; esac
	done
	echo "num_users $(cat "$REG/num_users" 2>/dev/null || echo ?), consumers:${c:- none}"
}
# processes holding the lens node open, as "pid(comm) ..."
holders() {
	[ -n "$LENS" ] || return 0
	{ find /proc/[0-9]*/fd -lname "$LENS" 2>/dev/null || true; } | cut -d/ -f3 | sort -un |
		while read -r p; do printf '%s(%s) ' "$p" "$(cat /proc/$p/comm 2>/dev/null)"; done
	return 0
}
# poll runtime_status until "suspended" or $1 seconds; prints the seconds waited (or ">$1"), 0 if suspended
wait_suspended() {
	local t0 t
	t0=$(now)
	while :; do
		t=$(now)
		if [ "$(rt)" = suspended ]; then awk -v a="$t0" -v b="$t" 'BEGIN { printf "%.2f", b - a }'; return 0; fi
		if awk -v a="$t0" -v b="$t" -v l="$1" 'BEGIN { exit !(b - a > l) }'; then printf '>%s' "$1"; return 1; fi
		sleep 0.1
	done
}
# background sampler: "<time> <runtime_status> <regulator state>" every 0.1 s into $1
sampler_start() {
	( while :; do echo "$(now) $(rt) $(regstate)"; sleep 0.1; done ) > "$1" &
	SPID=$!
}
sampler_stop() {
	[ -n "$SPID" ] && { kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; }
	SPID=
	return 0
}
# samples of file $1 within [$2, $3]: "<n> <active> <suspended> <regulator enabled>"
window() {
	awk -v a="$2" -v b="$3" '$1 >= a && $1 <= b { n++; if ($2 == "active") act++; if ($2 == "suspended") sus++;
		if ($3 == "enabled") en++ } END { printf "%d %d %d %d\n", n, act, sus, en }' "$1"
}
# cam --metadata output -> "key value" lines
CAMAWK='
BEGIN { nm[0] = "Idle"; nm[1] = "Scanning"; nm[2] = "Focused"; nm[3] = "Failed"; last = -1; focused = -1 }
/ seq: [0-9]+ / {
	frames++; s = $0; sub(/.* seq: /, "", s); sub(/ .*/, "", s); seq = s + 0; t = $1 + 0
	if (frames == 1) t0 = t
	next
}
/^\tAfState = / {
	af++; st = $3 + 0
	if (st != last) { trans = trans " " seq ":" ((st in nm) ? nm[st] : st); last = st }
	if (st == 2 && focused < 0) { focused = seq; ft = t - t0 }
	next
}
/^\tFocusAbsolute = / {
	af++; p = $3 + 0
	if (!(p in seen)) { seen[p] = 1; npos++ }
	if (npos == 1 && minp == "") { minp = p; maxp = p }
	if (p < minp) minp = p
	if (p > maxp) maxp = p
	lastp = p
	next
}
/^\tAfMode = / { af++; next }
END {
	print "frames " frames + 0
	print "aflines " af + 0
	print "focused " focused
	print "focused_after " ((focused >= 0) ? sprintf("%.2f", ft) : "-")
	print "final " ((last >= 0) ? ((last in nm) ? nm[last] : last) : "none")
	print "npos " npos + 0
	print "range " ((npos > 0) ? minp ".." maxp : "-")
	print "lastpos " ((npos > 0) ? lastp : "-")
	print "trans" trans
}'
declare -A M
parse_cam() {
	local k v
	M=()
	while read -r k v; do M[$k]=$v; done < <(awk "$CAMAWK" "$1")
}
cam_error() { grep -m3 -iE 'error|fail|in use|acquire|busy' "$1" | paste -sd'|' | cut -c1-300; }

# ---- preflight
echo "libcamera0.7 $(dpkg-query -W -f='${Version}' libcamera0.7 2>/dev/null || echo '?'), cam $(command -v cam || echo MISSING)"
echo "lens node ${LENS:-NOT FOUND} (I2C $LENS_I2C), $REGNAME ${REG:-NOT FOUND}"
command -v cam >/dev/null || { res - FAIL "cam not installed (libcamera-tools)"; echo "RESULT: FAIL"; exit 1; }
old=$(grep -l 'libcamera\.so\.0\.7.* (deleted)' /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 |
	while read -r p; do printf '%s(%s) ' "$p" "$(cat /proc/$p/comm 2>/dev/null)"; done)
[ -z "$old" ] || echo "WARNING: still running a replaced libcamera: $old- restart them (libcamera-af-install.sh --restart-wireplumber)"
"${U[@]}" cam -l > "$W/cam-list.txt" 2> "$W/cam-list.err"
camidx() {
	awk -v m="$1" -v f="$2" 'index($0, m) || index($0, f) { split($0, x, ":"); gsub(/ /, "", x[1]); print x[1]; exit }' \
		"$W/cam-list.txt"
}
REAR=$(camidx "$REAR_MATCH" "Internal back camera"); FRONT=$(camidx "$FRONT_MATCH" "Internal front camera")
echo "cameras: rear ${REAR:-NOT FOUND}, front ${FRONT:-NOT FOUND} ($W/cam-list.txt)"

# ---- a. idle
echo "== a: idle"
h=$(holders)
s=$(wait_suspended 5); ok=$?
r=$(regstate)
if [ $ok -eq 0 ] && [ -z "$h" ] && [ "$r" = disabled ]; then
	res a PASS "runtime_status suspended (${s} s), node not held, $REGNAME $r"
else
	res a FAIL "runtime_status $(rt) (waited ${s} s), node held by: ${h:-nobody}, $REGNAME $r, $(consumers)"
fi

# ---- b. rear capture with metadata
echo "== b: rear camera ${REAR:-?}, $FRAMES frames${SIZE:+, $SIZE}, --metadata"
if [ -z "$REAR" ]; then
	res b FAIL "rear camera not in cam -l (see $W/cam-list.txt)"
else
	sampler_start "$W/b-samples.txt"
	t0=$(now)
	"${U[@]}" "${CAMENV[@]}" timeout -s INT 60 cam -c "$REAR" --capture="$FRAMES" --metadata "${sopt[@]}" \
		> "$W/b-cam.out" 2> "$W/b-cam.err"
	crc=$?
	t1=$(now)
	s=$(wait_suspended 5); sok=$?
	sampler_stop
	parse_cam "$W/b-cam.out"
	echo "    ${M[frames]} frames (cam rc $crc), AfState transitions (seq:state):${M[trans]:- none}"
	grep -m1 'Autofocus selected native position' "$W/b-cam.err" | sed 's/.*\(Autofocus selected\)/    log: \1/'
	if [ "${M[frames]}" -lt 30 ]; then
		res b FAIL "only ${M[frames]} frames: $(cam_error "$W/b-cam.err")"
	else
		if [ "${M[focused]}" -ge 0 ]; then
			res b1 PASS "AfState Focused from seq ${M[focused]} (${M[focused_after]} s after the first frame)"
		else
			res b1 FAIL "AfState never Focused, last ${M[final]} (no AfState at all = the stock libcamera)"
		fi
		if [ "${M[npos]}" -ge 2 ]; then
			res b2 PASS "FocusAbsolute took ${M[npos]} values in ${M[range]}, final ${M[lastpos]}"
		else
			res b2 FAIL "FocusAbsolute took ${M[npos]} value(s) (${M[range]})"
		fi
		read -r n act sus en < <(window "$W/b-samples.txt" "$(plus "$t0" 1.5)" "$t1")
		if [ "$n" -gt 0 ] && [ "$act" -gt 0 ] && [ "$en" -gt 0 ]; then
			res b3 PASS "while streaming: $act/$n samples active, regulator enabled in $en"
		else
			res b3 FAIL "while streaming: $act/$n samples active, regulator enabled in $en"
		fi
		if [ $sok -eq 0 ] && awk -v s="$s" 'BEGIN { exit !(s <= 3) }'; then
			res b4 PASS "suspended ${s} s after cam exited"
		else
			res b4 FAIL "not suspended ${s} s after cam exited ($(rt); held by: $(holders))"
		fi
	fi
fi

# ---- c. front camera
echo "== c: front camera ${FRONT:-?}, 150 frames${SIZE:+, $SIZE}, --metadata"
if [ -z "$FRONT" ]; then
	res c FAIL "front camera not in cam -l (see $W/cam-list.txt)"
else
	wait_suspended 5 >/dev/null
	sampler_start "$W/c-samples.txt"
	# the wall-clock time of the first frame line (cam flushes every frame line; its own timestamps are sensor time,
	# not comparable with the sampler's), then the lens holders 1.5 s later
	( for _ in $(seq 700); do
		if grep -q ' seq: ' "$W/c-cam.out" 2>/dev/null; then
			now > "$W/c-first.txt"; sleep 1.5; holders > "$W/c-holders.txt"; exit 0
		fi
		sleep 0.1
	done ) &
	wpid=$!
	"${U[@]}" "${CAMENV[@]}" timeout -s INT 60 cam -c "$FRONT" --capture=150 --metadata "${sopt[@]}" \
		> "$W/c-cam.out" 2> "$W/c-cam.err"
	crc=$?
	t1=$(now)
	sampler_stop
	[ -s "$W/c-first.txt" ] || kill "$wpid" 2>/dev/null
	wait "$wpid" 2>/dev/null
	parse_cam "$W/c-cam.out"
	if [ "${M[frames]}" -ge 135 ] && [ "${M[aflines]}" -eq 0 ]; then
		res c1 PASS "${M[frames]} frames, no AF metadata"
	else
		res c1 FAIL "${M[frames]} frames (cam rc $crc), ${M[aflines]} AF metadata lines: $(cam_error "$W/c-cam.err")"
	fi
	ff=$(cat "$W/c-first.txt" 2>/dev/null)
	if [ -z "$ff" ]; then
		res c2 INFO "no front frame seen, nothing to judge"
	else
		read -r n act sus en < <(window "$W/c-samples.txt" "$(plus "$ff" 1.5)" "$(plus "$t1" -0.3)")
		if [ "$n" -lt 3 ]; then
			res c2 INFO "front capture too short to judge ($n samples from 1.5 s after its first frame on)"
		elif [ "$sus" -eq "$n" ]; then
			res c2 PASS "rear lens suspended in all $n samples from 1.5 s after the first front frame on"
		else
			h=$(cat "$W/c-holders.txt" 2>/dev/null)
			res c2 FAIL "rear lens active in $act/$n samples from 1.5 s after the first front frame on; held then by: ${h:-nobody}"
		fi
	fi
fi

# ---- d. sharpness before/after the lock (INFO)
echo "== d: sharpness"
if [ $sharp = 0 ]; then
	res d SKIP "--no-sharpness"
elif ! python3 -c 'import numpy' 2>/dev/null; then
	res d SKIP "python3-numpy not installed"
elif [ -z "$REAR" ]; then
	res d SKIP "no rear camera"
else
	wait_suspended 5 >/dev/null
	SH=$(mktemp -d /dev/shm/libcamera-af-check.XXXXXX); chown user "$SH"; chmod 700 "$SH"
	"${U[@]}" "${CAMENV[@]}" timeout -s INT 60 cam -c "$REAR" --capture=150 --metadata \
		-s role=viewfinder,width=640,height=480,pixelformat=BGR888 --file="$SH/frame-#.ppm" \
		> "$W/d-cam.out" 2> "$W/d-cam.err"
	out=$(python3 - "$W/d-cam.out" "$SH" <<'PY'
import glob, re, sys
import numpy as np

out, d = sys.argv[1], sys.argv[2]
state, seq = {}, None
for line in open(out, errors="replace"):
    m = re.search(r" seq: (\d+) ", line)
    if m:
        seq = int(m.group(1))
    elif line.startswith("\tAfState = ") and seq is not None:
        state[seq] = int(line.split("=")[1])
lock = min((s for s, v in state.items() if v == 2), default=None)


def score(path):
    data = open(path, "rb").read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    w, h = int(m.group(1)), int(m.group(2))
    rgb = np.frombuffer(data, np.uint8, w * h * 3, m.end()).reshape(h, w, 3).astype(np.float32)
    g = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    lap = 4 * g[1:-1, 1:-1] - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
    return float(lap.var() / max(float(g.mean()), 1.0) ** 2 * 1e3)


frames = {}
for p in glob.glob(d + "/frame-*.ppm"):
    m = re.search(r"-(\d+)\.ppm$", p)
    if m:
        frames[int(m.group(1))] = p
if not frames:
    print("no PPM frames written")
elif lock is None:
    print("%d frames, AfState never Focused: nothing to compare" % len(frames))
else:
    before = [score(p) for s, p in sorted(frames.items()) if 8 <= s < lock]
    after = [score(p) for s, p in sorted(frames.items()) if s >= lock + 3]
    if not before or not after:
        print("lock at seq %d leaves %d frames before / %d after: nothing to compare" % (lock, len(before), len(after)))
    else:
        mb, xb, ma = float(np.median(before)), max(before), float(np.median(after))
        print("lock at seq %d; var(Laplacian)/mean^2 x1e3: scan median %.3f max %.3f (%d frames), "
              "locked median %.3f (%d frames); locked/scan-median %.2f, locked/scan-max %.2f"
              % (lock, mb, xb, len(before), ma, len(after), ma / mb if mb else 0, ma / xb if xb else 0))
PY
)
	rm -rf "$SH"; SH=
	res d INFO "${out:-analysis failed}"
fi

# ---- e. PipeWire round trip (opt-in)
if [ $pw = 1 ]; then
	echo "== e: rear camera through PipeWire"
	node=$("${U[@]}" pw-dump 2>/dev/null | python3 -c '
import json, sys
m = sys.argv[1]
alt = m.replace("/", "_").replace("@", "_")
for o in json.load(sys.stdin):
    if o.get("type") != "PipeWire:Interface:Node":
        continue
    p = (o.get("info") or {}).get("props") or {}
    vals = " ".join(str(v) for v in p.values())
    if p.get("media.class") == "Video/Source" and "libcamera" in vals and (m in vals or alt in vals):
        print(p.get("node.name", ""))
        break
' "$REAR_MATCH" 2>/dev/null)
	if ! "${U[@]}" gst-inspect-1.0 pipewiresrc >/dev/null 2>&1; then
		res e SKIP "GStreamer pipewiresrc missing (gstreamer1.0-pipewire)"
	elif [ -z "$node" ]; then
		res e SKIP "no PipeWire libcamera Video/Source node for $REAR_MATCH (pw-dump)"
	else
		wait_suspended 5 >/dev/null
		sampler_start "$W/e-samples.txt"
		"${U[@]}" timeout -s INT 60 gst-launch-1.0 -q pipewiresrc target-object="$node" num-buffers=150 "${gcaps[@]}" \
			! fakesink > "$W/e-gst.out" 2>&1 &
		gpid=$!
		sleep 3.5; during=$(holders)
		wait $gpid; grc=$?
		s=$(wait_suspended 15); sok=$?
		after=$(holders)
		sampler_stop
		pwp=$(pgrep -u user -x pipewire | paste -sd' ')
		echo "    node $node, gst rc $grc, lens held during the stream by: ${during:-nobody}"
		if [ $grc -ne 0 ]; then
			res e FAIL "gst-launch-1.0 failed (rc $grc): $(head -c 300 "$W/e-gst.out")"
		elif [ $sok -eq 0 ] && [ -z "$after" ] && [ -n "$pwp" ]; then
			res e PASS "lens suspended ${s} s after the client left, pipewire ($pwp) still running"
		else
			res e FAIL "lens $(rt) ${s} s after the client left, held by: ${after:-nobody}; pipewire: ${pwp:-not running}"
		fi
	fi
fi

if [ $fails -eq 0 ]; then
	echo "RESULT: PASS (${results[*]}); logs $W"
	exit 0
fi
echo "RESULT: FAIL ($fails FAIL: ${results[*]}); logs $W"
exit 1
