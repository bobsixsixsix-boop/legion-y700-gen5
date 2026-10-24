#!/bin/bash
# 2026-10-18: when did the system domain (apps-pc) stop being entered with the screen off? 10-min buckets of this
# boot's flight recorder log: rows, rows with dpms=Off, rows with aco=Y aso=Y, sys use sum, apss count sum, bat mean,
# top 3 IRQ sources in the bucket (read-only)
export LC_ALL=C
F=${1:-/var/log/y700-flightrec/current.log}
awk '
function fld(name,   v) { if (match($0, " " name "=[^ ]*")) { v = substr($0, RSTART + length(name) + 2, RLENGTH - length(name) - 2); return v } return "" }
/^t=/ {
  t = substr($1, 3) + 0; b = int(t / 600)
  if (!(b in lab)) { lab[b] = substr(fld("at"), 1, 5); ord[++nb] = b }
  rows[b]++
  if (fld("dpms") == "Off") off[b]++
  if (fld("aco") == "Y" && fld("aso") == "Y") arm[b]++
  pd = fld("pd"); split(pd, p, ","); split(p[3], s, ":"); split(s[2], u, "/"); sys[b] += u[1]; rej[b] += u[2]
  qs = fld("qs"); split(qs, q, ","); split(q[1], a, ":"); split(a[2], an, "/"); ap[b] += an[1]
  bt = fld("bat"); gsub(/[+mW]/, "", bt); if (bt + 0 != 0) { sb[b] += bt; nbt[b]++ }
  if (match($0, /irq=.* c0=/)) { ir = substr($0, RSTART + 4, RLENGTH - 8); n = split(ir, li, ",")
    for (i = 1; i <= n; i++) { k = li[i]; sub(/:[0-9]+$/, "", k); c = li[i]; sub(/.*:/, "", c); irq[b SUBSEP k] += c; names[k] = 1 } }
}
END {
  printf "%-5s %5s %5s %5s %7s %5s %7s %6s  %s\n", "at", "rows", "off", "arm", "sysuse", "rej", "apss", "batmW", "top irq (summed counts)"
  for (i = 1; i <= nb; i++) { b = ord[i]
    top = ""; delete used
    for (j = 1; j <= 3; j++) { best = ""; bv = 0; for (k in names) if (!(k in used) && irq[b SUBSEP k] > bv) { bv = irq[b SUBSEP k]; best = k }
      if (best != "") { used[best] = 1; top = top best ":" bv "  " } }
    printf "%-5s %5d %5d %5d %7d %5d %7d %6.0f  %s\n", lab[b], rows[b], off[b], arm[b], sys[b], rej[b], ap[b], (nbt[b] ? sb[b] / nbt[b] : 0), top }
}' "$F"
