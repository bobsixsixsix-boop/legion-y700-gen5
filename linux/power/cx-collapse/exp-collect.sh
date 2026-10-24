#!/bin/bash
# exp-collect.sh STEP TAG [MIN]: after a cx-exp STEP (E1, E3a, ...) finished - record the run under /root/runs/TAG
# (read-only apart from that dir). Sums the flight recorder's pd= increments between "MARK ... STEP start" and
# "MARK ... STEP end", averages its bat= column over the same rows and keeps the recorder rows of the run, gzipped.
# MIN picks the run by its length ("MARK ... E4 start 40min", cx-exp.sh's "=== ... cx-exp E4 40 min"): the same step
# twice in one boot, e.g. E4:40 at E3a and E4@E3c:20 the same night (2026-10-18). Always check the selected start/end
# MARKs printed in the summary: their at= times say which night the run is from (one log per boot).
set -u
STEP=${1:?step, e.g. E3a}; TAG=${2:?run tag, e.g. E3a-20261016-0340}; MIN=${3:-}
R=/root/runs/$TAG; mkdir -p "$R"
# FRL=/var/log/y700-flightrec/flightrec-<id>.log for a run in an earlier boot (it reset: the log has no end MARK and
# the sums run to its last row; the "now" sections below are then this boot's, not the run's)
FRL=${FRL:-/var/log/y700-flightrec/current.log}
ASO=/sys/module/cpuidle_psci_domain/parameters/allow_system_off
START="$STEP start"; [ -n "$MIN" ] && START="$STEP start ${MIN}min"
HDR="cx-exp $STEP "; [ -n "$MIN" ] && HDR="cx-exp $STEP $MIN min "
{
echo "=== $(date '+%F %T') $(uname -r) up $(cut -d. -f1 /proc/uptime)s boot_id $(cat /proc/sys/kernel/random/boot_id)"
echo "== boots (the run must be inside the last one)"; journalctl --list-boots --no-pager -q | tail -3
echo "== cx-exp unit"; systemctl list-units --all 'y700-cx-exp*' --no-legend; pgrep -fa "cx-exp.sh $STEP" | grep -v "pgrep\|bash -c" || echo "no cx-exp process"
echo "== knobs now"; echo "aco=$(cat /sys/module/cpuidle_psci_domain/parameters/allow_cluster_off) aso=$([ -e $ASO ] && cat $ASO || echo -) dl=$(cat /sys/module/qcom_scm/parameters/download_mode) dpms=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1) bat=$(cat /sys/class/power_supply/qcom-battmgr-bat/status)/$(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%"
echo "== pd idle_states"; for d in cluster cluster1 system; do echo "-- $d"; cat /sys/kernel/debug/pm_genpd/power-domain-$d/idle_states; done
echo "== cpuidle state1 per cpu (usage/rejected/time us)"; for c in 0 3 5 6 7; do s=/sys/devices/system/cpu/cpu$c/cpuidle/state1; echo "cpu$c $(cat $s/name) usage=$(cat $s/usage) rej=$(cat $s/rejected) time=$(cat $s/time)"; done
echo "== qcom_stats"; for s in apss cxsd aosd ddr; do echo "-- $s: $(tr '\n' ' ' < /sys/kernel/debug/qcom_stats/$s | cut -c1-160)"; done
echo "== 1043 report lines"; dmesg | grep -F "power-domain-system: allow_system_off" | tail -4
echo "== kernel trouble lines in the last 200 min"; journalctl -k --since "-200min" -o cat | grep -E "WARNING:|BUG:|Oops|SError|Unhandled fault|timed out in resp|TCS Busy|vblank timeout|failed to flush" | sort | uniq -c | sort -rn | head -10
echo "== flightrec MARKs"; grep -h MARK "$FRL" | tail -6
echo "== selected run: the last \"MARK ... $START\" and the end MARK after it"
awk -v S="$START" -v E="$STEP end" 'index($0, "MARK") && index($0, S){s=$0; e=""} index($0, "MARK") && index($0, E) && s != "" && e == ""{e=$0} END{print s; print (e == "" ? "(no end MARK after it)" : e)}' "$FRL"
echo "== flightrec MODE lines inside the run (want: MODE fast right after the start MARK)"
awk -v S="$START" -v E="$STEP end" 'index($0, "MARK") && index($0, S){p=1; buf=""} p && /^MODE /{buf=buf $0 "\n"} index($0, "MARK") && index($0, E){p=0} END{printf "%s", buf}' "$FRL"
echo "== flightrec sums between MARK $START and MARK $STEP end (pd= and qs= are both per-row increments)"
awk -v S="$START" -v E="$STEP end" -F'pd=' 'index($0, "MARK") && index($0, S){on=1; n=0; s0=r0=s1=r1=sy=ry=0; delete qc; delete qm; nb=0; sb=0; z=0; t0=""; next} index($0, "MARK") && index($0, E){on=0}
  on && NF>1 {split($2,a," "); split(a[1],b,","); split(b[1],c,":"); split(c[2],u,"/"); s0+=u[1]; r0+=u[2];
             split(b[2],d,":"); split(d[2],v,"/"); s1+=v[1]; r1+=v[2]; split(b[3],e,":"); split(e[2],w,"/"); sy+=w[1]; ry+=w[2];
             if (split(a[2],q,"=")==2) {split(q[2],qq,","); for (i=1;i<=4;i++){split(qq[i],kv,":"); split(kv[2],cn,"/"); qc[i]+=cn[1]; sub(/^\+/,"",cn[2]); qm[i]+=cn[2]}}
             # bat=<+mW>: the gauge is read every ~5 s and repeated in between, so the row mean is a time mean; 0 = a
             # dropped firmware read (seen 2026-10-16), left out and counted
             if (match($1, /bat=[-+]?[0-9]+mW/)) {mw=substr($1, RSTART+4, RLENGTH-6)+0; if (mw == 0) z++; else {sb+=mw; nb++}}
             if (match($1, /t=[0-9.]+/) && t0 == "") t0=substr($1, RSTART+2, RLENGTH-2)+0; if (match($1, /t=[0-9.]+/)) t1=substr($1, RSTART+2, RLENGTH-2)+0
             n++}
  END{printf "rows=%d  cl0 use=%d rej=%d  cl1 use=%d rej=%d  sys use=%d rej=%d\n", n, s0, r0, s1, r1, sy, ry;
      printf "qcom_stats entries / ms summed: apss +%d / +%d ms  cxsd +%d / +%d  aosd +%d / +%d  ddr +%d / +%d\n", qc[1], qm[1], qc[2], qm[2], qc[3], qm[3], qc[4], qm[4];
      span=(n > 1 ? t1-t0 : 0); printf "span %.0f s (%.2f rows/s)  residency apss %.0f %%  cxsd %.0f %%  aosd %.0f %%  ddr %.0f %%\n", span, (span > 0 ? (n-1)/span : 0), (span > 0 ? qm[1]/10/span : 0), (span > 0 ? qm[2]/10/span : 0), (span > 0 ? qm[3]/10/span : 0), (span > 0 ? qm[4]/10/span : 0);
      printf "bat mean %.0f mW over %d rows (%d zero reads left out)\n", (nb ? sb/nb : 0), nb, z}' "$FRL"
} > "$R/summary.txt" 2>&1
# (all passes keep only the LAST run that matches, so with several runs of the same step in one boot only the last counts;
# the cx-exp log section ends at the next "=== " header - the next step, or cx-when-idle's own lines)
awk -v H="$HDR" 'index($0, "=== ") == 1 {p=0} index($0, "=== ") == 1 && index($0, H){p=1; buf=""} p{buf=buf $0 "\n"} END{printf "%s", buf}' /var/log/y700-cx-exp.txt > "$R/cx-exp-$STEP.txt"
awk -v S="$START" -v E="$STEP end" 'index($0, "MARK") && index($0, S){p=1; buf=""} p{buf=buf $0 "\n"} index($0, "MARK") && index($0, E){p=0} END{printf "%s", buf}' "$FRL" | gzip -9 > "$R/flightrec-$STEP.log.gz"
ls -la "$R"; cat "$R/summary.txt"
