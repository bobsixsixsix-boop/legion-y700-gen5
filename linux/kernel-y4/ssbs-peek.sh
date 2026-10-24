#!/bin/bash
# Snapshot PSTATE.SSBS (bit 12 of cpsr) of every thread of the given pids (read-only gdb attach/detach).
for p in "$@"; do
  n=$(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-45)
  timeout 30 gdb -p "$p" -batch -nx -ex 'thread apply all p/x $cpsr' 2>/dev/null > /tmp/ssbs-$p.txt
  python3 - "$p" "$n" <<'P'
import re, sys
vals = [int(m, 16) for m in re.findall(r'^\$\d+ = (0x[0-9a-f]+)', open('/tmp/ssbs-%s.txt' % sys.argv[1]).read(), re.M)]
off = sum(1 for v in vals if not v & 0x1000)
print("pid %s [%s]: threads=%d  SSBS=0(slow): %d  SSBS=1: %d" % (sys.argv[1], sys.argv[2].strip(), len(vals), off, len(vals) - off))
P
done
