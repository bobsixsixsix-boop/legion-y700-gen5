#!/bin/bash
# chrome-vp9-check.sh: VP9 hidden frames through Chrome's own VA-API path (libva-v4l2 + local patch 0001), ROOT on the
# tablet, 2026-10-23. Run detached:  systemd-run --unit=y700-vp9chrome --collect -p StandardOutput=file:/root/X.log \
#   bash /root/chrome-vp9-check.sh     (not a y700-cx-* unit name: cx-auto would take it for an experiment and disarm)
# YT_URL=<watch page> picks the YouTube video (default below), YT_URL= (empty) skips the YouTube part. ONLY=webcodecs
# (or video, youtube, a comma list) runs only those parts. CHROME_EXTRA="<flags>" adds Chrome flags, for diagnosis only
# (e.g. --disable-accelerated-video-decode for a software <video>: the checks still expect hardware and FAIL).
# CHROME_ENV="VAR=value ..." adds environment to the test Chrome, also for diagnosis (e.g. LD_PRELOAD=<yuv709-shim .so>
# Y700_YUV709_DEBUG=1; the desktop entry's own env prefix, MESA_LOADER_DRIVER_OVERRIDE=zink, still wins over it).
# LIBVA_DRV=<a v4l2_drv_video.so> runs the test Chrome on that driver instead of the installed one (a copy in the temp
# dir, through LIBVA_DRIVERS_PATH; nothing installed is touched). The negative control:
#   LIBVA_DRV=/root/v4l2_drv_video.so.bak-20261023-035833-6d03c3f   (upstream 6d03c3f without 0001) must FAIL on y14.
#
# Why: 0001 was verified with FFmpeg (vp9-hidden-check.sh, vaapi-check.sh). Chrome drives VA-API itself (its own VP9
# parser; it submits a hidden frame as its own picture and shows a show_existing_frame by re-outputting that VA surface
# without a VA call) and keeps its surfaces exported (the sync-right-after-submit path that 0001's 1 s fallback is for).
# This checks the same thing in Chrome, without touching the screen or the owner's Chrome:
#   a throwaway headless KWin (virtual backend, its own runtime dir and D-Bus session) and a throwaway Chrome profile
#   on it, started with the owner's own desktop-entry command line (zink, the VA-API features) plus
#   --user-data-dir/--remote-debugging-port/--password-store=basic, with IRIS_VAAPI_DEBUG=1 (the driver's trace goes
#   to Chrome's stderr, which this sorts by test part). No sound (no PipeWire in that runtime dir). Chrome's own
#   background traffic is switched off (--disable-background-networking and friends; Chrome may still look things up
#   now and then), the clips come from a local http.server; only the YouTube part loads pages from the internet. The
#   Y700 video-state extension comes in through /usr/share/google-chrome/extensions (a local CRX; no-av1.js: YouTube
#   serves VP9, not AV1); its native host is not in the throwaway profile, so the panel's refresh rate is not touched.
#   Refuses to start while a power experiment / measurement unit (cx-auto's list) or a Chrome video power run is up.
# Parts (chrome-vp9-check.py does them over DevTools):
#   webcodecs  vp9-p0 / -sef / vp9-p2-10bit / -sef (IVF) decoded with WebCodecs twice, prefer-software (libvpx, the
#              reference) and prefer-hardware (VA-API: "supported" only when Chrome has a hardware decoder for it).
#              Every output frame is drawn to a 192x108 canvas: hardware vs software luma difference per frame,
#              neutral-gray frames (what libva-v4l2 puts in for a damaged picture). Frame-exact. 8-bit: the decoded Y
#              plane itself (VideoFrame.copyTo) against libvpx's: bit for bit, or - what Chrome 155 on this stack gives -
#              within 1 on every pixel of every 8th row once libvpx's frame is put through Chrome's readback: a hardware
#              frame is read back via RGB, YUV -> RGB with BT.601 although the frame is tagged BT.709, RGB -> YUV with
#              BT.709 (fitted 10-23: 0.3 mean / 1 max; every other 601/709 x limited/full combination leaves >= 3). So
#              the hardware frame holds libvpx's bytes. The BT.601 is Chrome's EGL hint; with yuv709-shim.c preloaded
#              (CHROME_ENV) the YUV -> RGB step is BT.709, so a BT.709 -> RGB -> BT.709 model is accepted too (the line
#              counts the frames each one explained). A 10-bit hardware frame is opaque to copyTo, so 10-bit relies
#              on the thumbnails: the per-frame difference (<= 6) only catches gray; a wrong picture that is not gray
#              (a hidden frame, a neighbour, a stale surface) is caught by the nearest-frame test: each hardware
#              thumbnail must be no farther (+0.5) from its own software frame than from the 2 on each side (testsrc2
#              moves every frame: a one-frame shift is flagged at every frame, the check line prints this reach).
#              The thumbnails are also compared with FFmpeg's own decode scaled the same way, converted with BT.709
#              (*.ref.rgb, the right one) and with BT.601 (*.ref601.rgb): printed, not judged. 10-23: software 1.9 / 4.6
#              abs, hardware 5.5 / 1.8 - Chrome draws the hardware frames with BT.601 (the ~3.8 hardware - software
#              thumbnail difference is that, not scaling); a gray frame differs by ~77.
#   video      vp9-p0.webm and the -sef clips remuxed to WebM in a <video> at 0.5x (from a blob: URL - python's
#              http.server answers no Range requests and Chrome makes such a resource unseekable);
#              requestVideoFrameCallback draws every presented frame; the Media domain names the decoder. Then paused
#              seeks, what a scrub does (flush, decode from the keyframe to the frame sought): to frames 20/45/70 of
#              vp9-p0.webm and to every show_existing frame of the -sef clips. Each must show the frame sought (by
#              content against FFmpeg's decode: within 0.5 of the closest frame), not gray, both as drawImage gives it
#              and as the compositor shows it (Page.captureScreenshot of the element: what goes to the screen); the
#              seeks get a trace window of their own. INFO line: the matrix of both. 10-23: on screen 5.4 / 1.7 - Chrome
#              shows hardware-decoded video with the BT.601 matrix (its EGL hint, README "视频硬解": Chrome 硬解画面按
#              BT.601 上色); with yuv709-shim.c 2.1 / 4.8, BT.709 like the software path (1.9 / 4.6).
#   youtube    a YouTube page (muted, 25 s, then 3 seeks of 8 s): decoder, served codec, gray frames, trace counts.
# PASS needs, per part: a platform (hardware) decoder; decoded tokens > 0; VP9 invisible references = the clip's hidden
# frames (parsed from its packets; 7 per clip); no-show CAPTURE = invisible references (every wrapped hidden frame got
# its NOSHOW buffer matched; on a kernel without iris 1051, y13 and older, no-show must be 0 instead - LIBVA_EXPECT_ERRTS
# =0|1 overrides the guess from uname -r); 0 "replaced damaged picture", 0 "no picture after no-show", 0 "discarding
# completed token", 0 "sync timeout"; no gray output frame; webcodecs: hardware frame count = software count, the
# per-frame thumbnail difference <= 6, the nearest-frame test and (8-bit) the Y planes as above; video: no show_existing
# frame unseen, the paused seeks as above (their trace: the same 4 lines 0, no-show = invisible); youtube: the gray hook drew at least half the frames decoded since it was set. Then, with Chrome gone,
# the whole log once more (what no part's window covered, Chrome's exit included): none of those 4 lines.
# YouTube unreachable / served AV1 = SKIP (not a FAIL); a YouTube video without hidden frames = SKIP of that claim.
# First an INFO line: what this Chrome says it decodes (canPlayType, MSE, mediaCapabilities; powerEfficient = hardware).
# 10-23 on y14: 45 PASS, 0 FAIL with the installed 2de1857 (6d03c3f + 0001); the negative control (6d03c3f, LIBVA_DRV
# above) FAILs 20 checks and the whole log: gray at exactly the show_existing frames (3/16/33/48/63/78/88, p2 93) in
# WebCodecs, <video> and the paused seeks to them, 7 "replaced" per clip, and on YouTube 226 "replaced" with 0 visible
# gray frames (hidden frames are never shown there). README "视频硬解", 「Chrome/YouTube 实测」.
# Logs of the last run: /root/chrome-vp9-check-last/ (summary.json, chrome.log.gz, kwin.log). Takes about 2-3 min.
set -u
U=user; P=9337; HP=8771
YT_URL=${YT_URL-https://www.youtube.com/watch?v=aqz-KE-bpKQ}
D=/root/iris-restart; H=$(cd "$(dirname "$0")" && pwd); PY=$H/chrome-vp9-check.py
DESK=/home/$U/.local/share/applications/google-chrome.desktop
LAST=/root/chrome-vp9-check-last
[ "$(id -u)" = 0 ] || { echo "FAIL run as root"; exit 2; }
[ -s "$PY" ] || { echo "FAIL missing $PY"; exit 2; }
LIBVA_DRV=${LIBVA_DRV:-}
[ -z "$LIBVA_DRV" ] || [ -s "$LIBVA_DRV" ] || { echo "FAIL LIBVA_DRV=$LIBVA_DRV does not exist"; exit 2; }
for f in vp9-p0.webm vp9-p0-sef.ivf vp9-p2-10bit.webm vp9-p2-10bit-sef.ivf; do
	[ -s $D/$f ] || { echo "FAIL missing $D/$f (run /root/vaapi-check.sh once, it generates the clips)"; exit 2; }
done
EXEC=$(sed -n 's/^Exec=//p' "$DESK" | head -1 | sed 's/ %[uU]$//')
case $EXEC in *google-chrome*) ;; *) echo "FAIL no Chrome Exec= line in $DESK"; exit 2 ;; esac
# not during a power experiment / measurement: the units cx-auto stands down for (the same list and the same
# /run/systemd/units/invocation:* test as linux/power/cx-auto/src/main.rs; a symlink there = the unit is up) and the
# Chrome video power runs (also while one waits for an idle screen). Fails closed when the list cannot be read.
[ -d /run/systemd/units ] || { echo "FAIL /run/systemd/units missing: cannot tell whether a measurement runs"; exit 3; }
busy=
for f in /run/systemd/units/invocation:*.service; do
	[ -L "$f" ] || [ -e "$f" ] || continue
	u=${f##*/invocation:}; u=${u%.service}
	case $u in
		y700-cx-auto|y700-cx-status*) ;;
		y700-cx-*|y700-offmeasure|y700-offbench|y700-l1ssbench|y700-powerbench|y700-wakeups|y700-standby-now) busy="$busy $u" ;;
	esac
