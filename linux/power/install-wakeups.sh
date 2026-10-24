#!/bin/sh
# install-wakeups.sh -- the screen-off wakeup reductions of linux/power/WAKEUPS.md, each one opt-in. Root, on the
# tablet, from a copy of linux/power/. Nothing here changes the kernel; every step says how to undo it.
#   --powerdevil   PowerDevil without libddcutil (drop-in for the user unit; -10 wakeups/s "display_recheck")
#   --tailscale    tailscaled without the 1 s portlist poller (drop-in; restarts tailscaled: do it from the LAN)
#   --freeze       the y700-screen-off-freeze user service (Claude desktop / Chrome frozen while the panel is off)
#   --all          the three above
# The helper patch (helperd-slow-poll.patch) is a build, not an install: see the patch header.
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
USER_NAME=user
HOME_DIR=/home/$USER_NAME
U="sudo -u $USER_NAME env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
do_pd=0; do_ts=0; do_fr=0
for a in "$@"; do
	case $a in
	--powerdevil) do_pd=1 ;;
	--tailscale) do_ts=1 ;;
	--freeze) do_fr=1 ;;
	--all) do_pd=1; do_ts=1; do_fr=1 ;;
	*) echo "usage: $0 [--powerdevil] [--tailscale] [--freeze] [--all]" >&2; exit 2 ;;
	esac
done
[ $# -gt 0 ] || { echo "usage: $0 [--powerdevil] [--tailscale] [--freeze] [--all]" >&2; exit 2; }

if [ $do_pd = 1 ]; then
	D=$HOME_DIR/.config/systemd/user/plasma-powerdevil.service.d
	install -d -o $USER_NAME -g $USER_NAME "$D"
	install -o $USER_NAME -g $USER_NAME -m 644 "$SRC/plasma-powerdevil-no-ddcutil.conf" "$D/y700-no-ddcutil.conf"
	$U systemctl --user daemon-reload
	$U systemctl --user restart plasma-powerdevil.service
	sleep 3
	pid=$(pidof org_kde_powerdevil || true)
	if [ -n "$pid" ] && tr '\0' '\n' < /proc/$pid/environ | grep -q '^POWERDEVIL_NO_DDCUTIL=1$'; then
		n=$(cat /proc/$pid/task/*/comm 2>/dev/null | grep -c display_recheck || true)
		echo "powerdevil: POWERDEVIL_NO_DDCUTIL=1 in effect, display_recheck threads: $n (want 0)"
	else
		echo "powerdevil: WARNING - variable not in the daemon's environment (pid '$pid'); journalctl --user -u plasma-powerdevil" >&2
	fi
	echo "  undo: rm $D/y700-no-ddcutil.conf; systemctl --user daemon-reload; systemctl --user restart plasma-powerdevil.service"
fi

if [ $do_ts = 1 ]; then
	case "${SSH_CONNECTION:-}" in
	100.*) echo "tailscale: this ssh session rides on the tailnet - run it from the LAN address, the restart would cut you off" >&2; exit 1 ;;
	esac
	D=/etc/systemd/system/tailscaled.service.d
	install -d "$D"
	install -m 644 "$SRC/tailscaled-wakeups.conf" "$D/y700-wakeups.conf"
	systemctl daemon-reload
	systemctl restart tailscaled.service
	sleep 3
	pid=$(pidof tailscaled || true)
	if [ -n "$pid" ] && tr '\0' '\n' < /proc/$pid/environ | grep -q '^TS_PORTLIST=false$'; then
		echo "tailscaled: TS_PORTLIST=false in effect ($(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["BackendState"])' 2>/dev/null || echo 'status unknown'))"
	else
		echo "tailscaled: WARNING - variable not in the daemon's environment (pid '$pid')" >&2
	fi
	echo "  undo: rm $D/y700-wakeups.conf; systemctl daemon-reload; systemctl restart tailscaled"
fi

if [ $do_fr = 1 ]; then
	install -m 755 "$SRC/y700-screen-off-freeze" /usr/local/libexec/y700-screen-off-freeze
	install -m 644 "$SRC/y700-screen-off-freeze.service" /etc/systemd/user/y700-screen-off-freeze.service
	$U systemctl --user daemon-reload
	$U systemctl --user enable --now y700-screen-off-freeze.service
	sleep 1
	echo "freeze: $($U systemctl --user is-active y700-screen-off-freeze.service); candidates now:"
	$U /usr/local/libexec/y700-screen-off-freeze --list | sed 's/^/    /'
	echo "  WARNING: a frozen Claude desktop freezes the agent sessions inside it (MATCH in ~/.config/y700-screen-off-freeze.conf)"
	echo "  undo: systemctl --user disable --now y700-screen-off-freeze.service (thaws on stop)"
fi
echo WAKEUPS_INSTALL_OK
