#!/bin/bash
# deploy.sh SRC_DIR: install the Rust flight recorder on the tablet with a guard and a rollback (ROOT). 2026-10-17.
# SRC_DIR holds the built binary y700-flightrec and y700-flightrec.service. Meant to be started unattended
# (systemd-run --on-calendar=...), so it:
#   - never swaps the recorder under a running experiment: a y700-cx-* / y700-offmeasure unit active or a CX knob
#     set -> try again in 30 min (at most 8 times), log why;
#   - backs up what is installed - the recorder binary, the y700-flightrec.py path as it is (the Python recorder
#     the first time, the symlink to the binary since), the unit - to /root/*.bak-<stamp>; no backup, no install;
#   - installs /usr/local/libexec/y700-flightrec, makes /usr/local/libexec/y700-flightrec.py a symlink to it (the
#     installed cx-exp.sh calls that path for --mark), installs the unit, restarts the service;
#   - checks within ~40 s: the unit active, the new HEADER (idle_interval=) and a MODE line in current.log, a sample
#     line after the first interval, `--once` works, and (not under Y700_FR_ROOT) the battery page's files: the edge
#     file written at start and the energy line - this boot's, 321 bytes - rewritten within 25 s more; anything
#     off -> puts all three back. A binary without src/acc.rs (no "v1 boot=" in it: the pre-acc backup, deployed to
#     take acc out - battery/DESIGN.md section 9) skips those two and says so; the files it leaves are tmpfs, gone at
#     the next boot.
# Y700_FR_ROOT prefixes every absolute path (test-deploy.sh only).
# Log: /var/log/y700-flightrec-deploy.txt
set -u
SRC=${1:?source dir}
TRY=${2:-0}
R=${Y700_FR_ROOT:-}
LOG=$R/var/log/y700-flightrec-deploy.txt
exec >> "$LOG" 2>&1
STAMP=$(date +%Y%m%d-%H%M%S)
echo "=== $(date '+%F %T') deploy try $TRY from $SRC"
busy=""
for u in y700-cx-exp y700-cx-ladder y700-cx-idle y700-cx-night y700-offmeasure; do
	systemctl is-active -q $u && busy="$busy $u"
done
for k in allow_cluster_off allow_system_off; do
	v=$(cat $R/sys/module/cpuidle_psci_domain/parameters/$k 2>/dev/null)
	# knobs set by y700-cx-auto (daily use while the screen is off) are not an experiment
	[ -e $R/run/y700-cx-auto.armed ] && continue
	[ "$v" = Y ] || [ "$v" = 1 ] && busy="$busy $k=$v"
done
if [ -n "$busy" ]; then
	if [ "$TRY" -ge 8 ]; then echo "still busy ($busy) after 8 tries - giving up, nothing changed"; exit 1; fi
	echo "experiment running ($busy) - nothing changed, retrying in 30 min"
	# the transient unit runs in /: started as `bash deploy.sh pkg`, the retry got the relative "$0" "$SRC", bash found
	# no deploy.sh in / and it died (exit 127, journal only) before it logged a line (10-19 audit B6)
	systemd-run --unit "y700-flightrec-deploy-$((TRY + 1))" --collect --on-active=30min /bin/bash "$(readlink -m "$0")" "$(readlink -m "$SRC")" $((TRY + 1)) >/dev/null
	exit 0
fi
[ -x "$SRC/y700-flightrec" ] && [ -f "$SRC/y700-flightrec.service" ] || { echo "missing files in $SRC"; exit 2; }
L=$R/usr/local/libexec; UD=$R/etc/systemd/system; BK=$R/root
# A second deploy (Rust over Rust) found y700-flightrec.py already a symlink: `cp -p` followed it and the binary itself
# was never saved, so the rollback restarted the new binary it was meant to replace (10-19 audit). -P keeps the
# symlink as a symlink; the binary is saved on its own.
cp -P -p $L/y700-flightrec.py $BK/y700-flightrec.py.bak-$STAMP || { echo "no backup of $L/y700-flightrec.py, nothing changed"; exit 2; }
if [ -e $L/y700-flightrec ]; then
	cp -p $L/y700-flightrec $BK/y700-flightrec.bak-$STAMP || { echo "no backup of $L/y700-flightrec, nothing changed"; exit 2; }
