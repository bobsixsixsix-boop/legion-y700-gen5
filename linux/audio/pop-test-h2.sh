#!/bin/bash
# pop-test-h2.sh: glitches while something plays (2026-10-16). ROOT via systemd-run, ~45 s, plays a quiet 440 Hz tone.
# A continuous tone stands in for a video; during it: three times a low-latency (256/48000, like the keyboard's
# click stream) silent stream joins for 3 s and leaves (graph quantum 1024 -> 256 -> 1024), and once the volume
# key is "held" (kglobalaccel increase_volume x8 then decrease_volume x8 at 40 ms; the sink volume is restored).
# pop-analyze-h2.py looks for transients in the recorded tone around each event.
set -u
LL_LAT=${LL_LAT:-256}   # latency of the joining stream: 256 (like the keyboard before) or "none" (no request: follows the graph)
D=/root/pop-test-h2; mkdir -p $D; rm -f $D/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 LANG=C.UTF-8)
M=$D/markers.txt; mark() { echo "$(date +%s.%N) $*" >> $M; }
gacc() { "${U[@]}" qdbus6 org.kde.kglobalaccel /component/kmix org.kde.kglobalaccel.Component.invokeShortcut "$1" >/dev/null 2>&1; }
vol0=$("${U[@]}" pactl get-sink-volume effect_input.y700_lenovo | grep -oE "[0-9]+%" | head -1)
python3 - <<'PY'
import math, struct, wave
w = wave.open("/root/pop-test-h2/tone.wav", "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
n = 42 * 48000; fr = bytearray()
for i in range(n):
    g = min(1, i / 4800, (n - i) / 4800)
    v = int(32767 * 0.06 * g * math.sin(2 * math.pi * 440 * i / 48000)); fr += struct.pack("<hh", v, v)
w.writeframes(bytes(fr)); w.close()
PY
cp /root/pop-test/silence.wav $D/; chown -R user $D
REC=; TONE=; LL=
restore() { trap - EXIT; for p in $LL $TONE; do kill $p 2>/dev/null; done; "${U[@]}" pactl set-sink-volume effect_input.y700_lenovo "$vol0"
	[ -n "$REC" ] && kill -INT $REC 2>/dev/null; sleep 1; echo "volume restored to $("${U[@]}" pactl get-sink-volume effect_input.y700_lenovo | grep -oE '[0-9]+%' | head -1) (was $vol0)" > $D/log.txt; }
trap restore EXIT; trap 'exit 1' INT TERM
"${U[@]}" pw-record --target alsa_input.platform-sound.HiFi__Mic__source --rate 48000 --channels 1 --format s16 $D/mic.wav & REC=$!
sleep 1; mark REC_STARTED
"${U[@]}" pw-play --target effect_input.y700_lenovo $D/tone.wav & TONE=$!; mark TONE_START; sleep 5
for c in 1 2 3; do
	mark LL${c}_JOIN
	if [ "$LL_LAT" = none ]; then "${U[@]}" pw-play --target effect_input.y700_lenovo $D/silence.wav & LL=$!
	else "${U[@]}" pw-play --latency=$LL_LAT --target effect_input.y700_lenovo $D/silence.wav & LL=$!; fi
	sleep 3
	kill $LL; LL=; mark LL${c}_LEAVE; sleep 3
done
mark VOL_HOLD; for i in $(seq 8); do gacc increase_volume; sleep 0.04; done; for i in $(seq 8); do gacc decrease_volume; sleep 0.04; done; mark VOL_END
"${U[@]}" pactl set-sink-volume effect_input.y700_lenovo "$vol0"; sleep 6
mark TONE_STOP; kill $TONE; TONE=; sleep 2; mark END
