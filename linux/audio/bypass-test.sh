#!/bin/bash
# bypass-test.sh [pinned]: the real-device check of y700-speaker-guard's bypass protection (the 2026-10-14 review
# open item in the README). ROOT. Plays 6 s of digital silence straight to the raw hardware sink - the path that
# bypasses the protection chain - and logs every 100 ms where the stream sits and the amplifier attenuation
# (21 = normal, 159 = safe). Expected (guard of 2026-10-17): the stream is moved onto the Lenovo tuning sink
# ~0.3 s after it appears and the amplifiers stay at 21; with "pinned" (a stream that refuses to be moved) it
# stays on raw and the amplifiers sit at 159 until it ends. Owner-visible: one desktop notification; in the
# pinned case anything playing is ~13 dB quieter for those 6 s.
set -u
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus LC_ALL=C)
RAW=alsa_output.platform-sound.HiFi__Speaker__sink; TUNED=effect_input.y700_lenovo
W=/tmp/y700-bypass-silence.wav
ffmpeg -v error -y -f lavfi -i anullsrc=r=48000:cl=stereo -t 6 "$W" && chmod 644 "$W"
id_of() { "${U[@]}" pactl list short sinks | awk -v n="$1" '$2 == n {print $1}'; }
raw=$(id_of $RAW); tuned=$(id_of $TUNED)
gain() { amixer -c0 cget name=aw_dev_0_volume | sed -n 's/.*: values=//p'; }
echo "raw sink #$raw, tuned sink #$tuned, gain before $(gain)"
t0=$(date +%s.%N)
if [ "${1:-}" = pinned ]; then
	# a stream that refuses to be moved (node.dont-move): the guard must keep the amplifiers at 159 while it plays
	"${U[@]}" pw-play --target=$RAW -P '{ media.name = "y700-bypass-test" node.dont-move = true }' "$W" &
else
	"${U[@]}" paplay --device=$RAW --property=media.name=y700-bypass-test "$W" &
fi
P=$!
last=""
for i in $(seq 90); do
	s=$("${U[@]}" pactl list sink-inputs | awk '/^Sink Input #/ {sk = ""} /^\tSink:/ {sk = $2} /media.name = "y700-bypass-test"/ {print sk}')
	g=$(gain)
	now="sink=${s:--} gain=$g"
	[ "$now" != "$last" ] && printf '%6.2f s  %s%s\n' "$(echo "$(date +%s.%N) - $t0" | bc)" "$now" \
		"$([ "$s" = "$raw" ] && echo "  (raw: bypassing)"; [ "$s" = "$tuned" ] && echo "  (moved to tuned)")"
	last=$now
	sleep 0.1
done
wait $P 2>/dev/null
echo "gain after $(gain)"
rm -f "$W"
