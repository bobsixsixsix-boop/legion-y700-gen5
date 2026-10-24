#!/bin/bash
# no-waitboost-ab.sh (2026-10-18) [SETTLE_S] [WIN_S] [MAXWAIT_S] [ROUNDS, e.g. "S O|O S"]: ROOT. Same-video A/B on the owner's live Chrome (loaded with the v2 y700-no-waitboost.so):
# waits for playing=1, then alternates the shim switch /run/user/1000/y700-no-waitboost.ctl between Y1 (hints dropped, "S")
# and Y0 (pass-through, "O"), windows ordered S O / O S / S O. Per window: power, GPU clock, boosts/s and deadlines/s
# (kprobes on msm_devfreq_boost / msm_fence_set_deadline, removed on exit), state-file flags. The switch is put back to its
# previous value at the end. y700-gpu-floor is stopped for the run and started again: since 10-18 22:31 it sets its 500 MHz
# fallback ceiling whenever the switch says Y0, which would cap the O windows (the 10-18 22:2x results had no ceiling).
# Log: /root/shim-toggle-ab.log. Run as a transient unit so the ssh session can end: systemd-run --unit=shim-toggle-ab --collect /root/no-waitboost-ab.sh 6 20 900
# Nothing else changes on the system (kprobes are removed on exit). Needs a video playing in the owner's Chrome (it waits for playing=1); do not run it during y700-gpu-floor's LIVE test.
# Counting note: kprobe_profile lists the event name WITHOUT its group, hence the unique event names nwb_boost / nwb_deadline.
SETTLE=${1:-6}; WIN=${2:-20}; MAXW=${3:-900}; ROUNDS=${4:-"S O|O S|S O"}
LOG=/root/shim-toggle-ab.log
CTL=/run/user/1000/y700-no-waitboost.ctl
TR=/sys/kernel/tracing; [ -d $TR/events ] || TR=/sys/kernel/debug/tracing
G=/sys/class/devfreq/3d00000.gpu; B=/sys/class/power_supply/qcom-battmgr-bat
ton0=$(cat $TR/tracing_on)
sw0=$(head -c 2 $CTL 2>/dev/null); case $sw0 in Y0|Y1) ;; *) sw0=Y1 ;; esac
gf0=$(systemctl is-active y700-gpu-floor 2>/dev/null)
cleanup() {
	printf %s "$sw0" | dd of=$CTL conv=notrunc status=none 2>/dev/null
	[ "$gf0" = active ] && systemctl start y700-gpu-floor
	echo 0 > $TR/events/y700shim/enable 2>/dev/null; echo "-:y700shim/nwb_boost" >> $TR/kprobe_events 2>/dev/null
	echo "-:y700shim/nwb_deadline" >> $TR/kprobe_events 2>/dev/null; echo $ton0 > $TR/tracing_on
}
trap cleanup EXIT
hits() { awk -v e="nwb_$1" '$1 == e {print $2}' $TR/kprobe_profile; }
say() { echo "$(date +%T) $*" | tee -a $LOG; }
playing() { grep -qh "^playing=1" /run/user/1000/y700-video/chrome-* 2>/dev/null; }
: > $LOG
[ -f $CTL ] || { say "no switch file $CTL (is Chrome running with the v2 shim?)"; exit 2; }
echo "p:y700shim/nwb_boost msm_devfreq_boost" >> $TR/kprobe_events
echo "p:y700shim/nwb_deadline msm_fence_set_deadline" >> $TR/kprobe_events
echo 0 > $TR/tracing_on; echo 1 > $TR/events/y700shim/enable
say "waiting up to ${MAXW}s for a playing video"
t=0
while [ $t -lt $MAXW ]; do playing && break; sleep 2; t=$((t + 2)); done
[ $t -ge $MAXW ] && { say "no video started playing"; exit 3; }
[ "$gf0" = active ] && systemctl stop y700-gpu-floor   # ExecStopPost gives its limits back
sleep 8
window() {
	local tag=$1 mode=$2
	if [ "$mode" = S ]; then printf Y1 | dd of=$CTL conv=notrunc status=none; else printf Y0 | dd of=$CTL conv=notrunc status=none; fi
	sleep $SETTLE
	playing || { say "$tag: video stopped, skipped"; return 1; }
	local s=0 f=0 i p b0 d0 b1 d1
	b0=$(hits boost); d0=$(hits deadline)
	for i in $(seq $WIN); do
		p=$(awk '{print ($1<0?-$1:$1)/1e6}' $B/power_now); s=$(awk -v a=$s -v b=$p 'BEGIN{print a+b}')
		f=$((f + $(cat $G/cur_freq) / 1000000)); sleep 1
	done
	b1=$(hits boost); d1=$(hits deadline)
	say "$tag ($mode): $(awk -v s=$s -v k=$WIN 'BEGIN{printf "%.2f W", s/k}'), GPU avg $((f / WIN)) MHz, boosts $(( (b1 - b0) / WIN ))/s, deadlines $(( (d1 - d0) / WIN ))/s, $(grep -h fullscreen /run/user/1000/y700-video/chrome-* | head -1), $(grep -h fps /run/user/1000/y700-video/chrome-* | head -1)"
}
i=0
IFS="|" read -ra RR <<< "$ROUNDS"
for order in "${RR[@]}"; do
	i=$((i + 1))
	for m in $order; do window "round $i" $m || break 2; done
done
say "done"
