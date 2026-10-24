#!/bin/bash
# 只读探测：dock 改造前看清平板上面板、Plasma 版本、可用的 dock 包。root 跑。
# 用法：bash probe.sh [截图输出路径]
U=user
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0"
H=/home/$U

echo "== versions"
$RUN plasmashell --version 2>&1 | head -1
dpkg-query -W -f='${Package} ${Version}\n' plasma-workspace kwin-wayland plasma-desktop libplasma6 qt6-base-dev-tools 2>/dev/null
for p in latte-dock crystal-dock nwg-dock nwg-dock-hyprland plank cairo-dock; do
  printf '%s: ' $p; apt-cache policy $p 2>/dev/null | sed -n 's/^ *Candidate: //p' | head -1; echo
done

echo "== screen"
$RUN kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Output|Geometry|Scale|Rotation|enabled' | head

echo "== appletsrc (panel containments)"
cat $H/.config/plasma-org.kde.plasma.desktop-appletsrc

echo "== plasmashellrc"
cat $H/.config/plasmashellrc

echo "== plasmarc / theme"
cat $H/.config/plasmarc 2>/dev/null
grep -A3 -E '^\[(KDE|General|Icons)\]' $H/.config/kdeglobals 2>/dev/null | head -30

echo "== kwinrc ScreenEdges / Plugins"
grep -A20 -E '^\[(ScreenEdges|Plugins|Effect-blur)\]' $H/.config/kwinrc | head -50

echo "== pinned / taskmanager launchers"
grep -n -E 'launchers|showOnlyCurrent|iconSpacing|maxStripes|groupingStrategy' $H/.config/plasma-org.kde.plasma.desktop-appletsrc

echo "== user idle (seconds since last input, via logind)"
loginctl show-user $U -p IdleHint -p IdleSinceHint 2>/dev/null
cat /sys/class/backlight/*/bl_power 2>/dev/null; cat /sys/class/backlight/*/brightness 2>/dev/null

if [ -n "$1" ]; then
  $RUN spectacle -b -n -f -o "$1" >/dev/null 2>&1 && echo "shot: $1"
fi
