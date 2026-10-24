#!/bin/bash
# kprobe the iris HFI property traffic during one --restart run: what the driver sends vs what the firmware reports
T=/sys/kernel/tracing
cleanup() {
	echo 0 > $T/events/kprobes/enable 2>/dev/null
	echo '-:irisset' >> $T/kprobe_events 2>/dev/null; echo '-:irisprop' >> $T/kprobe_events 2>/dev/null
}
trap cleanup EXIT
cleanup
echo 'p:irisset iris_hfi_gen2_packet_session_property ptype=$arg2:x32 port=$arg4:x32 v0=+0($arg6):x32 v1=+4($arg6):x32' >> $T/kprobe_events
echo 'p:irisprop iris_hfi_gen2_handle_session_property type=+4($arg2):x32 port=+16($arg2):x32 v0=+32($arg2):x32 v1=+36($arg2):x32' >> $T/kprobe_events
for f in ${@:-h264-poc0.264}; do
	codec=h264; case $f in *.265) codec=hevc;; esac
	echo > $T/trace
	echo 1 > $T/events/kprobes/enable
	(cd /root/iris-restart && timeout 20 ./iris-restart-test /dev/video0 $codec 1280 720 $f --restart | grep -E "SOURCE|RESULT")
	echo 0 > $T/events/kprobes/enable
	grep -E "irisset|irisprop" $T/trace | grep -E "0x3000(103|105|107|108|109|10f|120|124|128|155)" |
		sed -E 's/^.*(irisset|irisprop): \([^)]*\) /\1 /' | awk '{
			n["0x3000103"]="RESOLUTION"; n["0x3000105"]="CROP"; n["0x3000107"]="PROFILE"; n["0x3000108"]="LEVEL";
			n["0x3000109"]="TIER"; n["0x300010f"]="BITDEPTH"; n["0x3000120"]="CODED_FRAMES"; n["0x3000124"]="MIN_OUT";
			n["0x3000128"]="POC"; n["0x3000155"]="COLOR"; t=$2; sub(/.*=/,"",t); print $1, n[t], $3, $4, $5 }'
done
