#!/bin/bash
# Run x86 Vulkan/GL probes from the FEX guest rootfs through Steam's own FEX compat tool (as the desktop user),
# the way Steam launches an x86 Linux game, minus pressure-vessel. Usage (root): fex-guest-test.sh [vkcube]
u=user; uid=$(id -u $u)
F=/home/$u/.local/share/Steam/steamapps/common/FEX-Emu
C=/tmp/y700-fex-guest-test; install -d -o $u $C
run() {
	runuser -u $u -- env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 \
		STEAM_COMPAT_DATA_PATH=$C timeout "${T:-60}" python3 $F/fex-compat-tool waitforexitandrun "$@"
}
echo "== x86 uname / glibc"; run /usr/bin/uname -m 2>&1 | tail -1
echo "== vulkaninfo --summary (x86_64)"; run /usr/bin/vulkaninfo --summary 2>&1 | grep -E "GPU id|deviceName|driverName|driverInfo|apiVersion|conformanceVersion|ERROR|error" | head -12
echo "== eglinfo -B (x86_64, GL via freedreno gallium)"; run /usr/bin/eglinfo -B 2>&1 | grep -E "OpenGL (core|ES) profile (renderer|version)|renderer string|error" | head -6
if [ "$1" = vkcube ]; then
	echo "== vkcube 8 s on screen"; T=8 run /usr/bin/vkcube --wsi wayland 2>&1 | tail -3
fi
