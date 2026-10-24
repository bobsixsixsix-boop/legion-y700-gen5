#!/bin/bash
# chrome-yt-bisect.sh: the 2026-10-18 evening run list for "why does the YouTube page cost ~1.4-2 W more than a plain
# <video> page in Chrome". ROOT, from /root/y700-cvp; start it with chrome-video-power-ab-when-idle.sh (visible test,
# only runs when the owner is away). Needs URL=<youtube watch page> in the environment. Results are copied to
# /root/chrome-video-power-ab-runs/yt-bisect-<name>/ after each part (chrome-video-power-ab.sh empties its own dir).
#   r1  A W W A L X   the page, rest of page hidden, ..., the local clip, overlays + rest of page hidden
#   r2  N V V N       no extension, bare <video> fullscreen
#   wifi  screen-off Wi-Fi receive cost at the stream's bitrate (wifi-rx-cost.sh)
cd "$(dirname "$0")" || exit 2
R=/root/chrome-video-power-ab-runs
keep() { mkdir -p $R/yt-bisect-$1; cp /root/chrome-video-power-ab/samples.tsv /root/chrome-video-power-ab/windows.txt $R/yt-bisect-$1/ 2>/dev/null; }
CFGS="A W W A L X" ./chrome-video-power-ab.sh 45; rc=$?; keep r1; [ $rc = 0 ] || exit $rc
CFGS="N V V N" ./chrome-video-power-ab.sh 45; rc=$?; keep r2; [ $rc = 0 ] || exit $rc
./wifi-rx-cost.sh; cp /root/wifi-rx-cost.txt $R/yt-bisect-wifi.txt 2>/dev/null