fi
cp -p $UD/y700-flightrec.service $BK/y700-flightrec.service.bak-$STAMP || { echo "no backup of the unit, nothing changed"; exit 2; }
rollback() {
	echo "ROLLBACK: $*"
	rm -f $L/y700-flightrec.py
	cp -P -p $BK/y700-flightrec.py.bak-$STAMP $L/y700-flightrec.py
	if [ -e $BK/y700-flightrec.bak-$STAMP ]; then
		cp -p $BK/y700-flightrec.bak-$STAMP $L/y700-flightrec.new && mv -f $L/y700-flightrec.new $L/y700-flightrec
	else
		rm -f $L/y700-flightrec
	fi
	cp -p $BK/y700-flightrec.service.bak-$STAMP $UD/y700-flightrec.service
	systemctl daemon-reload; systemctl restart y700-flightrec
	sleep 3; echo "after rollback: $(systemctl is-active y700-flightrec), $(tail -1 $R/var/log/y700-flightrec/current.log | cut -c1-80)"
	exit 3
}
install -m 755 "$SRC/y700-flightrec" $L/y700-flightrec
ln -sfn y700-flightrec $L/y700-flightrec.py
install -m 644 "$SRC/y700-flightrec.service" $UD/y700-flightrec.service
systemctl daemon-reload
EDGE=$R/run/y700-flightrec/edge
edge0=$(cat $EDGE 2>/dev/null) # the new recorder must replace it at start (its t is later than any before it)
systemctl restart y700-flightrec
sleep 13
systemctl is-active -q y700-flightrec || rollback "unit not active: $(systemctl is-active y700-flightrec)"
C=$R/var/log/y700-flightrec/current.log
hdr=$(grep "^HEADER" $C | tail -1)
case "$hdr" in *idle_interval=*) ;; *) rollback "no new HEADER in $C" ;; esac
tail -5 $C | grep -q "^MODE " || tail -20 $C | grep -q "^MODE " || rollback "no MODE line"
tail -3 $C | grep -q "^t=" || rollback "no sample line within 13 s"
$L/y700-flightrec --once | grep -q "^t=.* qs=" || rollback "--once failed"
# the battery page's counters (src/acc.rs): rewritten in place after every data line, 10 s apart here (no
# experiment). test-deploy.sh's fake recorders write current.log only, so this needs the real one. The energy line's
# format string is in every acc binary (strip=true keeps .rodata); one without it (the pre-acc backup) writes neither.
if [ -z "$R" ] && ! grep -qaF 'v1 boot=' "$SRC/y700-flightrec"; then
	echo "no acc in $SRC/y700-flightrec - battery files not checked"
elif [ -z "$R" ]; then
	E=$R/run/y700-flightrec/energy
	e0=$(cat $E 2>/dev/null); e1=$e0; n=0
	while [ "$e1" = "$e0" ] && [ $n -lt 25 ]; do sleep 1; n=$((n + 1)); e1=$(cat $E 2>/dev/null); done
	[ -n "$e1" ] && [ "$e1" != "$e0" ] || rollback "energy not rewritten within 25 s: '${e1:0:60}'"
	case "$e1" in "v1 boot=$(cut -c1-8 $R/proc/sys/kernel/random/boot_id) "*) ;; *) rollback "energy is not this boot's v1 line: ${e1:0:60}" ;; esac
	[ ${#e1} -eq 321 ] || rollback "energy line is ${#e1} bytes, not 321 (a residue past the newline counts)"
	edge1=$(cat $EDGE 2>/dev/null)
	case "$edge1" in "v1 t="*) ;; *) rollback "no edge file: '$edge1'" ;; esac
	[ "$edge1" != "$edge0" ] || rollback "edge not written at start: $edge1"
fi
echo "deployed: $(sha256sum $L/y700-flightrec | cut -c1-16); $(tail -1 $C | cut -c1-120)"
echo "backups: $BK/y700-flightrec{,.py,.service}.bak-$STAMP"
