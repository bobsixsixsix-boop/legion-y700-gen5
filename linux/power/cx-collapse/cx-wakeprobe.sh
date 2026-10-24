#!/bin/bash
# cx-wakeprobe.sh [SECS]: screen-off trace of the slow-path wakeup sources y700-wakeups only counts (2026-10-16).
# ROOT. Display off (kscreen-doctor), 30 s settle, then SECS (default 30) in a private tracefs instance:
#   cgroup:cgroup_mkdir / cgroup_rmdir      who creates/destroys cgroups (systemd units, scopes) - by path
#   sched:sched_process_exec                what gets exec'ed - by filename
#   ipi:ipi_send_cpumask + stacktrace       the cross-CPU calls that hit every CPU; stacks through
#                                           kick_all_cpus_sync are counted by caller (static key flips = jump_label)
# plus the journal lines of the window by identifier. Trace events only - no register debugfs, nothing written
# outside the instance (removed on exit). Prints its report to stdout; cx-ladder.sh appends it to the cx-exp log.
set -u
SECS=${1:-30}
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
T=/sys/kernel/tracing/instances/y700probe
INH=
cleanup() {
	trap - EXIT
	if [ -d $T ]; then
		echo 0 > $T/tracing_on
		for e in cgroup/cgroup_mkdir cgroup/cgroup_rmdir sched/sched_process_exec ipi/ipi_send_cpumask; do echo 0 > $T/events/$e/enable 2>/dev/null; done
		echo '!stacktrace' > $T/events/ipi/ipi_send_cpumask/trigger 2>/dev/null
		rmdir $T 2>/dev/null
	fi
	"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
	[ -n "$INH" ] && { pkill -P "$INH" 2>/dev/null; kill "$INH" 2>/dev/null; }
}
trap cleanup EXIT; trap 'exit 1' INT TERM
echo; echo "=== $(date '+%F %T') cx-wakeprobe ${SECS}s on $(uname -r), $(cat /sys/class/power_supply/qcom-battmgr-bat/status)"
"${U[@]}" kde-inhibit --power --screenSaver sleep $((SECS + 120)) >/dev/null 2>&1 </dev/null & INH=$!
"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
sleep 30
[ "$(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)" = Off ] || { echo "ABORT: display not off"; exit 2; }
mkdir $T || { echo "ABORT: cannot create $T"; exit 2; }
echo 16384 > $T/buffer_size_kb
echo stacktrace > $T/events/ipi/ipi_send_cpumask/trigger
for e in cgroup/cgroup_mkdir cgroup/cgroup_rmdir sched/sched_process_exec ipi/ipi_send_cpumask; do echo 1 > $T/events/$e/enable; done
since=$(date '+%F %T')
echo 1 > $T/tracing_on; sleep "$SECS"; echo 0 > $T/tracing_on
python3 - "$T/trace" "$SECS" <<'PY'
import re, sys, collections
lines = open(sys.argv[1], errors="replace").read().split("\n"); secs = float(sys.argv[2])
num = lambda s: re.sub(r"\d+", "N", s)
mk, rm, ex, kick, other = (collections.Counter() for _ in range(5))
ev_comm = None; stack = None; n_cpumask = 0
def flush():
    if stack is None: return
    if any("kick_all_cpus_sync" in f for f in stack):
        kick[(ev_comm, " <- ".join(f.split("+")[0] for f in stack[2:9]))] += 1
    elif stack: other[" <- ".join(f.split("+")[0] for f in stack[2:6])] += 1
for l in lines:
    if l.startswith(" => "):
        if stack is not None: stack.append(l[4:].strip())
        continue
    flush(); stack = None
    if "<stack trace>" in l: stack = []; continue
    m = re.match(r"\s*(.+?)-\d+\s+(?:\(\s*[\d-]+\)\s+)?\[\d+\]", l)
    comm = m.group(1).strip() if m else "?"
    if "cgroup_mkdir:" in l: mk[num(re.search(r"path=(\S+)", l).group(1) if "path=" in l else l[-80:])] += 1
    elif "cgroup_rmdir:" in l: rm[num(re.search(r"path=(\S+)", l).group(1) if "path=" in l else l[-80:])] += 1
    elif "sched_process_exec:" in l:
        f = re.search(r"filename=(\S+)", l); ex[f.group(1) if f else "?"] += 1
    elif "ipi_send_cpumask:" in l: n_cpumask += 1; ev_comm = comm
flush()
def show(title, c, k=10):
    t = sum(c.values()); print(f"-- {title}: {t} in {secs:.0f} s = {t/secs:.2f}/s")
    for key, v in c.most_common(k): print(f"   {v:5d} {v/secs:6.2f}/s  {key}")
show("cgroup_mkdir by path", mk); show("cgroup_rmdir by path", rm); show("exec by filename", ex)
print(f"-- ipi_send_cpumask events: {n_cpumask} = {n_cpumask/secs:.2f}/s")
show("  of which through kick_all_cpus_sync, by [sender] caller chain", kick, 8)
show("  other cpumask IPI callers", other, 6)
PY
echo "-- journal lines in the window by identifier"
journalctl --since "$since" -o json --output-fields=SYSLOG_IDENTIFIER,_COMM 2>/dev/null | python3 -c '
import json, sys, collections
c = collections.Counter()
for l in sys.stdin:
    try: d = json.loads(l)
    except Exception: continue
    c[d.get("SYSLOG_IDENTIFIER") or d.get("_COMM") or "?"] += 1
for k, v in c.most_common(8): print(f"   {v:5d}  {k}")'
echo "=== $(date +%T) cx-wakeprobe done"
