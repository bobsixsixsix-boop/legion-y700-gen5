#!/bin/bash
# y700-hud-cost-ab.sh OLD_DIR NEW_DIR [WINDOW_S] [PROFILE]: y700-hud-cost.sh once with the overlay files in OLD_DIR
# installed, then once with NEW_DIR's (VISIBLE, like y700-hud-cost.sh; ROOT, run with systemd-run). Each DIR holds
# the files to put into ~user/.local/bin (y700-hud-overlay, y700-hudinfo, y700_hud_sampler.py when that
# version uses it, a binary...) and optionally override.conf: a drop-in for y700-hud-overlay.service (e.g. the
# Rust port's ExecStart), installed as y700-hud-overlay.service.d/y700-ab.conf - absent, that drop-in is removed.
# At the end FINAL_DIR's set is installed (env FINAL, default NEW_DIR). Results: /root/y700-hud-cost-{old,new}/,
# or with env TAG=x /root/y700-hud-cost-x-{old,new}/.
# 2026-10-16: shell sampler vs in-process sampler, in a game (PROFILE game: vkcube under MangoHud); Python vs Rust.
set -u
OLD=$1; NEW=$2; WIN=${3:-60}; PROF=${4:-game}; FINAL=${FINAL:-$NEW}; T=${TAG:+$TAG-}
B=~user/.local/bin
D=~user/.config/systemd/user/y700-hud-overlay.service.d
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
put() {
	local f
	for f in "$1"/*; do
		case ${f##*/} in
			override.conf) ;;
			*.py) install -o user -g user -m 644 "$f" $B/ ;;
			*) install -o user -g user -m 755 "$f" $B/ ;;
		esac
	done
	# the shell-sampler era had no module: take it away so that version runs as it did
	[ -e "$1/y700_hud_sampler.py" ] || [ -e "$1/override.conf" ] || rm -f $B/y700_hud_sampler.py
	if [ -e "$1/override.conf" ]; then
		install -d -o user -g user $D; install -o user -g user -m 644 "$1/override.conf" $D/y700-ab.conf
	else
		rm -f $D/y700-ab.conf
	fi
	"${U[@]}" systemctl --user daemon-reload
}
trap 'put "$FINAL"' EXIT
for v in old new; do
	[ $v = old ] && put "$OLD" || put "$NEW"
	/root/y700-hud-cost.sh "$WIN" "$PROF"; rc=$?
	rm -rf /root/y700-hud-cost-$T$v; cp -r /root/y700-hud-cost /root/y700-hud-cost-$T$v
	if [ $rc = 4 ]; then exit 4; fi      # the owner touched the screen: stop, do not start the second half
done
exit 0                                  # (a trailing "[ ] && exit 4" made the script's status 1: a chained run stopped)
