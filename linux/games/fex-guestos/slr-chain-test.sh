#!/bin/bash
# The whole chain Steam uses for an x86 Linux game on this tablet, without the Steam client:
#   FEX-Emu/fex-compat-tool -> FEX -> SteamLinuxRuntime_4/_v2-entry-point -> pressure-vessel container -> x86 program
# pressure-vessel imports the graphics stack named by /usr/share/guestos/fex-mesa/graphics_provider.json.
# Usage (root): slr-chain-test.sh [program args...]   default: the runtime's own vulkaninfo --summary
u=user; uid=$(id -u $u)
S=/home/$u/.local/share/Steam
C=/tmp/y700-slr-chain-test; install -d -o $u $C
[ $# -gt 0 ] || set -- /usr/bin/vulkaninfo --summary
# root's DBUS_SESSION_BUS_ADDRESS must not leak in: bwrap fails on /run/user/0/bus and the program never runs
runuser -u $u -- env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=wayland-0 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus ${VERBOSE:+STEAM_LINUX_RUNTIME_VERBOSE=1 PRESSURE_VESSEL_VERBOSE=1} \
	STEAM_COMPAT_DATA_PATH=$C STEAM_COMPAT_CLIENT_INSTALL_PATH=$S STEAM_COMPAT_APP_ID=0 \
	STEAM_COMPAT_TOOL_PATHS=$S/steamapps/common/SteamLinuxRuntime_4:$S/steamapps/common/FEX-Emu \
	timeout ${T:-240} python3 $S/steamapps/common/FEX-Emu/fex-compat-tool waitforexitandrun -- \
	$S/steamapps/common/SteamLinuxRuntime_4/_v2-entry-point --verb=waitforexitandrun -- "$@"
echo "exit $?"
