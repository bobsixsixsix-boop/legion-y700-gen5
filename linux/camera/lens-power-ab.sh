#!/bin/bash
# lens-power-ab.sh [--idle MIN] [--until HH:MM] [--pairs N] [--settle S] [--secs S]: screen-off power with the rear
# lens actuator powered vs not, interleaved on one boot (2026-10-29, owner: "开始做熄屏功耗测试吧" after the libcamera
# lens fix; linux/camera/README.md "用法" step 6). ROOT, ON BATTERY, through systemd-run so no ssh session is open
# while it measures:
#   systemd-run --unit y700-lensab --collect /root/lens-power-ab.sh --idle 10 --until 09:30
# Deploy together (sha256 both ends): this file -> /root/; tools/y700-powersample.py -> /usr/local/libexec/ (the raw
# line is a 10-29 addition; checked at start); linux/power/cx-collapse/y700-cx-status -> /usr/local/libexec/ (the
# status page shows this log).
# A = the lens left alone. Since patch 0005 nobody holds its node: dw9719 (I2C 5-000c) is runtime suspended and
#     vreg_l6b_2p8 is off. This is the state after the 10-29 install.
# B = this script holds the lens's v4l-subdev node open with the focus control at 0. That is what the stock libcamera
#     did for the whole session before 10-29: CameraLens::init() opened the node and nothing moved the lens from the
#     control's default 0, so the driver chip and the LDO were on, the coil carried no current.
# Pairs alternate A B / B A (ABBA, so a linear drift cancels). Each window: switch, SETTLE s, then y700-powersample for
# SECS s (its usual line goes to the log; a raw line with the mean in mW and the per-second samples goes to the raw
# file once both windows of the pair counted). A window counts only if the display stayed off, no touch / power / volume key interrupt came, the rear sensor
# did not stream, the battery discharged at both ends and the lens / l6b state was the intended one before and after
# the sample, and at most SECS/10 gauge reads were exactly 0 (dropped reads, left out of the mean); a pair counts only
# with both windows. The owner using the tablet ends the pair (lens back to A at once);
# the pair is redone after the next IDLE minutes without input with the display off (as cx-when-idle.sh), until
# --until or --pairs.
# Deliberately not a cx-auto BENCHES name: cx-auto stays armed (E3a), the state a screen-off night is in every day.
# Touches nothing but the lens node: not the display, Wi-Fi, the CX knobs or PowerDevil. The focus control is left
# at 0 (libcamera sets its own position whenever a camera starts). On any exit the holder goes and the lens
# suspends about 1 s later. Status without ssh: curl http://100.64.0.10:8766/ (y700-cx-status shows this log).
set -u
LOG=/var/log/y700-lensab.txt
RAW=/var/log/y700-lensab-raw.tsv
PS=/usr/local/libexec/y700-powersample.py
LENS_I2C=5-000c; SENSOR_I2C=5-0056; REGNAME=vreg_l6b_2p8
IDLE=10; UNTIL=09:30; NPAIRS=0; SETTLE=30; SECS=120; MINCAP=20
while [ $# -gt 0 ]; do case $1 in
	--idle) IDLE=$2; shift 2 ;; --until) UNTIL=$2; shift 2 ;; --pairs) NPAIRS=$2; shift 2 ;;
	--settle) SETTLE=$2; shift 2 ;; --secs) SECS=$2; shift 2 ;;
	*) echo "usage: $0 [--idle MIN] [--until HH:MM] [--pairs N] [--settle S] [--secs S]" >&2; exit 2 ;; esac; done
