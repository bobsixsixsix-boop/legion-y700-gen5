#!/usr/bin/env python3
# im-log.py: dbus-monitor (default format) on stdin -> one line per message, for gate-steam.sh's TRACE:
#   TIME SENDER IFACE.MEMBER[last path element] args...     (an OskGate Event: TIME gate {json})
# The sender stays a bus name (:1.738); gate-steam.sh turns it into the process name.
import re, sys
hdr = re.compile(r"^(signal|method call|method return|error) time=([0-9.]+) sender=(\S+) .*?(?:path=([^;]+); )?(?:interface=([^;]+); )?member=(\S+)")
cur = None
args = []

def flush():
    global cur, args
    if cur:
        t, sender, path, iface, member = cur
        if member == "Event" and iface.endswith("OskGate"):
            print(f"{t:.3f} gate {args[0] if args else ''}", flush=True)
        else:
            short = iface.split(".")[-1]
            p = path.rsplit("/", 1)[-1] if path else ""
            print(f"{t:.3f} {sender} {short}.{member}[{p}] {' '.join(args)}", flush=True)
    cur = None
    args = []

for line in sys.stdin:
    m = hdr.match(line)
    if m:
        flush()
        if m.group(1) in ("method call", "signal"):
            cur = (float(m.group(2)), m.group(3), m.group(4) or "", m.group(5) or "", m.group(6))
        continue
    if cur is None:
        continue
    s = line.strip()
    a = re.match(r'^string "(.*)"$', s)
    if a:
        args.append(a.group(1) if cur[4] == "Event" else '"' + a.group(1)[:60] + '"')
        continue
    a = re.match(r"^(?:int32|uint32|int64|uint64|double|boolean|byte|int16|uint16) (\S+)$", s)
    if a:
        args.append(a.group(1))
flush()
