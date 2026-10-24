#!/bin/bash
# 2026-10-18: this morning's flight-recorder rows cut by wall-clock window (at=HH:MM:SS): mean battery power, cluster0 /
# system domain entries per second, apss residency, cxsd entries. Read-only. Args: LABEL=HH:MM:SS-HH:MM:SS ...
export LC_ALL=C
FRL=${FRL:-/var/log/y700-flightrec/current.log}
for w in "$@"; do
	l=${w%%=*}; r=${w#*=}; a=${r%-*}; b=${r#*-}
	awk -v L="$l" -v A="$a" -v B="$b" '/^t=/ && match($0, /at=[0-9:]+/) {at = substr($0, RSTART + 3, RLENGTH - 3)
		if (at < A || at > B) next
		if (match($0, /bat=[-+]?[0-9]+mW/)) {mw = substr($0, RSTART + 4, RLENGTH - 6) + 0; if (mw != 0) {sb += mw; nb++}}
		if (match($0, /dpms=[A-Za-z]+/)) dp[substr($0, RSTART + 5, RLENGTH - 5)]++
		if (match($0, /aco=[YN-]/)) ac[substr($0, RSTART + 4, 1)]++
		if (match($0, /pd=cl0:[0-9]+\/[0-9]+,cl1:[0-9]+\/[0-9]+,sys:[0-9]+/)) {split(substr($0, RSTART, RLENGTH), p, /[:\/,]/); c0 += p[2]; c1 += p[5]; sy += p[8]}
		if (match($0, /qs=apss:[0-9]+\/\+?[0-9]+,cxsd:[0-9]+/)) {split(substr($0, RSTART, RLENGTH), q, /[:\/,]/); sub(/^\+/, "", q[3]); am += q[3]; cx += q[5]}
		if (match($0, /^t=[0-9.]+/)) {t = substr($0, 3, RLENGTH - 2) + 0; if (t0 == "") t0 = t; t1 = t}
		n++}
		END {s = t1 - t0; if (s <= 0) s = 1
		     d = ""; for (k in dp) d = d k ":" dp[k] " "; e = ""; for (k in ac) e = e k ":" ac[k] " "
		     printf "%-10s %s-%s rows %4d  bat %4.0f mW  cl0 %5.1f/s  cl1 %5.1f/s  sys %5.1f/s  apss %3.0f%%  cxsd +%d  | dpms %s aco %s\n", L, A, B, n, (nb ? sb / nb : 0), c0 / s, c1 / s, sy / s, am / 10 / s, cx, d, e}' "$FRL"
done
