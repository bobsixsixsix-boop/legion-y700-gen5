#!/bin/bash
# linux/power/flightrec/test-lock.sh [BIN] -- one recorder per run dir (10-31 audit A1). ROOT on the tablet (the
# recorder reads debugfs). Every recorder here runs on a temp --log-dir/--run-dir with --no-pmsg; the running service,
# /run/y700-flightrec and /var/log/y700-flightrec are not touched. BIN defaults to the installed
# /usr/local/libexec/y700-flightrec.
#   second       a second recorder on the same run dir (what a hand-started `y700-flightrec --no-pmsg --log-dir D`
#                without --run-dir meets): it exits 1 within 3 s before it writes anything (its log dir is not even
#                made), the first one's daemon.pid and live.log stay as they were
#   foreign-pid  daemon.pid names another process when the recorder stops: it stays (batteryd reads it)
#   own-pid      daemon.pid names the recorder when it stops: it goes; a recorder started after that gets the lock
# Expected: every case PASS with the 10-31 build; the build before it fails second and foreign-pid.
BIN=${1:-/usr/local/libexec/y700-flightrec}
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fails=0
R=$T/run
rec() { "$BIN" --log-dir "$1" --run-dir "$R" --no-pmsg --interval 1 --idle-interval 10 >/dev/null 2>&1 & pid=$!; }
headers() { cat "$R/live.log" 2>/dev/null | grep -c '^HEADER'; }
upto() { for _ in $(seq 50); do [ "$(headers)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
stop() { kill "$1"; wait "$1"; }
result() { if [ -z "$2" ]; then echo "PASS $1"; else echo "FAIL $1:$2"; fails=$((fails + 1)); fi; }

rm -rf "$R"; why=""
rec "$T/log1"; first=$pid; upto 1 || why="$why the first recorder wrote no HEADER;"
rec "$T/log2"; second=$pid
for _ in $(seq 30); do kill -0 $second 2>/dev/null || break; sleep 0.1; done
if kill -0 $second 2>/dev/null; then
	why="$why the second one still runs after 3 s;"; stop $second
else
	wait $second; rc=$?; [ $rc = 1 ] || why="$why the second one exited $rc, not 1;"
fi
[ -e "$T/log2" ] && why="$why the second one made its log dir;"
[ "$(cat "$R/daemon.pid" 2>/dev/null)" = "$first" ] || why="$why daemon.pid is '$(cat "$R/daemon.pid" 2>/dev/null)', not the first's $first;"
[ "$(headers)" = 1 ] || why="$why $(headers) HEADER lines in live.log, not 1;"
kill -0 $first 2>/dev/null || why="$why the first one died;"
stop $first
result second "$why"

rm -rf "$R"; why=""
rec "$T/log1"; upto 1 || why="$why no HEADER;"
echo $$ >"$R/daemon.pid" # a live process that is not the recorder
stop $pid; rc=$?; [ $rc = 0 ] || why="$why exit $rc, not 0;"
grep -qs '^STOP' "$R/live.log" || why="$why no STOP line;"
[ "$(cat "$R/daemon.pid" 2>/dev/null)" = $$ ] || why="$why daemon.pid is '$(cat "$R/daemon.pid" 2>/dev/null)', not $$;"
result foreign-pid "$why"

rm -rf "$R"; why=""
rec "$T/log1"; upto 1 || why="$why no HEADER;"
[ "$(cat "$R/daemon.pid" 2>/dev/null)" = $pid ] || why="$why daemon.pid does not name it;"
stop $pid; rc=$?; [ $rc = 0 ] || why="$why exit $rc, not 0;"
[ -e "$R/daemon.pid" ] && why="$why daemon.pid left behind;"
rec "$T/log1"; upto 2 || why="$why a recorder started after it wrote no HEADER (lock not released?);"
[ "$(cat "$R/daemon.pid" 2>/dev/null)" = $pid ] || why="$why daemon.pid does not name the next one;"
stop $pid
result own-pid "$why"

echo "$fails failed"
[ $fails = 0 ]
