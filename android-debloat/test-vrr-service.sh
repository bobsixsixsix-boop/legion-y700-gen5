#!/bin/bash
# Offline test of ksu-y700-vrr/service.sh's whitelist copy (10-31 audit A4). Runs anywhere bash runs (Git Bash on the
# PC, Linux): a copy of the module goes into a temp dir, /data/adb/y700 in service.sh is pointed into it, and
# getprop / sleep / nohup are fakes on PATH (nohup only records its arguments: vrr-bridge.sh never starts).
#   fresh   /data/adb/y700 has no vrr-apps.txt (a new install after a factory reset) -> service.sh puts the
#           module's list there; without it vrr-bridge.sh's wanted() says yes to every app (60 Hz for anyone)
#   kept    a hand-edited vrr-apps.txt is already there -> left as it is
#   started service.sh still starts vrr-bridge.sh
# Prints ALL PASS.
cd "$(dirname "$0")" || exit 1
MOD=$PWD/ksu-y700-vrr
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/sh\necho 1\n' > "$T/bin/getprop"
printf '#!/bin/sh\n:\n' > "$T/bin/sleep"
printf '#!/bin/sh\necho "$*" >> "%s/nohup.log"\n' "$T" > "$T/bin/nohup"
chmod +x "$T/bin/"*
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

run() {   # $1 = case name; prints nothing, leaves $T/$1/data (the fake /data/adb/y700)
	local m=$T/$1/module d=$T/$1/data s
	mkdir -p "$m"
	cp "$MOD"/* "$m/"
	s=$(cat "$MOD/service.sh")
	printf '%s\n' "${s//\/data\/adb\/y700/$d}" > "$m/service.sh"
	PATH="$T/bin:$PATH" sh "$m/service.sh"
}

run fresh
cmp -s "$T/fresh/data/vrr-apps.txt" "$MOD/vrr-apps.txt"; check "fresh: the module's vrr-apps.txt is copied to /data/adb/y700" $?

mkdir -p "$T/kept/data"
echo com.example.only > "$T/kept/data/vrr-apps.txt"
run kept
[ "$(cat "$T/kept/data/vrr-apps.txt")" = com.example.only ]; check "kept: a hand-edited vrr-apps.txt is not overwritten" $?

for _ in 1 2 3 4 5 6 7 8 9 10; do   # service.sh starts nohup with &: give the fake a moment to write
	[ "$(grep -c vrr-bridge.sh "$T/nohup.log" 2>/dev/null)" = 2 ] && break
	sleep 0.2
done
[ "$(grep -c vrr-bridge.sh "$T/nohup.log" 2>/dev/null)" = 2 ]
check "started: service.sh still starts vrr-bridge.sh (once per run)" $?

[ "$fails" = 0 ] && echo "ALL PASS" || echo "$fails FAILED"
[ "$fails" = 0 ]
