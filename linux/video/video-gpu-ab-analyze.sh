#!/bin/bash
# video-gpu-ab-analyze.sh [DIR]: per-window and per-profile summary of video-gpu-ab.sh samples.
# The owner keeps watching (content, brightness and seeks vary), so each window's mean battery power is also
# reported corrected to a common backlight with the measured slope (~0.78 mW per backlight level, README),
# plus the median (robust against a seek / UI burst) and the GPU frequency mean from the per-second samples.
# 2026-10-16.
D=${1:-/root/video-gpu-ab}
SLOPE=${SLOPE:-0.00078}     # W per backlight level
awk -F'\t' -v slope=$SLOPE '
NR == 1 { next }
$7 != "Discharging" { nondis++ }
{ w = $2; prof[w] = $3; n[w]++; W[w] += $4; B[w] += $5; G[w] += $6; v[w, n[w]] = $4; allB += $5; N++ }
function median(w,   i, j, t, a, m) { m = n[w]; for (i = 1; i <= m; i++) a[i] = v[w, i]
	for (i = 2; i <= m; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
	return m % 2 ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2 }
END {
	ref = allB / N
	printf "reference backlight %.0f (mean over all windows), slope %.2f mW/level%s\n", ref, slope * 1000, nondis ? sprintf(", WARNING %d samples not discharging", nondis) : ""
	for (w = 1; w in n; w++) {
		mw = W[w] / n[w]; mb = B[w] / n[w]; corr = mw - (mb - ref) * slope
		printf "window %d %-11s: %.2f W mean, median %.2f W, backlight %.0f -> %.2f W at the reference; GPU sample mean %.0f MHz (%d s)\n", w, prof[w], mw, median(w), mb, corr, G[w] / n[w], n[w]
		C[prof[w]] += corr; K[prof[w]]++
	}
	for (p in C) printf "profile %-11s: corrected mean %.2f W over %d windows\n", p, C[p] / K[p], K[p]
}' "$D/samples.tsv"
echo "--- windows.txt"; cat "$D/windows.txt"