T=/run/y700-lensab; mkdir -p "$T"; PAIRF=$T/pairs; : > "$PAIRF"
note() { echo "$(date +%T) $*" >> "$LOG"; }
RT=/sys/bus/i2c/devices/$LENS_I2C/power/runtime_status
SRT=/sys/bus/i2c/devices/$SENSOR_I2C/power/runtime_status
BAT=/sys/class/power_supply/qcom-battmgr-bat
LENS=; REG=
for d in /sys/class/video4linux/v4l-subdev*; do
	[ "$(basename "$(readlink -f "$d/device" 2>/dev/null)")" = "$LENS_I2C" ] && { LENS=/dev/${d##*/}; break; }
done
for d in /sys/class/regulator/regulator.*; do [ "$(cat "$d/name" 2>/dev/null)" = "$REGNAME" ] && { REG=$d; break; }; done
echo >> "$LOG"
echo "=== $(date '+%F %T') lens-power-ab: idle ${IDLE} min, until $UNTIL, pairs ${NPAIRS} (0 = no limit), settle ${SETTLE} s, sample ${SECS} s; $(uname -r), libcamera0.7 $(dpkg-query -W -f='${Version}' libcamera0.7 2>/dev/null), lens ${LENS:-?} ($LENS_I2C), ${REG:-?} ($REGNAME), $(cat $BAT/status) $(cat $BAT/capacity)%" >> "$LOG"
[ "$(id -u)" = 0 ] || { note "ABORT: not root"; exit 2; }
[ -n "$LENS" ] && [ -n "$REG" ] && [ -e "$RT" ] && [ -e "$SRT" ] && [ -x "$PS" ] && command -v v4l2-ctl >/dev/null ||
	{ note "ABORT: lens node / regulator / runtime_status / $PS / v4l2-ctl missing"; exit 2; }

inputs() { awk '$NF ~ /NVT-ts|pwrkey|resin|volume|gpio-keys/ {for (i = 2; i <= 9; i++) s += $i} END {print s + 0}' /proc/interrupts; }
dpms() { cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1; }
holders() {
	{ find /proc/[0-9]*/fd -lname "$LENS" 2>/dev/null || true; } | cut -d/ -f3 | sort -un |
		while read -r p; do printf '%s(%s) ' "$p" "$(cat /proc/$p/comm 2>/dev/null)"; done
}
state() { echo "lens $(cat "$RT") l6b $(cat "$REG/state") users $(cat "$REG/num_users") holders [$(holders)]"; }
# ok_state A|B: the lens / regulator are where the arm wants them
ok_state() {
	case $1 in
		A) [ "$(cat "$RT")" = suspended ] && [ "$(cat "$REG/state")" = disabled ] ;;
		B) [ "$(cat "$RT")" = active ] && [ "$(cat "$REG/state")" = enabled ] && [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null ;;
	esac
}
focus() { v4l2-ctl -d "$LENS" -C focus_absolute 2>/dev/null | awk -F': *' '{print $2}'; }

CHILD=; HOLDER=; PSPID=; IN0=
nap() { sleep "$1" & CHILD=$!; wait $CHILD; CHILD=; }
lens_on() { { [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; } || { sleep 7200 3<>"$LENS" & HOLDER=$!; }; }
lens_off() { [ -n "$HOLDER" ] && { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }; HOLDER=; }
# wait until the lens suspended (up to $1 s); 0 if it did
wait_lens_off() { local i=0; while [ $i -lt $(($1 * 4)) ]; do [ "$(cat "$RT")" = suspended ] && return 0; sleep 0.25; i=$((i + 1)); done; return 1; }

summary() {
	local med
	[ -s "$PAIRF" ] || { echo "no valid pair"; return 0; }
	med=$(awk '{print $3 - $2}' "$PAIRF" | sort -g | awk '{v[NR] = $1} END {print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2}')
	awk -v med="$med" '{d = $3 - $2; n++; s += d; ss += d * d; a += $2; b += $3}
		END {m = s / n; v = (n > 1) ? (ss - n * m * m) / (n - 1) : 0; sd = (v > 0) ? sqrt(v) : 0; se = sd / sqrt(n)
			printf "%d pairs: A %.1f mW, B %.1f mW, B-A mean %+.1f mW (sd %.1f, se %.1f, ~95%% %+.1f..%+.1f), median %+.1f mW", n, a / n, b / n, m, sd, se, m - 2 * se, m + 2 * se, med}' "$PAIRF"
}
cleanup() {
	trap - EXIT
	[ -n "$PSPID" ] && { kill "$PSPID" 2>/dev/null; wait "$PSPID" 2>/dev/null; }
	[ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
	lens_off
	# no focus read here: it would open the node and power the lens up once more
	wait_lens_off 5 && note "end: $(state); the focus control is left at 0 on purpose" ||
		note "WARN: lens not suspended 5 s after the end: $(state)"
	note "SUMMARY $(summary)"
	rm -rf "$T"
}
trap cleanup EXIT
trap 'note "stop requested"; exit 1' TERM INT

deadline=$(date -d "$UNTIL" +%s); [ "$deadline" -le "$(date +%s)" ] && deadline=$(date -d "tomorrow $UNTIL" +%s)
pairsecs=$((2 * (SETTLE + SECS + 15)))
time_left() { [ $(($(date +%s) + pairsecs)) -le "$deadline" ]; }
# battery capacity; a failed read (battmgr returns EAGAIN / ETIMEDOUT now and then) counts as "fine, look next time"
cap() { local c; c=$(cat $BAT/capacity 2>/dev/null); case $c in '' | *[!0-9]*) echo 100 ;; *) echo "$c" ;; esac; }

# the installed sampler must write the raw line (the 10-29 tools/y700-powersample.py); found now, not after 40 min
Y700_POWERSAMPLE_RAW=$T/pre "$PS" 1 preflight > /dev/null 2>&1
[ -n "$(awk -F'\t' 'NR == 1 && NF >= 6 {print $2}' "$T/pre" 2>/dev/null)" ] ||
	{ note "ABORT: $PS wrote no raw line - install the 10-29 tools/y700-powersample.py"; exit 2; }

# wait_idle: 0 once IDLE min passed with no input, the display off, on battery, the camera unused and the lens idle;
# 1 when the deadline would cut the next pair, 3 when the battery is low
wait_idle() {
	local last since now cur
	last=$(inputs); since=$(date +%s)
	while :; do
		time_left || return 1
		[ "$(cap)" -ge $MINCAP ] || return 3
		nap 30
		now=$(date +%s); cur=$(inputs)
		if [ "$cur" != "$last" ] || [ "$(dpms)" != Off ] || [ "$(cat $BAT/status)" != Discharging ] ||
			[ "$(cat "$SRT")" = active ] || [ "$(cat "$RT")" != suspended ]; then since=$now; last=$cur; continue; fi
		[ $((now - since)) -ge $((IDLE * 60)) ] && return 0
	done
}
# quiet: nothing happened since the pair started (input count $IN0, display off, rear sensor not streaming)
quiet() { [ "$(inputs)" = "$IN0" ] && [ "$(dpms)" = Off ] && [ "$(cat "$SRT")" != active ]; }
# naps $1 s in 10 s steps while quiet; 1 as soon as it is not
quiet_nap() { local left=$1 s; while [ "$left" -gt 0 ]; do s=$((left < 10 ? left : 10)); nap $s; left=$((left - s)); quiet || return 1; done; }

# window ARM K: 0 valid (mean mW in $MW), 1 the owner / charger / camera interrupted, 2 wrong lens state
window() {
	local arm=$1 k=$2 s0 s1 f lbl
	if [ "$arm" = B ]; then lens_on; else lens_off; fi
	quiet_nap "$SETTLE" || { note "p$k $arm: interrupted while settling"; return 1; }
	s0=$(state)
	ok_state "$arm" || { note "p$k $arm: wrong state before the sample: $s0"; return 2; }
	if [ "$arm" = B ]; then lbl="p$k B lens on"; else lbl="p$k A lens off"; fi
	: > "$T/raw"
	t0=$(date +%s)
	Y700_POWERSAMPLE_RAW=$T/raw "$PS" "$SECS" "$lbl" > "$T/line" 2>&1 & PSPID=$!
	while kill -0 $PSPID 2>/dev/null; do
		left=$((SECS + 1 - ($(date +%s) - t0)))           # the last nap ends ~1 s after the sample, not up to 10 s
		nap $((left > 10 ? 10 : (left > 1 ? left : 1)))
		kill -0 $PSPID 2>/dev/null || break
		quiet || { kill $PSPID 2>/dev/null; wait $PSPID 2>/dev/null; PSPID=; note "p$k $arm: interrupted while sampling"; return 1; }
	done
	wait $PSPID; PSPID=
	quiet || { note "p$k $arm: interrupted at the end of the sample"; return 1; }
	s1=$(state)
	ok_state "$arm" || { note "p$k $arm: wrong state after the sample: $s1"; return 2; }
	# the focus check comes after the sample (the holder keeps the node open, so the read changes nothing): before it,
	# only arm B would run a v4l2-ctl right as its sample starts
	if [ "$arm" = B ]; then f=$(focus); [ "$f" = 0 ] || { note "p$k B: focus_absolute is '$f', not 0"; return 2; }; fi
	[ "$(cat $BAT/status 2>/dev/null)" = Discharging ] || { note "p$k $arm: not discharging at the end"; return 1; }
	# the mean without exact-zero gauge reads (a dropped firmware read, exp-collect.sh / fr-slice R3 drop them too)
	MW=; NZ=0
	read -r MW NZ < <(awk -F'\t' 'NR == 1 && NF >= 6 {n = split($6, p, ","); for (i = 1; i <= n; i++) if (p[i] + 0 == 0) z++; else {s += p[i]; c++}
		if (c) printf "%.2f %d\n", s / c, z + 0}' "$T/raw") || true
	[ -n "$MW" ] || { note "p$k $arm: powersample gave no raw line: $(head -c 200 "$T/line")"; return 2; }
	[ "$NZ" -le $((SECS / 10)) ] || { note "p$k $arm: $NZ zero gauge reads - window dropped"; return 1; }
	[ "$NZ" = 0 ] || note "p$k $arm: $NZ zero gauge reads left out of the mean"
	cat "$T/line" >> "$LOG"; cat "$T/raw" >> "$T/pairraw"
	note "p$k $arm ok ($MW mW): $s1"
	return 0
}

k=0; bad=0; fresh=1
while [ "$NPAIRS" -eq 0 ] || [ "$k" -lt "$NPAIRS" ]; do
	# back to back pairs go on without a new idle wait as long as nothing happened since the session started
	if [ $fresh = 0 ] && { ! quiet || [ "$(cat $BAT/status)" != Discharging ] || [ "$(cat "$RT")" != suspended ]; }; then fresh=1; fi
	if [ $fresh = 0 ]; then
		time_left || { note "deadline $UNTIL: no time for another pair - stopping"; break; }
		[ "$(cap)" -ge $MINCAP ] || { note "battery below ${MINCAP}% - stopping"; break; }
	else
		wait_idle; rc=$?
		[ $rc = 1 ] && { note "deadline $UNTIL: no time for another pair - stopping"; break; }
		[ $rc = 3 ] && { note "battery below ${MINCAP}% - stopping"; break; }
		[ -z "$(holders)" ] || { note "someone holds the lens node: $(holders)- waiting"; continue; }
		# reading the control opens the node: the lens powers up for ~1 s (moving to the control's value) and goes
		# off again. Only here, after an idle wait: a camera used in between may have left another value.
		f=$(focus)
		if [ "$f" != 0 ]; then
			v4l2-ctl -d "$LENS" -c focus_absolute=0 2>> "$LOG"
			note "focus_absolute was '$f', set to $(focus)"
		fi
		wait_lens_off 5 || { note "lens not suspended after the focus read: $(state)"; continue; }
		IN0=$(inputs); fresh=0
		note "idle ${IDLE} min on battery, display off; cx-auto armed: $([ -e /run/y700-cx-auto.armed ] && echo yes || echo no); $(cat $BAT/capacity)%"
	fi
	if [ $((k % 2)) = 0 ]; then order="A B"; else order="B A"; fi
	ok=1; MA=; MB=; : > "$T/pairraw"
	for arm in $order; do
		window "$arm" "$k"; rc=$?
		if [ $rc = 0 ]; then [ "$arm" = A ] && MA=$MW || MB=$MW; continue; fi
		ok=0; fresh=1
		[ $rc = 2 ] && bad=$((bad + 1))
		break
	done
	# wait for the 1 s autosuspend after a pair that ended in B, or the check at the top of the loop sees the lens
	# still active and throws away the back-to-back run (review 10-29)
	lens_off
	wait_lens_off 5 || { note "lens not suspended 5 s after the pair: $(state)"; fresh=1; }
	if [ $ok = 1 ]; then
		bad=0
		cat "$T/pairraw" >> "$RAW"          # the raw file holds complete pairs only, in order
		echo "$k $MA $MB" >> "$PAIRF"
		note "PAIR $k: A $MA mW, B $MB mW, B-A $(awk -v a="$MA" -v b="$MB" 'BEGIN {printf "%+.1f", b - a}') mW | $(summary)"
		k=$((k + 1))
	elif [ $bad -ge 3 ]; then
		note "three pairs in a row with a wrong lens state - stopping"; exit 3
	fi
done
note "done"
