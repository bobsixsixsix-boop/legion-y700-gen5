#!/bin/bash
# probe-chrome.sh start|stop: a throw-away Chrome (own profile in /tmp) on tests/touchprobe.html for gate-chrome.sh
# and gate-steam.sh (cases 8, 9),
# started with the plasmashell environment and the desktop entry's text-input flags.
pidf=/tmp/y700-probe-chrome.pid
case "$1" in
start)
	ps=$(pgrep -u user -x plasmashell | head -1); mapfile -d '' senv < /proc/$ps/environ
	sudo -u user env -i "${senv[@]}" setsid /usr/bin/google-chrome-stable --user-data-dir=/tmp/y700-probe-chrome \
		--password-store=basic --no-first-run --no-default-browser-check --remote-debugging-port=9333 \
		--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3 \
		file:///usr/local/src/y700-osk/tests/touchprobe.html >/dev/null 2>&1 < /dev/null &
	echo $! > $pidf
	sleep 6
	echo "probe chrome pid $(cat $pidf)"
	;;
stop)
	p=$(cat $pidf 2>/dev/null); [ -n "$p" ] || exit 0
	kill "$p" 2>/dev/null; sleep 2; kill -9 "$p" 2>/dev/null
	rm -f $pidf
	;;
esac
