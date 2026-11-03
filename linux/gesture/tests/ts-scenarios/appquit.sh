# ts-bed scenario (10-31): a swiped-away card quits its app, not only its window (taskswitcher/ui/AppQuit.qml). Its
# window gone, 3 s later systemd (here fake-systemd.py) gets StartUnit y700-appquit@PID_WINPIDS.service: PID owned
# the window, the WINPIDs own the windows still there (appquit.py decides; tests/test-appquit.py). Also after the
# cards are gone before those 3 s (AppQuit lives in main.qml's root, not in the view: Esc right after the swipe,
# 「全部关闭」 closing every card), and when the card came back but its window still went within 5 s. Not for a
# window that shows again within the 3 s, one that went more than 5 s after the swipe, one that went by itself, a
# game card. The installed build before this (71e8bd192443) never starts anything: tray, card-back, clear-all FAIL.
front() { eval_js "for (const w of workspace.stackingOrder) if (w.caption === '$1') { w.minimized = false; workspace.activeWindow = w; }"; }
refute() { tail -n +$((MARK + 1)) "$LOG" | grep -qF -- "$*" && { echo "TSBED_EXPECT_FAIL: unexpected $*"; FAIL=1; }; true; }
fx() { echo "tsbed fx=$(qdbus6 org.kde.KWin /Effects org.freedesktop.DBus.Properties.Get org.kde.kwin.Effects activeEffects 2>&1 | grep -c y700-taskswitcher)" >> "$LOG"; }
swipe_esc() {   # open the cards on window $1, swipe its card away, Esc 0.3 s later: the view is gone long before 3 s
    front "$1"; shortcut; sleep 1
    touch <<'T'
swipe 800 500 800 80 160
s 300
k 1
T
    sleep 1; fx
}
python3 "$T/bin/fake-systemd.py" >> "$LOG" 2>&1 &
i=0
while ! grep -q 'FAKESD up' "$LOG"; do
    i=$((i + 1)); [ $i -gt 40 ] && { echo "TSBED_EXPECT_FAIL: fake systemd not up"; FAIL=1; break; }
    sleep 0.25
done
app Kate '#3d7bf7'
KATE=$!
app Stubborn '#e67e22' ts-stubborn --refuse-close
STUB=$!
app Game '#c0392b' steam_app_1
GAME=$!
app Tray '#16a085' ts-tray --tray
TRAY=$!
app Again '#2980b9' ts-again --tray
AGAIN=$!

mark tray
swipe_esc Tray
expect 'tsbed fx=0'
sleep 3.5
shot 50-tray-swiped
expect "y700-taskswitcher: app quit: start y700-appquit@${TRAY}_"
expect "FAKESD StartUnit y700-appquit@${TRAY}_"
expect ".service replace"
refute "_${TRAY}_"
refute "_${TRAY}.service"
refute "FAKESD REJECTED"
refute "StartUnit failed"
kill -0 $TRAY 2>/dev/null || { echo "TSBED_EXPECT_FAIL: the tray app's process is gone (ts-app.py --tray should stay)"; FAIL=1; }

mark shows-again
swipe_esc Again
kill -USR1 $AGAIN   # its dock icon tapped, about 1.3 s after the swipe
sleep 3.5
expect "y700-taskswitcher: app quit: ${AGAIN} has a window again"
refute "y700-appquit@${AGAIN}"

mark card-back
front Stubborn
shortcut
sleep 1
touch <<'T'
swipe 800 500 800 80 160
T
sleep 2.2
expect 'card back, its window did not close'
touch <<'T'
k 1
T
kill $STUB   # "save?" answered about 2.5 s after the swipe: the window goes within the 5 s
sleep 4
expect "FAKESD StartUnit y700-appquit@${STUB}"

mark expired
app Late '#7f8c8d' ts-late --refuse-close
LATE=$!
swipe_esc Late
sleep 5
kill $LATE   # more than 5 s after the swipe
sleep 4
refute "y700-appquit@${LATE}"

mark by-itself
kill $KATE
sleep 4
refute "y700-appquit@${KATE}"

mark game
front Game
shortcut
sleep 1
touch <<'T'
swipe 800 500 800 80 160
T
sleep 1
touch <<'T'
swipe 800 500 800 80 160
T
sleep 4.5
eval_js 'print("tsbed game=" + workspace.stackingOrder.some(w => w.caption === "Game" && !w.deleted))'
expect 'tsbed game=false'
refute "y700-appquit@${GAME}"
touch <<'T'
k 1
T
sleep 1

mark clear-all
app A2 '#8e44ad' ts-a2 --tray
A2=$!
app B2 '#2c3e50' ts-b2 --tray
B2=$!
shortcut
sleep 1
touch <<'T'
d 0 800 905
s 60
u 0
s 400
d 0 800 905
s 60
u 0
T
sleep 2
fx
expect 'tsbed fx=0'
sleep 3
shot 51-after-clear
# every card closed, no window left: the instance names hold no other pid
expect "FAKESD StartUnit y700-appquit@${A2}.service replace"
expect "FAKESD StartUnit y700-appquit@${B2}.service replace"
expect "FAKESD StartUnit y700-appquit@${AGAIN}.service replace"
refute "FAKESD REJECTED"
