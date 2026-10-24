#!/bin/bash
# gamemon.sh PATTERN [SAMPLES] [INTERVAL]: CPU/GPU/thermal sampler for a running game
PAT=${1:-Shipping\.exe}; N=${2:-8}; T=${3:-5}
P=$(pgrep -f "[${PAT:0:1}]${PAT:1}" | head -1)
[ -n "$P" ] || { echo "no process matching $PAT"; exit 1; }
echo "game pid $P: $(tr '\0' ' ' < /proc/$P/cmdline | cut -c1-120)"
HZ=$(getconf CLK_TCK)
gpu_ns() { local s=0; for f in /proc/[0-9]*/fdinfo/*; do v=$(awk '/^drm-engine-gpu:/{print $2}' "$f" 2>/dev/null); [ -n "$v" ] && s=$((s+v)); done 2>/dev/null; echo $s; }
ticks() { awk '{print $14+$15}' /proc/$P/stat; }
declare -A th
for t in /proc/$P/task/*; do th[${t##*/}]=$(awk '{print $14+$15}' $t/stat 2>/dev/null); done
a=$(ticks); g=$(gpu_ns); s0=$(date +%s%N)
for i in $(seq $N); do
  sleep $T
  b=$(ticks); h=$(gpu_ns); s1=$(date +%s%N); dt=$(( (s1-s0)/1000000 ))
  cpu=$(( (b-a)*100*1000/HZ/dt ))
  gpu=$(( (h-g)/10000/dt ))
  top3=$(for t in /proc/$P/task/*; do id=${t##*/}; n=$(awk '{print $14+$15}' $t/stat 2>/dev/null); p=${th[$id]:-$n}; th[$id]=$n; echo "$(( (n-p)*100*1000/HZ/dt )) $(cat $t/comm)"; done | sort -rn | head -3 | tr '\n' ',')
  f0=$(( $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)/1000 ))
  f6=$(( $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq)/1000 ))
  gf=$(( $(cat /sys/class/devfreq/3d00000.gpu/cur_freq)/1000000 ))
  th_=$(tb323fu-ctl thermal 2>/dev/null | awk '/surface/{s=$2}/cpu \(max\)/{c=$3}/gpu \(max\)/{g=$3}/throttling/{t=$2}END{print "surf "s" cpu "c" gpu "g" thr "t}')
  printf "%2d) game CPU %4d%%  top: %s  little %4dMHz big %4dMHz | GPU %3dMHz busy %3d%% | %s\n" $i $cpu "$top3" $f0 $f6 $gf $gpu "$th_"
  a=$b; g=$h; s0=$s1
done
