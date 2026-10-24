#!/bin/sh
# test-wait-tuned-sink.sh: y700-wait-tuned-sink against fake pactl / pw-metadata (2026-10-23). Runs anywhere with a
# POSIX sh (PC Git Bash, the tablet's dash); nothing of the real audio stack is touched.
#   sh linux/audio/test-wait-tuned-sink.sh [path/to/y700-wait-tuned-sink]
# Each case gives the sinks present and what successive pw-metadata reads print (one read per line of a script file,
# names separated by spaces = one read printing the key several times; the last line repeats), and the expected
# first words of the script's message. Ends with "ALL PASS" or "FAILED n".
W=${1:-$(dirname "$0")/y700-wait-tuned-sink}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/pactl" <<'EOF'
#!/bin/sh
for s in $(cat "$FAKE/sinks"); do printf '1\t%s\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n' "$s"; done
EOF
cat > "$T/bin/pw-metadata" <<'EOF'
#!/bin/sh
n=$(cat "$FAKE/n" 2>/dev/null || echo 1)
line=$(sed -n "${n}p" "$FAKE/reads"); [ -n "$line" ] || line=$(tail -1 "$FAKE/reads")
echo $((n + 1)) > "$FAKE/n"
echo 'Found "default" metadata 44'
for v in $line; do
	[ "$v" = - ] && continue
	echo "update: id:0 key:'default.configured.audio.sink' value:'{\"name\":\"$v\"}' type:'Spa:String:JSON'"
done
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/"*
fail=0
t() {      # name, sinks, reads (|-separated), expected start of the message
	rm -rf "$T/c"; mkdir "$T/c"
	echo "$2" > "$T/c/sinks"
	printf '%s\n' "$3" | tr '|' '\n' > "$T/c/reads"
	out=$(FAKE="$T/c" PATH="$T/bin:$PATH" sh "$W")
	case "$out" in
	"$4"*) echo "PASS  $1: $out" ;;
	*) echo "FAIL  $1: got '$out', want '$4...'"; fail=$((fail + 1)) ;;
	esac
}
L=effect_input.y700_lenovo S=effect_input.speakers B=bluez_output.02_00_00_00_00_50.1
t "tuned at once" "$S $L" "$L" "tuned sink is the default after 0.0 s"
t "tuned printed twice (10-22)" "$S $L" "$L $L" "tuned sink is the default after 0.0 s"
t "tuned printed three times (10-23)" "$S $L" "$L $L $L" "tuned sink is the default after 0.0 s"
t "speakers then tuned in one read: wait" "$S $L" "$S $L|$S $L|$L" "tuned sink is the default after 0.50 s"
t "boot dance: speakers, then tuned" "$S $L" "$S|$S|$S|$L" "tuned sink is the default after 0.75 s"
t "nothing configured yet" "$S $L" "-|-|$L" "tuned sink is the default after 0.50 s"
t "tuned sink not there yet" "$S" "$S" "tuned sink not the default after 12 s"
t "owner's headphones connected" "$S $L $B" "$B" "owner's headphones '$B' kept"
t "owner's headphones gone: wait for the guard" "$S $L" "$B|$B|$L" "tuned sink is the default after 0.50 s"
t "owner's other choice" "$S $L foo" "foo" "owner's default 'foo' kept"
t "owner's other choice printed twice" "$S $L foo" "foo foo" "owner's default 'foo' kept"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED $fail"
[ $fail -eq 0 ]
