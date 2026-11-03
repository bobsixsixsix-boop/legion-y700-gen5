#!/bin/bash
# steam-tri.sh TAG [VAR=VALUE ...] - restart Steam (no game running) on the GPU with zink's default render-pass
# tracking (Y700_STEAM_UI=gpu-rp, the setting that shows the noise) plus the given variables, open WorldBox's store
# page at its reviews, screenshot six scroll positions and score the noise blocks; prints which Vulkan driver and
# variables the steamwebhelper GPU process really got. README "Steam 界面花屏" has the 10-30 results.
# steam-tri.sh default... - the same with the launcher's default (GPU, ZINK_DEBUG=norp).
# steam-tri.sh cpu...     - the same with CPU drawing (Y700_STEAM_UI=cpu), the reference.
# steam-tri.sh restore    - restart the normal Steam (launcher default, no extra variables), stop vtouch, screen off.
# Run as root on the tablet from /root, next to noise-score.py and linux/osk/tests/vtouch.py; screenshots go to
# ~user/sb-real/tri. The six shots are three page positions: the touch that scrolls the page also brings up
# the on-screen keyboard, and the next drag starts on the keyboard, which only hides it (shots 0/2/4 show it).
U=user; H=/home/$U; L=$H/.local/share/Steam/logs/webhelper_gpu.txt; OUT=$H/sb-real/tri
TAG=$1; shift
XA=$(sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment | grep '^XAUTHORITY=' | cut -d= -f2-)
R() { sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HOME=$H \
	DISPLAY=:0 XAUTHORITY=$XA WAYLAND_DISPLAY=wayland-0 "$@"; }
if pgrep -x 'reaper|wineserver' >/dev/null || pgrep -f 'steamapps/common' >/dev/null; then echo "GAME RUNNING - not restarting"; exit 1; fi
mkdir -p $OUT && chown $U: $OUT
R kscreen-doctor --dpms on >/dev/null 2>&1
OLD=$(pgrep -o -u $U -x steam); START=$(wc -l < $L)
if [ -n "$OLD" ]; then
	R timeout 60 $H/.local/bin/steam-arm64 -shutdown >/dev/null 2>&1 &
	for i in $(seq 90); do kill -0 $OLD 2>/dev/null || break; sleep 1; done
	kill -0 $OLD 2>/dev/null && { echo "STILL RUNNING after 90 s - not relaunching"; exit 1; }
	echo "old steam $OLD exited after ${i}s"; sleep 3
fi
case "$TAG" in
restore|default*) SETENV=() ;;
cpu*) SETENV=(-E Y700_STEAM_UI=cpu) ;;
*) SETENV=(-E Y700_STEAM_UI=gpu-rp) ;;
esac
for kv in "$@"; do SETENV+=(-E "$kv"); done
UNIT=app-steam-arm64-tri-$TAG-$(date +%s)
R systemd-run --user --collect --slice=app.slice --unit=$UNIT "${SETENV[@]}" $H/.local/bin/steam-arm64 >/dev/null \
	&& echo "started $UNIT with: ${SETENV[*]}"
for i in $(seq 90); do pgrep -u $U -f steamwebhelper >/dev/null && break; sleep 1; done
echo "webhelper up after ${i}s"; sleep 25
# zygote children keep the zygote's command line, so the GPU process is the child that loaded the Vulkan driver
WH=""; GPU=""
for p in $(pgrep -u $U -f steamwebhelper); do
	c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
	case "$c" in
	*--type=*) grep -q libvulkan_freedreno /proc/$p/maps 2>/dev/null && GPU=$p ;;
	*steamwebhelper*) WH=$p ;;
	esac
done
echo "browser process $WH: $(tr '\0' ' ' < /proc/$WH/cmdline 2>/dev/null | grep -oE -- '--disable-gpu[a-z-]*' | tr '\n' ' ')"
if [ -n "$GPU" ]; then
	echo "gpu process $GPU env: $(tr '\0' '\n' < /proc/$GPU/environ | grep -E '^(TU_DEBUG|IR3_SHADER_DEBUG|ZINK_DEBUG|VK_DRIVER_FILES|VK_ICD_FILENAMES|Y700_STEAM_UI)=' | tr '\n' ' ')"
	echo "gpu process maps: $(grep -oE '/[^ ]*libvulkan_freedreno[^ ]*' /proc/$GPU/maps | sort -u | tr '\n' ' ')"
else
	echo "no gpu process"
fi
tail -n +$START $L | grep -E 'GL_RENDERER|gpu_compositing|\[ rasterization \]' | cut -c1-160 | tail -3
if [ "$TAG" = restore ]; then
	[ -p /run/y700-vtouch.fifo ] && echo quit > /run/y700-vtouch.fifo
	sleep 2; R kscreen-doctor --dpms off >/dev/null 2>&1; echo "restored; screen off"; exit 0
fi
systemctl is-active -q y700-vtouch || systemd-run --unit y700-vtouch --collect python3 /root/vtouch.py >/dev/null 2>&1
for i in $(seq 20); do [ -p /run/y700-vtouch.fifo ] && break; sleep 0.5; done
R timeout 30 $H/.local/bin/steam-arm64 "steam://openurl/https://store.steampowered.com/app/1206560/#app_reviews_hash" >/dev/null 2>&1
sleep 15
SHOTS=()
for n in 0 1 2 3 4 5; do
	if [ $n -gt 0 ]; then echo "drag 1000 850 1000 350 600 20" > /run/y700-vtouch.fifo; sleep 3; fi
	F=$OUT/$TAG-$n-$(date +%H%M%S).png
	R spectacle -b -n -f -o $F 2>/dev/null; sleep 1.5; SHOTS+=($F)
done
python3 /root/noise-score.py "${SHOTS[@]}"
