#!/bin/bash
# linux/power/flightrec/test-prune.sh [BIN] -- which per-boot logs the recorder keeps when it starts (2026-10-23).
# ROOT on the tablet (the recorder reads debugfs). Each case starts a second recorder on a temp --log-dir/--run-dir
# with --no-pmsg and stops it once its own HEADER is out (~1 s; no HEADER of its own within 5 s fails the case); the
# running recorder and /var/log/y700-flightrec are not touched. BIN defaults to the installed
# /usr/local/libexec/y700-flightrec.
#   legacy-newer  12 old logs, no boots.txt, all with mtimes later than now - what this boot's fresh log meets when
#                 the RTC is still at 1970: this boot's log must stay, the oldest old one goes (the 10-23 bug: the
#                 old prune_logs sorted by mtime and deleted this boot's log)
#   index         boots.txt names 12 boots in the order opposite to their mtimes: the first in boots.txt goes
#   unknown       a log boots.txt does not know (newest mtime) goes before every one it knows
#   restart       a second start in the same boot appends nothing to boots.txt and removes nothing
#   crash-1970    the boot before this one died before NTP (its log has a 1970 mtime): it stays
# Every boot also has its pstore/<boot> copy (archive_pstore, 10-31 audit A2): it must go and stay with its log, this
# boot's always stays, exactly 12 are left; index adds pstore/p00 with no log (a copy left from before the fix): it goes.
# Expected: every case PASS with the 10-31 build; the 10-23 build fails every case on the pstore copies (it never
# removed one); the build before that fails every case on the logs too (restart: it keeps no boots.txt).
BIN=${1:-/usr/local/libexec/y700-flightrec}
B=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
# this boot's pstore copy is made here: archive_pstore makes it only when the tablet has records
fresh() { rm -rf "$T/log" "$T/run"; mkdir -p "$T/log/pstore/$B" "$T/run"; }
mk() {  # boot8, mtime: its log and its pstore copy
	echo "t=1" >"$T/log/flightrec-$1.log"; touch -d "$2" "$T/log/flightrec-$1.log"
	mkdir -p "$T/log/pstore/$1"; echo x >"$T/log/pstore/$1/pmsg-ramoops-0"
}
headers() { cat "$T/run/live.log" 2>/dev/null | grep -c '^HEADER'; }
# live.log is appended to, so restart (no fresh before it) finds unknown's HEADER there: waiting for "a HEADER" killed
# the second recorder before it blocked SIGTERM, and restart judged what unknown had left (10-31 review). Wait for one
# more than there was; the HEADER comes after prune_logs, so a recorder that wrote none fails its case.
start() {
	local n0; n0=$(headers)
	"$BIN" --log-dir "$T/log" --run-dir "$T/run" --no-pmsg --interval 1 --idle-interval 10 >/dev/null 2>&1 & local pid=$!
	for _ in $(seq 50); do [ "$(headers)" -gt "$n0" ] && break; sleep 0.1; done
	kill $pid; wait $pid 2>/dev/null
	if [ "$(headers)" -gt "$n0" ]; then nohdr=""; else nohdr=" it wrote no HEADER within 5 s;"; fi
}
# case name, then the boots whose logs and pstore copies must be there (this boot's are always checked) and "-"
# followed by those that must be gone; also exactly 12 logs and 12 copies
check() {
	local name=$1 why=$nohdr want=present b; shift
	[ -e "$T/log/flightrec-$B.log" ] || why="$why this boot's log is gone;"
	[ -d "$T/log/pstore/$B" ] || why="$why this boot's pstore copy is gone;"
	for b in "$@"; do
		[ "$b" = - ] && { want=gone; continue; }
		if [ $want = present ]; then
			[ -e "$T/log/flightrec-$b.log" ] || why="$why $b gone;"
			[ -d "$T/log/pstore/$b" ] || why="$why pstore/$b gone;"
		else
			[ -e "$T/log/flightrec-$b.log" ] && why="$why $b kept;"
			[ -e "$T/log/pstore/$b" ] && why="$why pstore/$b kept;"
		fi
	done
	local n; n=$(ls "$T/log" | grep -c '^flightrec-.*\.log$')
	[ "$n" = 12 ] || why="$why $n logs, not 12;"
	n=$(ls "$T/log/pstore" | wc -l)
	[ "$n" = 12 ] || why="$why $n pstore copies, not 12;"
	if [ -z "$why" ]; then echo "PASS $name"; else echo "FAIL $name:$why"; fails=$((fails + 1)); fi
}
seq2() { for i in $(seq -w 1 12); do echo "$1$i"; done; }

fresh; for i in $(seq -w 1 12); do mk o$i "2030-01-01 00:$i"; done
start; check legacy-newer $(seq2 o | tail -11) - o01
[ "$(cat "$T/log/boots.txt" 2>/dev/null)" = "$B" ] || { echo "FAIL legacy-newer: boots.txt is '$(cat "$T/log/boots.txt" 2>/dev/null)', not $B"; fails=$((fails + 1)); }

fresh; for i in $(seq -w 1 12); do mk a$i "2025-01-01 00:$(printf %02d $((13 - 10#$i)))"; done; seq2 a >"$T/log/boots.txt"
mkdir "$T/log/pstore/p00"
start; check index $(seq2 a | tail -11) - a01 p00

fresh; for i in $(seq -w 2 12); do mk k$i "2025-01-01 00:$i"; done; mk x99 "2030-01-01"; seq2 k | tail -11 >"$T/log/boots.txt"
start; check unknown $(seq2 k | tail -11) - x99
start; check restart $(seq2 k | tail -11)
[ "$(grep -cx "$B" "$T/log/boots.txt")" = 1 ] || { echo "FAIL restart: this boot is in boots.txt $(grep -cx "$B" "$T/log/boots.txt") times"; fails=$((fails + 1)); }

fresh; for i in $(seq -w 1 11); do mk c$i "2025-01-01 00:$i"; done; mk c12 "1970-01-14 07:02"; seq2 c >"$T/log/boots.txt"
start; check crash-1970 $(seq2 c | tail -11) - c01

echo "$fails failed"
[ $fails = 0 ]
