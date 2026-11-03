#!/bin/bash
# steam-pages.sh TAG - open a few Steam pages in the running Steam (library, store front, a game page, its community
# reviews, its store reviews) and screenshot each one to sb-real/tri/pages-TAG-N-*.png; prints the noise score of
# each. It touches nothing, so an on-screen keyboard brought up earlier stays over the lower 40 % of every shot.
# Run as root on the tablet from /root (next to noise-score.py), e.g. after steam-tri.sh cpu / steam-tri.sh default.
U=user; H=/home/$U; OUT=$H/sb-real/tri; TAG=$1
XA=$(sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment | grep '^XAUTHORITY=' | cut -d= -f2-)
R() { sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HOME=$H \
	DISPLAY=:0 XAUTHORITY=$XA WAYLAND_DISPLAY=wayland-0 "$@"; }
SHOTS=(); n=0
for u in steam://open/games steam://store \
	"steam://openurl/https://store.steampowered.com/app/1206560/" \
	"steam://openurl/https://steamcommunity.com/app/1206560/reviews/?browsefilter=toprated" \
	"steam://openurl/https://store.steampowered.com/app/1206560/#app_reviews_hash"; do
	R timeout 30 $H/.local/bin/steam-arm64 "$u" >/dev/null 2>&1
	sleep 12
	F=$OUT/pages-$TAG-$n-$(date +%H%M%S).png
	R spectacle -b -n -f -o $F 2>/dev/null; sleep 1.5; SHOTS+=($F); n=$((n + 1))
done
python3 /root/noise-score.py "${SHOTS[@]}"
