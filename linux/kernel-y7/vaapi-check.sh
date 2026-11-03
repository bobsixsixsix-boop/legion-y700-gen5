#!/bin/bash
# VA-API decode through libva-v4l2 (qcom-va-driver from v1.1) as the desktop user: 8-bit H.264/HEVC test streams, a
# 10-bit HEVC clip, two VP9 clips (profile 0, and profile 2 = 10-bit; VP9 is what Chrome gets from YouTube) and a
# show_existing_frame variant of each VP9 clip (*-sef.ivf, below); plus an 8-bit AV1 Main clip when the driver lists
# VAProfileAV1Profile0 (AV1, below).
# Exits non-zero unless, for every stream:
#   - ffmpeg decodes it into VA-API surfaces (output stream "wrapped_avframe, vaapi", i.e. no software fallback) with
#     rc 0 and as many frames as libavcodec's software decoder gives (90; 97 for the -sef variants);
#   - CONTENT: the same hardware decode, also read back through hwdownload (a second ffmpeg output), is bit-identical
#     frame by frame (framemd5) to libavcodec's software decode in the same layout (nv12 / p010le; H.264, HEVC, VP9
#     and AV1 decoding is bit-exact by spec; AV1's reference is libdav1d). This sees VISIBLE damage: a neutral gray
#     substitute that is actually shown, a wrong, missing or extra frame;
#   - LOG: no suspicious line in ffmpeg's output: any "iris-vaapi:" line, or error / fail / timeout / damaged
#     (case-insensitive). No whitelist. With IRIS_VAAPI_DEBUG unset (enforced below) libva-v4l2 writes "iris-vaapi:"
#     lines only on an error, or (d5df780 on) when it replaces a damaged picture with a neutral gray frame
#     (src/decoder.cpp recover_picture) - that gray frame still counts as a decoded frame and ffmpeg's rc stays 0.
# Why both: a gray substitute on a HIDDEN VP9 frame (show_frame=0, an alt-ref) is not output by ffmpeg, so only the
# log line shows it - until a later show_existing_frame shows that slot: ffmpeg and Chrome then output the hidden
# frame's VA surface again without any VA call and without a new log line. The -sef clips insert exactly such frames
# (after every packet with a hidden frame, a 1-byte show_existing_frame of the slot it refreshed), so the content check
# sees them. Found 2026-10-23: kernel y14 (1051: iris keeps the timestamp on error buffers) + libva-v4l2 6d03c3f
# without linux/video/libva-v4l2-patches/retired/0001 gray every hidden frame (7 per VP9 clip here): Iris returns
# the hidden half of the superframe libva-v4l2 builds (src/vp9.cpp) as an empty NOSHOW buffer flagged ERROR, which
# now carries the picture's timestamp. On a failing VP9 clip the hidden-frame tokens are printed for comparison
# (token = 1-based position among the frames ffmpeg hands to VA-API, show_existing frames excluded; libva-v4l2
# counts from 1).
# Clean runs print no "iris-vaapi:" line (y13 + 6d03c3f, 2026-10-23). Until 2026-10-23 this script always exited 0.
# AV1 (qcom-va-driver v1.1 decodes AV1 Main 8/10-bit; 10-bit still fails in the y14 firmware on some streams, so only
# 8-bit is required here): checked only when vainfo, run with the same driver selection as the decodes, lists
# VAProfileAV1Profile0:VAEntrypointVLD - an older driver prints "AV1: not checked" and the stream count stays 7.
# av1-main-8bit.ivf = 3 s of 1080p30 testsrc2, libaom "good" with 25 frames of lookahead like av1.py's
# 1080p8-lookahead: 36 hidden frames (show_frame=0) and 30 show_existing_frame ones in 90 output frames, i.e. the
# hidden-reference path the kernel's NOSHOW recycling (0005 = our 1052) exists for. Those counts come from FFmpeg
# 9.0.2's libaom on Win11 (10-28); the tablet's libaom may differ, so the premise (at least one hidden frame, 90 output
# frames) is checked below. Generating it takes seconds on a PC, longer on the tablet. FFmpeg prefers libdav1d, so
# the hardware decode names the native decoder (-c:v av1, the only one with hwaccel) and the reference libdav1d.
# LIBVA_DRIVER_NAME / LIBVA_DRIVERS_PATH from the caller's environment are passed through (libva-v4l2-update.sh uses
# them to check an uninstalled build); without them libva picks the installed msm -> v4l2 driver.
# Streams: /root/iris-restart. The 8-bit H.264/HEVC ones (720p) come from linux/kernel-y6/iris-restart-run.sh; the
# 10-bit HEVC, VP9 and AV1 clips (1080p) and the -sef variants are generated below on first use and kept
# (chrome-vp9-check.sh reuses vp9-p0.webm and av1-main-8bit.ivf).
set -u
unset IRIS_VAAPI_DEBUG IRIS_VAAPI_DUMP
u=user; uid=$(id -u $u); D=/root/iris-restart; cd $D || exit 1
gen() {   # gen <file> <passes 1|2> <ffmpeg output options...>: make <file> once from 3 s of 1080p30 testsrc2. Encodes
	# to a temporary name first, so an interrupted encode cannot leave a short clip behind that would be taken as made.
	local f=$1 passes=$2 ok=1; shift 2
	[ -s "$f" ] && return 0
	echo "generating $D/$f"
	local src=(-v error -nostdin -y -f lavfi -i testsrc2=s=1920x1080:r=30 -t 3)
	if [ "$passes" = 2 ]; then
		nice -n 10 ffmpeg "${src[@]}" "$@" -pass 1 -passlogfile ".new-$f" -f null - \
			&& nice -n 10 ffmpeg "${src[@]}" "$@" -pass 2 -passlogfile ".new-$f" ".new-$f" || ok=0
	else nice -n 10 ffmpeg "${src[@]}" "$@" ".new-$f" || ok=0; fi
	rm -f ".new-$f"-*.log
	if [ $ok = 1 ]; then mv -f ".new-$f" "$f"; else rm -f ".new-$f"; echo "vaapi-check: FAIL (cannot generate $D/$f)"; exit 1; fi
}
# <in.ivf> <out.ivf>: after every packet whose superframe holds a hidden frame, insert a 1-byte show_existing_frame of
# a slot that hidden frame refreshed (and no later frame of the packet overwrote); pts renumbered 0, 1, 2, ... @30 fps
SEF_PY=$(cat <<'PY'
import struct, sys
def frames_of(pkt):
    b = pkt[-1]
    if b & 0xE0 == 0xC0:
        n, mag = (b & 7) + 1, ((b >> 3) & 3) + 1
        size = 2 + mag * n
        if len(pkt) >= size and pkt[-size] == b:
            out, pos = [], 0
            for i in range(n):
                off = len(pkt) - size + 1 + i * mag
                sz = int.from_bytes(pkt[off:off + mag], 'little')
                out.append(pkt[pos:pos + sz]); pos += sz
            return out
    return [pkt]
def header(f):
    pos = 0
    def bit():
        nonlocal pos
        v = (f[pos // 8] >> (7 - pos % 8)) & 1; pos += 1; return v
    def bits(n):
        v = 0
        for _ in range(n): v = (v << 1) | bit()
        return v
    assert bits(2) == 2
    low = bit(); profile = (bit() << 1) | low
    if profile == 3: bit()
    if bit(): return dict(sef=True, show=1, refresh=0)
    ftype, show, er = bit(), bit(), bit()
    if ftype == 0: return dict(sef=False, show=show, refresh=0xFF)
    intra = bit() if not show else 0
    if not er: bits(2)
    if intra:
        assert bits(24) == 0x498342
        if profile > 0:
            bit(); assert bits(3) != 7; bit()
    return dict(sef=False, show=show, refresh=bits(8))
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'DKIF'
hl = struct.unpack_from('<H', d, 6)[0]
hdr = bytearray(d[:hl])
struct.pack_into('<II', hdr, 16, 30, 1)
pkts, pos = [], hl
while pos + 12 <= len(d):
    sz = struct.unpack_from('<I', d, pos)[0]; pos += 12
    pkts.append(d[pos:pos + sz]); pos += sz
out = []
for p in pkts:
    out.append(p)
    hs = [header(f) for f in frames_of(p)]
    for k, h in enumerate(hs):
        if h['show'] or h['sef']:
            continue
        later = 0
        for h2 in hs[k + 1:]:
            later |= h2['refresh']
        free = h['refresh'] & ~later
        if free:
            out.append(bytes([(p[0] & 0xF0) | 0x08 | ((free & -free).bit_length() - 1)]))
            break
assert len(out) > len(pkts), 'no hidden frame to show'
struct.pack_into('<I', hdr, 24, len(out))
with open(sys.argv[2], 'wb') as o:
    o.write(hdr)
    for n, p in enumerate(out):
        o.write(struct.pack('<Iq', len(p), n)); o.write(p)
PY
)
gen_sef() {   # gen_sef <out.ivf> <in.webm>
	local f=$1
	[ -s "$f" ] && return 0
	echo "generating $D/$f"
	if ffmpeg -v error -nostdin -y -i "$2" -map 0:v:0 -c copy -f ivf ".new-$f.in" && python3 -I -c "$SEF_PY" ".new-$f.in" ".new-$f"
	then mv -f ".new-$f" "$f"; rm -f ".new-$f.in"
	else rm -f ".new-$f" ".new-$f.in"; echo "vaapi-check: FAIL (cannot generate $D/$f)"; exit 1; fi
}
vui=(-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv)
gen hevc-10bit.mp4 1 -pix_fmt yuv420p10le -c:v libx265 -x265-params log-level=error
# VP9 two-pass like YouTube's encodes: only two-pass "good" gives hidden alt-ref frames (superframes; 97 frames in 90
# packets here, one-pass gives none) - the VP9 feature a stateful decoder behind VA-API can trip over
vp9=(-c:v libvpx-vp9 -b:v 4M -deadline good -cpu-used 4 -row-mt 1)
gen vp9-p0.webm 2 "${vui[@]}" -pix_fmt yuv420p "${vp9[@]}" -profile:v 0
gen vp9-p2-10bit.webm 2 "${vui[@]}" -pix_fmt yuv420p10le "${vp9[@]}" -profile:v 2
gen_sef vp9-p0-sef.ivf vp9-p0.webm
gen_sef vp9-p2-10bit-sef.ivf vp9-p2-10bit.webm
S=(h264-poc0-vui.264 hevc-main-vui.265 hevc-10bit.mp4 vp9-p0.webm vp9-p2-10bit.webm vp9-p0-sef.ivf vp9-p2-10bit-sef.ivf)
E=(XDG_RUNTIME_DIR=/run/user/$uid)
if [ -n "${LIBVA_DRIVER_NAME:-}" ]; then E+=(LIBVA_DRIVER_NAME="$LIBVA_DRIVER_NAME"); fi
if [ -n "${LIBVA_DRIVERS_PATH:-}" ]; then E+=(LIBVA_DRIVERS_PATH="$LIBVA_DRIVERS_PATH"); fi
# AV1 (header): only when this driver lists it
if runuser -u $u -- env "${E[@]}" vainfo --display drm --device /dev/dri/renderD128 2>/dev/null \
	| grep -q 'VAProfileAV1Profile0[[:space:]]*:[[:space:]]*VAEntrypointVLD'; then
	gen av1-main-8bit.ivf 1 "${vui[@]}" -pix_fmt yuv420p -c:v libaom-av1 -usage good -cpu-used 8 -crf 30 -b:v 0 -g 30 \
		-lag-in-frames 25 -row-mt 1 -threads 4
	S+=(av1-main-8bit.ivf); av1="checked (av1-main-8bit.ivf)"
else av1="not checked (vainfo lists no VAProfileAV1Profile0:VAEntrypointVLD for this driver)"; fi
T=$(mktemp -d /tmp/vaapi-check.XXXXXX) || exit 1; trap 'rm -rf "$T"' EXIT
chmod 755 "$T"; cp -f "${S[@]}" "$T"/ || exit 1; chmod a+r "$T"/*
# decode from inside $T with bare file names: the random mktemp suffix never reaches ffmpeg's output and the grep below
cd "$T" || exit 1
if [ -n "${LIBVA_DRIVERS_PATH:-}" ]; then echo "driver: $LIBVA_DRIVERS_PATH/${LIBVA_DRIVER_NAME:-msm}_drv_video.so"
else echo "driver: installed (/usr/lib/aarch64-linux-gnu/dri/msm_drv_video.so -> v4l2_drv_video.so)"; fi
echo "AV1: $av1"
HW=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi)
# hdr_frames <file> <bitstream filters>: "H <token>" per hidden frame, "E <n>" per show_existing_frame (n = its
# 1-based output frame), "S <frames output>" last. trace_headers prints show_frame only for frames that are not
# show_existing ones - in VP9 (superframes split first) and in AV1 alike. A VP9 token is the driver's (one per frame
# handed to VA); for AV1 only the count of hidden frames is used.
hdr_frames() {
	ffmpeg -hide_banner -nostdin -i "$1" -map 0:v:0 -c copy -bsf:v "$2" -f null - 2>&1 \
		| tr -d '\r' | awk '{for (i = 1; i < NF; i++) {
			if ($i == "show_existing_frame" && $NF == 1) print "E", ++out
			if ($i == "show_frame") {++sent; if ($NF == 0) print "H", sent; else ++out}}}
			END {print "S", out + 0}'
}
gray() {   # gray <WxH> <nv12|p010le>: md5 of libva-v4l2's neutral frame (0x80 / 0x8000 everywhere, as error-recovery.py)
	python3 -I -c 'import hashlib, sys; w, h = map(int, sys.argv[1].split("x")); s = b"\x80" if sys.argv[2] == "nv12" else b"\x00\x80"; print(hashlib.md5(s * (w * h * 3 // 2)).hexdigest())' "$1" "$2"
}
md5s() { awk -F', *' '!/^#/ && NF >= 6 {print $NF}' "$1"; }
bad=0
for f in "${S[@]}"; do
	case $f in *10bit*) pf=p010le ;; *) pf=nv12 ;; esac
	hid=; sef=; want=90; dsw=(); dhw=()
	if [[ $f == vp9-* ]]; then
		vf=$(hdr_frames "$f" vp9_superframe_split,trace_headers)
		hid=$(awk '$1 == "H" {print $2}' <<<"$vf"); sef=$(awk '$1 == "E" {print $2}' <<<"$vf")
		want=$((90 + $(grep -c . <<<"$sef")))
		# the clips' premise (two-pass libvpx: hidden alt-refs; 90 frames + one per inserted show_existing_frame)
		if [ -z "$hid" ] || [ "$(awk '$1 == "S" {print $2}' <<<"$vf")" != "$want" ] || { [[ $f == *-sef.ivf ]] && [ -z "$sef" ]; }; then
			echo "$f: FAIL cannot read its VP9 frame headers (hidden: $(echo $hid); show_existing: $(echo $sef))"; bad=1; continue
		fi
	elif [[ $f == av1-* ]]; then
		dsw=(-c:v libdav1d); dhw=(-c:v av1)
		vf=$(hdr_frames "$f" trace_headers)
		hid=$(awk '$1 == "H" {print $2}' <<<"$vf"); sef=$(awk '$1 == "E" {print $2}' <<<"$vf")
		# the clip's premise (libaom lookahead: hidden references, shown again by show_existing_frame; 90 output frames)
		if [ -z "$hid" ] || [ "$(awk '$1 == "S" {print $2}' <<<"$vf")" != 90 ]; then
			echo "$f: FAIL cannot read its AV1 frame headers or it has no hidden frame (hidden: $(grep -c . <<<"$hid");" \
				"output frames: $(awk '$1 == "S" {print $2}' <<<"$vf"))"; bad=1; continue
		fi
	fi
	# software reference: libavcodec (AV1: libdav1d), same layout as the hwdownload below (yuv420p(10) -> nv12/p010le
	# repacks losslessly)
	ffmpeg -hide_banner -nostdin -v error "${dsw[@]}" -i "$f" -map 0:v:0 -vf format=$pf -fps_mode passthrough -f framemd5 - >sw.raw 2>/dev/null
	md5s sw.raw >sw.md5; nref=$(grep -c . sw.md5)
	# ONE hardware decode, two outputs: #0 null (the zero-copy path players use; its "wrapped_avframe, vaapi" proves VA
	# surfaces), #1 hwdownload -> framemd5 on stdout (root's shell opens hw.raw; a software fallback cannot pass
	# hwdownload). So every log line below belongs to the decode whose frames are compared.
	out=$(runuser -u $u -- env "${E[@]}" ffmpeg -hide_banner -nostdin "${HW[@]}" "${dhw[@]}" -i "$f" -map 0:v:0 -f null - \
		-map 0:v:0 -vf hwdownload,format=$pf -fps_mode passthrough -f framemd5 pipe:1 2>&1 >hw.raw); rc=$?
	out=$(printf '%s\n' "$out" | tr '\r' '\n')
	md5s hw.raw >hw.md5; nhw=$(grep -c . hw.md5)
	frames=$(echo "$out" | grep -o 'frame= *[0-9]*' | tail -1 | grep -o '[0-9]*$')
	sus=$(echo "$out" | grep -iE 'iris-vaapi:|error|fail|timeout|damaged'); nsus=$(grep -c . <<<"$sus")
	hw=$(echo "$out" | grep -c 'wrapped_avframe, vaapi')
	mism=$(paste -d' ' hw.md5 sw.md5 | awk '$1 != $2 {print NR}'); nmism=$(grep -c . <<<"$mism")
	g=$(gray "$(sed -n 's/^#dimensions 0: //p' sw.raw)" $pf)
	ngray=$(paste -d' ' hw.md5 sw.md5 | awk -v g="$g" '$1 != $2 && $1 == g' | grep -c .)
	echo "$f: frame=${frames:-0}/$nref, content $((nref - nmism))/$nref = software decode, $nsus suspicious lines, hw: $hw, rc $rc"
	ok=1
	[ "$rc" = 0 ] && [ "$hw" -ge 1 ] || ok=0
	[ "$nref" = "$want" ] && [ "${frames:-0}" = "$nref" ] && [ "$nhw" = "$nref" ] || ok=0
	[ "$nsus" = 0 ] && [ "$nmism" = 0 ] || ok=0
	if [ "$nmism" != 0 ]; then
		echo "    content differs from the software decode at output frame(s) $(echo $mism | cut -d' ' -f1-12) ($ngray of $nmism neutral gray)"
		[ -z "$sef" ] || echo "    the clip's show_existing frames are output frames $(echo $sef)"
	fi
	if [ "$nsus" != 0 ]; then echo "$sus" | head -8 | sed 's/^/    /'; fi
	if [ "$ok" = 0 ] && [ -n "$hid" ]; then
		if [[ $f == av1-* ]]; then echo "    AV1 hidden frames in this clip: $(grep -c . <<<"$hid")"
		else echo "    VP9 hidden-frame tokens of this clip: $(echo $hid)"; fi
	fi
	if [ "$rc" != 0 ] || [ "${frames:-0}" != "$nref" ]; then echo "$out" | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^/    /'; fi
	[ "$ok" = 1 ] || bad=1
done
if [ $bad = 0 ]; then echo "vaapi-check: PASS (${#S[@]} streams)"; else echo "vaapi-check: FAIL"; fi
exit $bad
