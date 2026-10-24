#!/bin/bash
# pop-test-h3.sh: does the smoothed-volume tuning chain remove the zipper of a held volume key? (2026-10-16)
# ROOT via systemd-run, ~50 s, plays a quiet 440 Hz tone twice. A/B without touching the live chain:
#   A: tone -> the live effect_input.y700_lenovo, its volume stepped 50->85->50 % in 5 % steps every 40 ms
#   B: tone -> a temporary second instance of the SMOOTHED tuning chain (y700-lenovo-tuning.smooth-volume.conf.DRAFT,
#      nodes renamed effect_input/output.y700_smoothtest, log.level 2), same stepping, then the instance is stopped.
# Both chains feed effect_input.speakers (the protection chain). pop-analyze-h3.py compares the tone residual
# during the steps. All volumes are restored.
# Not in this repository: the tuning conf and its smoothed-volume draft (see linux/audio/README.md); /root/smooth.conf
# must be your own smoothed copy of your own tuning conf.
set -u
D=/root/pop-test-h3; mkdir -p $D; rm -f $D/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 LANG=C.UTF-8)
M=$D/markers.txt; mark() { echo "$(date +%s.%N) $*" >> $M; }
LIVE=effect_input.y700_lenovo; TEST=effect_input.y700_smoothtest
vol0=$("${U[@]}" pactl get-sink-volume $LIVE | grep -oE "[0-9]+%" | head -1)
sed -e 's/effect_input\.y700_lenovo/effect_input.y700_smoothtest/; s/effect_output\.y700_lenovo/effect_output.y700_smoothtest/' \
    -e 's/扬声器（联想调音）/smoothtest/g' -e 's/^\(\s*log\.level\s*=\s*\)0/\12/' /root/smooth.conf > $D/smoothtest.conf
python3 - <<'PY'
import math, struct, wave
w = wave.open("/root/pop-test-h3/tone.wav", "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
n = 12 * 48000; fr = bytearray()
for i in range(n):
    g = min(1, i / 4800, (n - i) / 4800)
    v = int(32767 * 0.06 * g * math.sin(2 * math.pi * 440 * i / 48000)); fr += struct.pack("<hh", v, v)
w.writeframes(bytes(fr)); w.close()
PY
chown -R user $D
REC=; TONE=; INST=
restore() { trap - EXIT; [ -n "$TONE" ] && kill $TONE 2>/dev/null; [ -n "$INST" ] && kill $INST 2>/dev/null
	"${U[@]}" pactl set-sink-volume $LIVE "$vol0"; [ -n "$REC" ] && kill -INT $REC 2>/dev/null; sleep 1
	echo "volume restored to $("${U[@]}" pactl get-sink-volume $LIVE | grep -oE '[0-9]+%' | head -1) (was $vol0); test instance $(pgrep -f smoothtest.conf >/dev/null && echo STILL RUNNING || echo gone)" > $D/log.txt; }
trap restore EXIT; trap 'exit 1' INT TERM
steps() {   # $1 = sink: 50 -> 85 -> 50 % in 5 % steps, 40 ms apart (a held volume key)
	for v in 55 60 65 70 75 80 85 80 75 70 65 60 55 50; do "${U[@]}" pactl set-sink-volume $1 $v%; sleep 0.04; done; }
"${U[@]}" pw-record --target alsa_input.platform-sound.HiFi__Mic__source --rate 48000 --channels 1 --format s16 $D/mic.wav & REC=$!
sleep 1; mark REC_STARTED
# A: live chain
"${U[@]}" pactl set-sink-volume $LIVE 50%
"${U[@]}" pw-play --target $LIVE $D/tone.wav & TONE=$!; mark A_TONE; sleep 4
mark A_STEPS; steps $LIVE; mark A_STEPS_END; sleep 4; wait $TONE; TONE=
"${U[@]}" pactl set-sink-volume $LIVE "$vol0"; sleep 2
# B: smoothed chain, temporary instance
"${U[@]}" pipewire -c $D/smoothtest.conf > $D/instance.log 2>&1 & INST=$!
for i in $(seq 40); do "${U[@]}" pactl list sinks short 2>/dev/null | grep -q $TEST && break; sleep 0.25; done
"${U[@]}" pactl list sinks short | grep -q $TEST || { echo "B: test sink did not appear" >> $D/log.txt; mark B_FAILED; exit 2; }
"${U[@]}" pactl set-sink-volume $TEST 50%; mark B_READY
"${U[@]}" pw-play --target $TEST $D/tone.wav & TONE=$!; mark B_TONE; sleep 4
mark B_STEPS; steps $TEST; mark B_STEPS_END; sleep 4; wait $TONE; TONE=
mark END
