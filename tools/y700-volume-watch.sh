#!/bin/bash
# y700-volume-watch: read-only. On every sink / sink-input / server event (pactl subscribe), log with ms timestamps:
# the default sink, the three speaker stages' volumes, and every playing stream's volume + sink. Log: /tmp/volwatch.log
export LC_ALL=C
L=/tmp/volwatch.log
snap() {
	local d s
	d=$(pactl get-default-sink 2>/dev/null)
	s=$(pactl list sinks 2>/dev/null | awk '/^Sink #/ {id = substr($2, 2)} /^\tName:/ {n = $2} /^\tVolume:/ {v = $5; print n "=" v}' | sed 's/effect_input\.y700_lenovo/TUNED/; s/effect_input\.speakers/PROT/; s/alsa_output\.platform-sound\.HiFi__Speaker__sink/RAW/' | tr '\n' ' ')
	i=$(pactl list sink-inputs 2>/dev/null | awk '/^Sink Input #/ {id = substr($3, 2)} /^\tSink:/ {sk = $2} /^\tVolume:/ {v = $5} /application\.name = / {a = $0; sub(/.*= "/, "", a); sub(/"$/, "", a)} /node\.name = / {n = $0; sub(/.*= "/, "", n); sub(/"$/, "", n); print "#" id "(" (a != "" ? a : n) ")@" sk "=" v; a = ""}' | tr '\n' ' ')
	echo "$(date +%T.%3N) $1 | default=$d | $s| $i" >> $L
}
snap start
pactl subscribe 2>/dev/null | while IFS= read -r line; do
	case "$line" in
	*" on sink #"* | *" on sink-input #"* | *" on server"*) snap "$line" ;;
	esac
done
