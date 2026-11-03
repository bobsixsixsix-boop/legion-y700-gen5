#!/bin/sh
# test-prefer-6g.sh: the NetworkManager dispatcher script 90-y700-prefer-6g against a fake nmcli (2026-10-31 audit).
# Runs anywhere with a POSIX sh (PC Git Bash, the tablet); nothing real is touched: the script runs from a copy whose
# stamp files (/run) and interface directory (/sys/class/net) point into a temp dir, nmcli / logger are fakes that
# log, sleep returns at once. The script is sourced in `sh -c '. copy; wait'` so its background loop is waited for.
#   sh linux/wifi/test-prefer-6g.sh [path/to/90-y700-prefer-6g]
# Ends with "ALL PASS" or "FAILED n".
P=${1:-$(dirname "$0")/90-y700-prefer-6g}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
awk -v s="$T/c/stamps/" -v n="$T/c/net" '/^[A-Z]+=\/run\// {sub(/=\/run\//, "=" s)} /^NET=/ {$0 = "NET=" n} 1' "$P" > "$T/prefer"
awk '!/^#/ && !/^[A-Z]+=/' "$P" | grep -q '/run/\|/sys/' && { echo "$P names a /run or /sys path the test cannot redirect"; exit 2; }
# nmcli: the active connection in $F/active, the scan in $F/ssids; `con up HOME_6G` fails while $F/6g-fails exists
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/sh
case "$*" in
"-g GENERAL.CONNECTION dev show "*) cat "$F/active" ;;
"-g SSID dev wifi list "*) cat "$F/ssids" ;;
"con up "*)
	echo "up $3" >> "$F/log"
	[ "$3" = HOME_6G ] && [ -e "$F/6g-fails" ] && exit 4
	echo "$3" > "$F/active" ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "logger $*" >> "$F/log"\n' > "$T/bin/logger"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
F=$T/c; export F
fail=0
setup() {      # what the scan shows; then optional: "fails" (HOME_6G cannot be joined)
	rm -rf "$F"; mkdir -p "$F/stamps" "$F/net/wlp1s0"; : > "$F/log"
	echo 3 > "$F/net/wlp1s0/ifindex"
	echo HOME_2.4G > "$F/active"; printf '%s\n' $1 > "$F/ssids"
	[ "$2" = fails ] && : > "$F/6g-fails"
	return 0
}
up() {         # one dispatcher call: the connection that came up (default HOME_2.4G)
	CONNECTION_ID=${1:-HOME_2.4G} PATH="$T/bin:$PATH" sh -c '. "$0"; wait' "$T/prefer" wlp1s0 up
}
age() {        # minutes: every stamp the script wrote is now that old
	for s in "$F/stamps/"*; do [ -e "$s" ] && touch -d "$1 minutes ago" "$s"; done
	return 0
}
back24() { echo HOME_2.4G > "$F/active"; up; }   # NetworkManager is back on HOME_2.4G, the dispatcher runs
tries() { grep -cx "up HOME_6G" "$F/log"; }
ok() {         # name, condition
	if eval "$2"; then echo "PASS  $1"
	else echo "FAIL  $1  [log: $(tr '\n' ';' < "$F/log")]"; fail=$((fail + 1)); fi
}

setup "HOME_2.4G HOME_6G"; up
ok "HOME_6G visible: switched" '[ "$(tries)" = 1 ] && [ "$(cat "$F/active")" = HOME_6G ]'

# the loop of the audit: the switch fails, the fallback brings HOME_2.4G up, the dispatcher runs again
setup "HOME_2.4G HOME_6G" fails; up; up; up
ok "HOME_6G cannot be joined: one try, then stays on HOME_2.4G" '[ "$(tries)" = 1 ] && [ "$(cat "$F/active")" = HOME_2.4G ]'
rm "$F/6g-fails"; age 31; up
ok "a HOME_2.4G connection 31 min after that: switches again" '[ "$(tries)" = 2 ] && [ "$(cat "$F/active")" = HOME_6G ]'

# the switch worked, HOME_6G dropped at once: NetworkManager is back on HOME_2.4G 1 min later, same interface
setup "HOME_2.4G HOME_6G"; up; age 1; back24
ok "back on HOME_2.4G 1 min after a switch: stays" '[ "$(tries)" = 1 ] && [ "$(cat "$F/active")" = HOME_2.4G ] && grep -q staying "$F/log"'
age 10; up
ok "... that was a failure: a HOME_2.4G connection 10 min later still stays" '[ "$(tries)" = 1 ]'

# the review of the fix: a switch that held must not block the way back to HOME_6G after an unrelated drop
setup "HOME_2.4G HOME_6G"; up; age 10; back24
ok "back on HOME_2.4G 10 min after a switch that held: switches again" '[ "$(tries)" = 2 ] && [ "$(cat "$F/active")" = HOME_6G ]'
setup "HOME_2.4G HOME_6G"; up; age 1; echo 4 > "$F/net/wlp1s0/ifindex"; back24
ok "ath12k reloaded (new ifindex) 1 min after a switch: switches again" '[ "$(tries)" = 2 ] && [ "$(cat "$F/active")" = HOME_6G ]'

setup "HOME_2.4G"; up
ok "HOME_6G not in the scan: nothing" '[ "$(tries)" = 0 ]'

setup "HOME_2.4G HOME_6G"; up HOME_6G
ok "another connection came up: nothing" '[ "$(tries)" = 0 ]'

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED $fail"
[ $fail -eq 0 ]
