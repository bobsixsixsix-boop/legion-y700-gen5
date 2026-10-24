#!/bin/bash
# pop-test-h1.sh: is the speaker path's power-up / power-down audible? (2026-10-16) ROOT via systemd-run, ~45 s.
# Three cycles of: a silent stream for 3 s (PCM open -> both aw882xx power up), stop, 8 s (WirePlumber suspends after
# 5 s -> PCM close -> both amps power down). Records the internal microphone; pop-analyze-h1 looks for transients at
# the same place in every cycle (a real power transient repeats; room noise does not). Nothing audible is played.
set -u
D=/root/pop-test-h1; mkdir -p $D; rm -f $D/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 LANG=C.UTF-8)
M=$D/markers.txt; mark() { echo "$(date +%s.%N) $*" >> $M; }
cp /root/pop-test/silence.wav $D/ && chown -R user $D
REC=; SIL=
restore() { trap - EXIT; [ -n "$SIL" ] && kill $SIL 2>/dev/null; [ -n "$REC" ] && kill -INT $REC 2>/dev/null; sleep 1; }
trap restore EXIT; trap 'exit 1' INT TERM
"${U[@]}" pw-record --target alsa_input.platform-sound.HiFi__Mic__source --rate 48000 --channels 1 --format s16 $D/mic.wav & REC=$!
sleep 1; mark REC_STARTED; sleep 8
for c in 1 2 3; do
	mark C${c}_OPEN; "${U[@]}" pw-play --target effect_input.y700_lenovo $D/silence.wav & SIL=$!; sleep 3
	kill $SIL; SIL=; mark C${c}_CLOSE; sleep 8
done
mark END
journalctl -k --since "-60s" -o short-unix -q | grep -E "start success|device_stop: done" > $D/amp.txt
