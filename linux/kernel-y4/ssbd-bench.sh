#!/bin/bash
# Measure how much Oryon slows down when a task runs with speculative store bypass disabled (PSTATE.SSBS=0),
# which is what Wine's sigreturn leaves Proton threads in (ArmadaOS patch 0540).
set -e
D=/root/ssbd-bench; mkdir -p $D; cd $D
cat > ssbd-run.c <<'C'
#include <sys/prctl.h>
#include <linux/prctl.h>
#include <unistd.h>
#include <stdio.h>
int main(int c, char **v) {
  if (prctl(PR_SET_SPECULATION_CTRL, PR_SPEC_STORE_BYPASS, PR_SPEC_DISABLE, 0, 0)) { perror("prctl"); return 1; }
  execvp(v[1], v + 1); perror("exec"); return 1;
}
C
cc -O2 -o ssbd-run ssbd-run.c
head -c 40000000 /usr/lib/aarch64-linux-gnu/libLLVM*.so* 2>/dev/null > blob || head -c 40000000 /usr/bin/* > blob
cat > py.py <<'P'
d = {}
for i in range(3_000_000):
    d[i & 4095] = d.get((i * 7) & 4095, 0) + i
print(len(d))
P
cpu=7
run() { local s e; s=$(date +%s.%N); taskset -c $cpu "$@" > /dev/null; e=$(date +%s.%N); echo "$e - $s" | bc; }
echo "cpu$cpu $(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq 2>/dev/null) kHz"
./ssbd-run grep Speculation_Store_Bypass /proc/self/status
grep Speculation_Store_Bypass /proc/self/status
for w in "xz -T1 -3 -c blob" "python3 py.py"; do
  for i in 1 2 3; do
    a=$(run $w); b=$(run ./ssbd-run $w)
    echo "$w | SSBS=1 ${a}s | SSBS=0 ${b}s"
  done
done
