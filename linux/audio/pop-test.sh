#!/bin/bash
# pop-test.sh: automated speaker-pop test (2026-10-16). ROOT, through systemd-run; ~2.5 min; visible and audible:
# the display comes on, the keyboard pops up, the screen rotates once and back, a short tone plays twice.
# Records the internal microphone for the whole run and the aw882xx / PulseAudio timeline (pop-watch.sh), and
# writes wall-clock markers for every step; pop-analyze.py then finds click transients in the recording and
# maps them to the steps. Everything it changes (volume, rotation, display, keyboard) is put back at the end.
#   S1 reference: 150 ms tone after >= 8 s silence (amplifier power-up), then 9 s silence (power-down)
#   S2 keyboard pop-up without typing, 6 s, hide           (expect: no amplifier start since c73fd28)
#   S3 keyboard shown + rotation and back                   (expect: no amplifier start)
#   S4 volume key held: kglobalaccel increase_volume x10, decrease_volume x10 at 40 ms (expect: no feedback streams)
#   S5 tone again while a silent stream keeps the path running (pop-free reference for the tone itself)
set -u
D=/root/pop-test; mkdir -p $D; rm -f $D/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 LANG=C.UTF-8)
M=$D/markers.txt
mark() { echo "$(date +%s.%N) $*" >> $M; }
gacc() { "${U[@]}" qdbus6 org.kde.kglobalaccel /component/kmix org.kde.kglobalaccel.Component.invokeShortcut "$1" >/dev/null 2>&1; }
vol0=$("${U[@]}" pactl get-sink-volume effect_input.y700_lenovo | grep -oE "[0-9]+%" | head -1)
rot0=$("${U[@]}" kscreen-doctor -j 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["outputs"][0]["rotation"])')
dpms0=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)
case $rot0 in 1) R0=none; R1=left ;; 2) R0=left; R1=none ;; 4) R0=inverted; R1=right ;; *) R0=right; R1=none ;; esac
INH=; REC=; WATCH=; SIL=
restore() {
	trap - EXIT
	[ -n "$SIL" ] && kill $SIL 2>/dev/null
	"${U[@]}" y700-osk hide >/dev/null 2>&1
	"${U[@]}" kscreen-doctor output.DSI-1.rotation.$R0 >/dev/null 2>&1
	"${U[@]}" pactl set-sink-volume effect_input.y700_lenovo "$vol0"
	[ -n "$REC" ] && kill -INT $REC 2>/dev/null; sleep 1
	[ -n "$WATCH" ] && systemctl stop y700-pop-watch 2>/dev/null
	[ "$dpms0" = Off ] && "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
	[ -n "$INH" ] && { pkill -P $INH 2>/dev/null; kill $INH 2>/dev/null; }
	echo "restored: volume $("${U[@]}" pactl get-sink-volume effect_input.y700_lenovo | grep -oE '[0-9]+%' | head -1) (was $vol0), rotation $R0, dpms $dpms0" >> $D/log.txt
}
trap restore EXIT; trap 'exit 1' INT TERM
python3 - <<'PY'
import math, struct, wave
for name, secs, freq, amp in (("tone", 0.15, 2000, 0.25), ("silence", 40, 0, 0)):
    w = wave.open(f"/root/pop-test/{name}.wav", "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    n = int(secs * 48000); fade = 480
    fr = bytearray()
    for i in range(n):
        g = min(1, i / fade, (n - i) / fade) if freq else 0
        v = int(32767 * amp * g * math.sin(2 * math.pi * freq * i / 48000)); fr += struct.pack("<hh", v, v)
    w.writeframes(bytes(fr)); w.close()
PY
chown user /root/pop-test /root/pop-test/*.wav; chmod 755 /root /root/pop-test 2>/dev/null
"${U[@]}" kde-inhibit --power --screenSaver sleep 400 >/dev/null 2>&1 </dev/null & INH=$!
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
systemd-run --unit y700-pop-watch --collect bash /root/pop-watch.sh 170 >/dev/null 2>&1; WATCH=1
"${U[@]}" pw-record --target alsa_input.platform-sound.HiFi__Mic__source --rate 48000 --channels 1 --format s16 $D/mic.wav & REC=$!
sleep 1; mark REC_STARTED
echo "start $(date +%T) volume $vol0 rotation $rot0 ($R0) dpms $dpms0" > $D/log.txt
sleep 9                                   # >= 8 s of silence: speaker path suspended (5 s timeout)
mark S1_TONE; "${U[@]}" pw-play --target effect_input.y700_lenovo $D/tone.wav; mark S1_TONE_END
sleep 10                                  # power-down at ~5 s
mark S2_KBD_SHOW; "${U[@]}" y700-osk show >/dev/null 2>&1; sleep 6
mark S2_KBD_HIDE; "${U[@]}" y700-osk hide >/dev/null 2>&1; sleep 8
mark S3_KBD_SHOW; "${U[@]}" y700-osk show >/dev/null 2>&1; sleep 3
mark S3_ROTATE; "${U[@]}" kscreen-doctor output.DSI-1.rotation.$R1 >/dev/null 2>&1; sleep 5
mark S3_ROTATE_BACK; "${U[@]}" kscreen-doctor output.DSI-1.rotation.$R0 >/dev/null 2>&1; sleep 4
mark S3_KBD_HIDE; "${U[@]}" y700-osk hide >/dev/null 2>&1; sleep 8
mark S4_VOL_HOLD; for i in $(seq 10); do gacc increase_volume; sleep 0.04; done
for i in $(seq 10); do gacc decrease_volume; sleep 0.04; done; mark S4_VOL_END
"${U[@]}" pactl set-sink-volume effect_input.y700_lenovo "$vol0"; sleep 9
mark S5_SILENT_STREAM; "${U[@]}" pw-play --target effect_input.y700_lenovo $D/silence.wav & SIL=$!; sleep 6
mark S5_TONE; "${U[@]}" pw-play --target effect_input.y700_lenovo $D/tone.wav; mark S5_TONE_END; sleep 4
kill $SIL 2>/dev/null; SIL=; mark S5_SILENT_STOP; sleep 9
mark END
cp /root/pop-watch.txt $D/timeline.txt 2>/dev/null
