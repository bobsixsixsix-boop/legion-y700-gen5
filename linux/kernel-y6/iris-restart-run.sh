#!/bin/bash
# Build iris-restart-test, make the test streams once, run the matrix. Usage: iris-restart-run.sh [outdir]
# --restart on y5: every stream FAILs (the firmware raises the source change again after the bitstream port restart).
# With a BT.709 colour description (-vui, like real streaming encoders) only h264-poc2 and hevc-high should fail:
# those are the two properties ArmadaOS 1030/1031 fix. Without one, the driver also re-sends a colour info that does
# not match what the firmware reported (see README "内核 y6").
D=${1:-/root/iris-restart}; mkdir -p $D; cd $D
H=$(dirname "$(readlink -f "$0")")
gcc -O2 -Wall -o iris-restart-test "$H/iris-restart-test.c" || exit 2
src="-f lavfi -i testsrc2=s=1280x720:r=30 -t 3 -pix_fmt yuv420p"
# "-vui" streams carry a BT.709 colour description like every real streaming encoder (Steam, NVENC, Sunshine)
vui="-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv"
for v in "" -vui; do
	c=; [ -n "$v" ] && c=$vui
	[ -s h264-poc2$v.264 ] || ffmpeg -v error -y $src $c -c:v libx264 -bf 0 -g 30 -bsf:v h264_metadata=aud=insert -f h264 h264-poc2$v.264
	[ -s h264-poc0$v.264 ] || ffmpeg -v error -y $src $c -c:v libx264 -bf 2 -g 30 -bsf:v h264_metadata=aud=insert -f h264 h264-poc0$v.264
	[ -s hevc-main$v.265 ] || ffmpeg -v error -y $src $c -c:v libx265 -x265-params log-level=error:aud=1 -f hevc hevc-main$v.265
	[ -s hevc-high$v.265 ] || ffmpeg -v error -y $src $c -c:v libx265 -b:v 25M 		-x265-params log-level=error:aud=1:level-idc=4:high-tier=1:vbv-maxrate=25000:vbv-bufsize=25000 -f hevc hevc-high$v.265
done
echo "== stream headers"
for f in h264-poc2.264 h264-poc0.264 h264-poc2-vui.264; do
	echo "$f: pic_order_cnt_type = $(ffmpeg -hide_banner -i $f -c copy -bsf:v trace_headers -f null - 2>&1 | grep -m1 ' pic_order_cnt_type ' | awk '{print $NF}')" 		"colour_description_present_flag = $(ffmpeg -hide_banner -i $f -c copy -bsf:v trace_headers -f null - 2>&1 | grep -m1 ' colour_description_present_flag ' | awk '{print $NF}')"
done
for f in hevc-main.265 hevc-high.265 hevc-high-vui.265; do
	echo "$f: general_tier_flag = $(ffmpeg -hide_banner -i $f -c copy -bsf:v trace_headers -f null - 2>&1 | grep -m1 ' general_tier_flag ' | awk '{print $NF}')"
done
echo "== $(uname -r)"
for m in "" --restart; do
	for v in "" -vui; do
		for x in "h264 h264-poc2$v.264" "h264 h264-poc0$v.264" "hevc hevc-main$v.265" "hevc hevc-high$v.265"; do
			set -- $x
			timeout 60 ./iris-restart-test /dev/video0 $1 1280 720 $2 $m | tail -1 | sed "s|^|$2 ${m:-normal}: |"
		done
	done
done
dmesg | grep -i iris | tail -5