done
pgrep -f 'chrome-video-power-ab' >/dev/null && busy="$busy chrome-video-power-ab"
[ -z "$busy" ] || { echo "FAIL a power experiment or measurement is running:$busy"; exit 3; }
for port in $P $HP; do
	ss -ltn | awk '{print $4}' | grep -q ":$port\$" && { echo "FAIL port $port in use"; exit 2; }
done

# the kernel's NOSHOW buffer: with iris 1051 (y14 on) it carries the hidden frame's timestamp (as vp9-hidden-check.sh)
kr=$(uname -r)
if [ -n "${LIBVA_EXPECT_ERRTS:-}" ]; then errts=$LIBVA_EXPECT_ERRTS
elif [[ $kr =~ -y([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -le 13 ]; then errts=0
else errts=1; fi

T=$(mktemp -d /tmp/y700-cvp9-XXXXXX) && [ -d "$T" ] || { echo "FAIL mktemp"; exit 2; }
mkdir -p "$T/run" "$T/home" "$T/kconfig" "$T/kdata" "$T/prof" "$T/www"
chmod 755 "$T"; chmod 700 "$T/run"
SOCK="y700-cvp9-$$"
BASE="HOME=$T/home PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 XDG_RUNTIME_DIR=$T/run"
HTTPD=
kwin_pid() { pgrep -u $U -f "^kwin_wayland --virtual .*--socket $SOCK\$"; }
stop_chrome() {
	pkill -u $U -f -- "--user-data-dir=$T/prof" 2>/dev/null
	for _ in $(seq 20); do pgrep -u $U -f -- "--user-data-dir=$T/prof" >/dev/null || break; sleep 0.5; done
	pkill -9 -u $U -f -- "--user-data-dir=$T/prof" 2>/dev/null
}
cleanup() {
	trap - EXIT
	stop_chrome
	[ -n "$HTTPD" ] && kill $HTTPD 2>/dev/null; pkill -u $U -f "http.server $HP --bind 127.0.0.1" 2>/dev/null
	k=$(kwin_pid); [ -n "$k" ] && { kill "$k" 2>/dev/null; sleep 1; kill -9 "$k" 2>/dev/null; }
	rm -rf $LAST; mkdir -p $LAST
	cp "$T/kwin.log" "$T/summary.json" $LAST/ 2>/dev/null
	[ -s "$T/chrome.log" ] && gzip -c "$T/chrome.log" > $LAST/chrome.log.gz
	rm -rf "$T"
}
trap cleanup EXIT

# 1. the clips: IVF for WebCodecs (the -sef ones are IVF already), WebM for <video> (the -sef ones remuxed: their
#    1-byte show_existing_frame packets stay packets of their own)
for f in vp9-p0 vp9-p2-10bit; do
	ffmpeg -v error -nostdin -y -i $D/$f.webm -map 0:v:0 -c copy -f ivf "$T/www/$f.ivf" &&
	cp $D/$f.webm "$T/www/$f.webm" && cp $D/$f-sef.ivf "$T/www/$f-sef.ivf" &&
	ffmpeg -v error -nostdin -y -i $D/$f-sef.ivf -map 0:v:0 -c copy -f webm "$T/www/$f-sef.webm" ||
		{ echo "FAIL cannot prepare $f clips"; exit 1; }
	# FFmpeg's own decode as 192x108 thumbnails, YUV -> RGB in BT.709 (*.ref.rgb, the right one) and in BT.601
	# (*.ref601.rgb); for a -sef clip it outputs the show_existing frames too (97; native vp9 = libvpx bit for bit, 10-23)
	for src in $D/$f.webm $D/$f-sef.ivf; do
		b=$(basename "${src%.*}")
		for m in 709 601; do
			ffmpeg -v error -nostdin -y -i "$src" -map 0:v:0 -an -fps_mode passthrough \
				-vf scale=192:108:flags=area:in_color_matrix=bt$m:in_range=tv:out_range=pc,format=rgb24 \
				-f rawvideo "$T/www/$b.ref${m/709/}.rgb" || { echo "FAIL cannot prepare $f clips"; exit 1; }
		done
	done
done
DRVENV=
if [ -n "$LIBVA_DRV" ]; then
	mkdir -p "$T/drv"; cp "$LIBVA_DRV" "$T/drv/v4l2_drv_video.so"
	DRVENV="LIBVA_DRIVERS_PATH=$T/drv LIBVA_DRIVER_NAME=v4l2"
	echo "      driver under test: $LIBVA_DRV (sha256 $(sha256sum "$LIBVA_DRV" | cut -c1-16)), not the installed one"
fi
echo '<!doctype html><meta charset=utf-8><title>vp9 check</title><body style="margin:0;background:#000"></body>' > "$T/www/index.html"
chown -R $U:$U "$T"
(cd "$T/www" && exec sudo -u $U python3 -m http.server $HP --bind 127.0.0.1 >/dev/null 2>&1) & HTTPD=$!

# 2. the test KWin (as in wiliwili-wayland-disconnect-test.sh). KDE_DEBUG=1: no KCrash handler restarting it.
sudo -u $U env -i $BASE XDG_CONFIG_HOME="$T/kconfig" XDG_DATA_HOME="$T/kdata" XDG_DATA_DIRS=/usr/local/share:/usr/share \
	KDE_DEBUG=1 timeout 600 dbus-run-session -- kwin_wayland --virtual --no-lockscreen --no-global-shortcuts \
	--width 1920 --height 1080 --socket "$SOCK" > "$T/kwin.log" 2>&1 &
i=0
while [ ! -S "$T/run/$SOCK" ]; do
	i=$((i + 1)); [ $i -gt 60 ] && { echo "FAIL test KWin did not create its socket within 15 s"; tail -n 3 "$T/kwin.log"; exit 1; }
	sleep 0.25
done

# 3. Chrome on it: the owner's command line + the test flags, the session's Vulkan ICD (zink runs on Turnip)
sudo -u $U env -i $BASE WAYLAND_DISPLAY="$SOCK" XDG_SESSION_TYPE=wayland XDG_CONFIG_HOME="$T/home/.config" \
	XDG_CACHE_HOME="$T/home/.cache" XDG_DATA_HOME="$T/home/.local/share" \
	VK_ICD_FILENAMES=/var/lib/tb323fu/mesa/icd/turnip.json VK_DRIVER_FILES=/var/lib/tb323fu/mesa/icd/turnip.json \
	IRIS_VAAPI_DEBUG=1 $DRVENV ${CHROME_ENV:-} timeout 540 dbus-run-session -- sh -c 'ulimit -c 0; exec '"$EXEC"' "$@"' chrome \
	--user-data-dir="$T/prof" --no-first-run --no-default-browser-check --password-store=basic --kiosk \
	--disable-background-networking --disable-component-update --disable-sync --no-pings --disable-domain-reliability \
	--autoplay-policy=no-user-gesture-required --remote-debugging-port=$P ${CHROME_EXTRA:-} "http://127.0.0.1:$HP/index.html" \
	> "$T/chrome.log" 2>&1 &

# 4. the tests
python3 -I "$PY" --port $P --http $HP --log "$T/chrome.log" --out "$T/summary.json" --errts $errts \
	${YT_URL:+--youtube "$YT_URL"} ${ONLY:+--only "$ONLY"}
rc=$?
# which VA driver file the test Chrome really has mapped (its GPU / video processes; Chrome is still up here)
maps=$(for p in $(pgrep -u $U -f -- "--user-data-dir=$T/prof"); do grep -o '/[^ ]*_drv_video\.so' /proc/$p/maps 2>/dev/null; done | sort -u)
echo "VA driver mapped by the test Chrome: ${maps:-none}"
case $maps in
	"") echo "FAIL the test Chrome has no VA driver mapped"; rc=1 ;;
	*"$T/drv/"*) [ -n "$LIBVA_DRV" ] || rc=1 ;;
	*) [ -z "$LIBVA_DRV" ] || { echo "FAIL LIBVA_DRV given but Chrome did not load it"; rc=1; } ;;
