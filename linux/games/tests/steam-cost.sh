#!/bin/bash
# steam-cost.sh TAG - put the running Steam on WorldBox's reviews again and run steam-cost.py TAG there; screenshot
# before and after, so the numbers can be checked against where the page really was (the trailer at the top of
# the page plays by itself and would be measured as "idle"). Run as root on the tablet from /root, next to
# steam-cost.py, with Steam started by steam-tri.sh (which also starts y700-vtouch).
U=user; H=/home/$U; OUT=$H/sb-real/tri; TAG=$1
XA=$(sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment | grep '^XAUTHORITY=' | cut -d= -f2-)
R() { sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HOME=$H \
	DISPLAY=:0 XAUTHORITY=$XA WAYLAND_DISPLAY=wayland-0 "$@"; }
R timeout 30 $H/.local/bin/steam-arm64 "steam://openurl/https://store.steampowered.com/app/1206560/#app_reviews_hash" >/dev/null 2>&1
sleep 12
# any touch on the page brings up the on-screen keyboard and Steam's window shrinks to the space above it
# (page about y 121-566 in logical pixels): let that happen now, not during the measurement
echo "tap 60 300" > /run/y700-vtouch.fifo; sleep 4
R spectacle -b -n -f -o $OUT/cost-$TAG-before-$(date +%H%M%S).png 2>/dev/null; sleep 1.5
python3 /root/steam-cost.py $TAG
R spectacle -b -n -f -o $OUT/cost-$TAG-after-$(date +%H%M%S).png 2>/dev/null; sleep 1.5
ls -t $OUT/cost-$TAG-* | head -2
