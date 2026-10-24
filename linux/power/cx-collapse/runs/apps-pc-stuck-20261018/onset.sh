#!/bin/bash
# 2026-10-18: the system domain stopped being entered 2026-10-17 18:08-18:18. What happened then? (read-only)
export LC_ALL=C
F=/var/log/y700-flightrec/current.log
echo "######## flightrec rows 10-17 17:58-18:30 (t window from the at= crossing): at dpms aco aso pd qs irq"
# the boot started 10-16 19:08, so 10-17 18:00 is mono t around 82000-84500; pick rows whose at= is 17:58-18:30 and t > 80000 and t < 90000
awk '/^t=/ { t = substr($1, 3) + 0; if (t < 80000 || t > 90000) next
  if (match($0, / at=[^ ]*/)) at = substr($0, RSTART + 4, 8); if (at < "17:58" || at > "18:30") next
  d = ""; if (match($0, / dpms=[^ ]*/)) d = substr($0, RSTART + 6, RLENGTH - 6)
  a = ""; if (match($0, / aco=[^ ]* aso=[^ ]*/)) a = substr($0, RSTART + 1, RLENGTH - 1)
  p = ""; if (match($0, / pd=[^ ]*/)) p = substr($0, RSTART + 4, RLENGTH - 4)
  q = ""; if (match($0, / qs=apss:[^,]*/)) q = substr($0, RSTART + 4, RLENGTH - 4)
  i = ""; if (match($0, /irq=.* c0=/)) i = substr($0, RSTART + 4, RLENGTH - 8)
  b = ""; if (match($0, / busy=[^ ]*/)) b = substr($0, RSTART + 1, RLENGTH - 1)
  print at, d, a, b, p, q, i }' "$F"
echo "######## journal 10-17 18:00-18:25 (all, minus noisy)"
journalctl --since '2026-10-17 18:00' --until '2026-10-17 18:25' --no-pager -o short | grep -v -E 'sshd\[|pam_unix|session-[0-9]+\.scope|Accepted publickey|systemd-logind.*(New|Removed) session|CRON' | cut -c1-230 | head -150
echo "######## kernel 10-17 17:55-18:30"
journalctl -k --since '2026-10-17 17:55' --until '2026-10-17 18:30' --no-pager -o short | cut -c1-230 | tail -60
echo "######## lsmod changes? modules loaded from /usr/local/lib/modules"
lsmod | head -3; for m in ath12k ath12k_wifi7 mhi qrtr_mhi; do printf "%s: " $m; modinfo -n $m 2>/dev/null; cat /sys/module/$m/srcversion 2>/dev/null; done
echo "######## runtime-PM active devices now (power/runtime_status=active, excluding cpus)"
for d in $(find /sys/devices -name runtime_status 2>/dev/null); do s=$(cat $d 2>/dev/null); [ "$s" = active ] && echo "${d%/power/runtime_status}"; done | grep -v -E '/cpu[0-9]|/system/cpu' | sed 's#/sys/devices/##' | head -80