esac
# the whole trace, Chrome's exit included: the parts only see the bytes written while each ran
stop_chrome
all=$(grep -aoE 'decoded token=|no-show CAPTURE token=|VP9 invisible reference|replaced damaged picture|no picture after no-show|discarding completed token|sync timeout' \
	"$T/chrome.log" | sort | uniq -c | awk '{n = $1; $1 = ""; printf "%s%s %d", s, $0, n; s = ","}')
echo "whole Chrome log:${all:- no libva-v4l2 trace}"
if grep -aqE 'replaced damaged picture|no picture after no-show|discarding completed token|sync timeout' "$T/chrome.log"; then
	echo "FAIL  whole log: libva-v4l2 reported a damaged / missing picture or a sync timeout (see above)"; rc=1
elif ! grep -aq 'decoded token=' "$T/chrome.log"; then
	echo "FAIL  whole log: no libva-v4l2 trace at all (IRIS_VAAPI_DEBUG did not reach the driver?)"; rc=1
else echo "PASS  whole log: no damaged / missing picture, no sync timeout"; fi
echo "kernel $kr (errts $errts), installed libva-v4l2 $(cat /root/libva-v4l2.installed 2>/dev/null | head -1), installed driver sha256 $(sha256sum /usr/local/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so | cut -c1-16)"
echo "Chrome $(/opt/google/chrome/chrome --version 2>/dev/null | awk '{print $3}'); logs in $LAST/"
exit $rc
