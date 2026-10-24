#!/bin/bash
# gate-apps.sh: keyboard-popup cases for the other kinds of clients, each opened on a scratch file,
# placed on the right half (810,10 780x900) next to Telegram (left), tested, then closed:
#   Konsole, Kate          v2 show request on the PRESS over the text: tap it -> keyboard; Kate toolbar / tab bar -> none
#   gnome-text-editor      GTK4, text-input v3: tap the text -> keyboard; tap its header bar -> none
#   Dolphin                file list -> none
#   Konsole's title bar    server-side frame: drag -> none
# Run as root on the tablet with y700-vtouch running.
K=/usr/local/libexec
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
act() { echo "for (const w of workspace.windowList()) if (w.resourceClass == '$1' && w.normalWindow) workspace.activeWindow = w;" | $K/kwin-eval.sh >/dev/null; sleep 0.8; }
place() { echo "for (const w of workspace.windowList()) if (w.resourceClass == '$1' && w.normalWindow) { w.setMaximize(false, false); w.frameGeometry = { x: 810, y: 10, width: 780, height: 900 }; workspace.activeWindow = w; }" | $K/kwin-eval.sh >/dev/null; sleep 1; }
run() { QUIET=1 GATELINES=${GL:-5} $K/gate-run.sh "$@"; }
launch() {   # the plasmashell environment, as a desktop launch would get it
	local ps; ps=$(pgrep -u user -x plasmashell | head -1); mapfile -d '' senv < /proc/$ps/environ
	sudo -u user env -i "${senv[@]}" setsid "$@" >/dev/null 2>&1 &
	echo $!
}
close() { kill "$1" 2>/dev/null; sleep 1; kill -9 "$1" 2>/dev/null; }

echo "y700 gate test" > /tmp/y700-gate-test.txt; chmod 666 /tmp/y700-gate-test.txt

p=$(launch konsole --separate --workdir /tmp); sleep 3; place org.kde.konsole
act org.telegram.desktop; run konsole-act-tap "tap 1200 500 80" 2
run konsole-retap "tap 1200 520 80" 2
act org.telegram.desktop; run konsole-title-drag "drag 1300 25 1250 60 400 20" 2
close $p

p=$(launch kate -n /tmp/y700-gate-test.txt); sleep 4; place org.kde.kate
act org.telegram.desktop; run kate-act-tap "tap 1200 500 80" 2
# Kate active: its toolbar and tab bar are not text (Kate asks for the panel on the press over the editor only)
run kate-toolbar "tap 1292 102 80" 2
run kate-tabbar "tap 1197 136 80" 2
run kate-editor "tap 1102 285 80" 2
close $p

p=$(launch gnome-text-editor --standalone /tmp/y700-gate-test.txt); sleep 4; place org.gnome.TextEditor
act org.telegram.desktop; run gte-act-tap-text "tap 1200 400 80" 2
run gte-retap-text "tap 1200 420 80" 2
act org.telegram.desktop; run gte-act-tap-header "tap 1150 30 80" 2
close $p

p=$(launch dolphin --new-window /tmp); sleep 4; place org.kde.dolphin
act org.telegram.desktop; run dolphin-act-list "tap 1250 600 80" 2
close $p
rm -f /tmp/y700-gate-test.txt
