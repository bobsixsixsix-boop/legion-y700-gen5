#!/bin/bash
# 2026-10-18: run gdbowner2.py at one QAbstractAnimationJob::setCurrentTime hit in plasmashell; detach always
export LC_ALL=C
P=$(pgrep -x plasmashell | head -1)
cat > /tmp/gdbowner2.cmd <<'EOF'
set debuginfod enabled off
set pagination off
set print thread-events off
set unwindonsignal on
break QAbstractAnimationJob::setCurrentTime
continue
delete
source /tmp/gdbowner2.py
detach
EOF
timeout -s INT 25 gdb -p $P -batch -nx -x /tmp/gdbowner2.cmd 2>&1 | grep -v -E '^\[New LWP|^Reading symbols|^\(No debugging|Download failed|^warning: (Could not|Unable)|libthread_db' | cut -c1-1200
pkill -INT -x gdb 2>/dev/null
echo "plasmashell state after: $(awk '{print $3}' /proc/$P/stat) pid $(pgrep -x plasmashell) $(grep TracerPid /proc/$P/status)"
