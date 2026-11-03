#!/bin/sh
# test-wifi-watchdog.sh: y700-wifi-watchdog against fake journalctl / systemctl / nmcli / modprobe / lsmod (2026-10-31
# audit). Runs anywhere with a POSIX sh (PC Git Bash, the tablet); nothing real is touched: the script runs from a
# copy whose STAMP points into a temp dir, every command it calls is a fake that only logs, sleep returns at once.
#   sh linux/net/test-wifi-watchdog.sh [path/to/y700-wifi-watchdog]
# Ends with "ALL PASS" or "FAILED n".
W=${1:-$(dirname "$0")/y700-wifi-watchdog}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
awk -v s="$T/c/stamp" '/^STAMP=/ {print "STAMP=" s; next} 1' "$W" > "$T/watchdog"
grep -q "^STAMP=$T/c/stamp\$" "$T/watchdog" || { echo "no STAMP= line in $W"; exit 2; }
cat > "$T/bin/journalctl" <<'EOF'
#!/bin/sh
cat "$F/kmsg"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/sh
cat "$F/ap"
EOF
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/sh
echo "nmcli $*" >> "$F/log"
case "$*" in
"-t -f WIFI radio") cat "$F/radio" ;;
"-t -f DEVICE,TYPE device") echo "wlp1s0:wifi" ;;
esac
exit 0
EOF
for c in modprobe sudo; do printf '#!/bin/sh\necho "%s $*" >> "$F/log"\n' "$c" > "$T/bin/$c"; done
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/lsmod"      # nothing loaded: modprobe -r worked
chmod +x "$T/bin/"*
F=$T/c; export F
fail=0
LINE="ath12k_wifi7_pci 0000:01:00.0: failed to flush transmit queue, data pkts pending 7"
t() {      # name, flush lines, radio, CarPlay AP state, stamp ("" = none), expected start of the last output line, check
	rm -rf "$F"; mkdir "$F"; : > "$F/log"; : > "$F/kmsg"
	i=0; while [ $i -lt "$2" ]; do echo "$LINE" >> "$F/kmsg"; i=$((i + 1)); done
	echo "$3" > "$F/radio"; echo "$4" > "$F/ap"
	[ -n "$5" ] && echo "$5" > "$F/stamp"
	out=$(PATH="$T/bin:$PATH" sh "$T/watchdog" 2>&1 | tail -1)
	case "$out" in
	"$6"*) if (cd "$F" && eval "$7"); then echo "PASS  $1: $out"; return; fi ;;
	esac
	echo "FAIL  $1: got '$out', want '$6...'  [log: $(tr '\n' ';' < "$F/log")]"; fail=$((fail + 1))
}
now=$(date +%s)
t "stuck, Wi-Fi on: reloaded, the radio switch never written" 2 enabled inactive "" "reloaded (radio enabled, device back)" \
	'! grep -q "radio wifi" log && grep -qx "modprobe -r ath12k_wifi7" log && grep -qx "modprobe ath12k_wifi7" log && grep -q " ok$" stamp'
t "stuck, Wi-Fi off: reloaded, stays off" 2 disabled inactive "" "reloaded (radio disabled, device back)" \
	'! grep -q "radio wifi" log && grep -qx "modprobe ath12k_wifi7" log'
t "one flush failure: nothing" 1 enabled inactive "" "" '! grep -q modprobe log'
t "CarPlay's access point has Wi-Fi: left alone" 2 enabled active "" "stuck TX (2 flush failures) but CarPlay" '! grep -q modprobe log'
t "reloaded 60 s ago: waits" 2 enabled inactive "$((now - 60)) ok" "stuck TX (2 flush failures) but last reload (ok)" \
	'! grep -q modprobe log'
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED $fail"
[ $fail -eq 0 ]
