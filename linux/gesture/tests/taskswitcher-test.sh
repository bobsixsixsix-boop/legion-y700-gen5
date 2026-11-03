#!/bin/bash
# taskswitcher-test.sh: self-test of the bottom-edge task switcher (y700-taskswitcher effect) with the
# virtual touchscreen. VISIBLE on the tablet for about a minute (test windows open, the cards come up,
# cards get swiped away): tell the owner first. Run as root on the tablet after
# linux/gesture/taskswitcher/install.sh. Needs /usr/local/libexec/y700-vtouch.py and kwin-eval.sh
# (from linux/osk/tests), python3-tk for the "game" window.
#
# Cases: swipe up and hold -> cards; swipe a card up -> that window gets closeWindow (closed, not
# killed; 3 s later the effect starts y700-appquit@, which leaves this test's windows alone: they run in
# y700-tstest-* units, not app-*, see ts-scenarios/appquit.sh); the keyboard mapping mid-gesture does not lose the release (10-21 "卡片无法滑动");
# flick -> home (minimized, no cards); a "game" (X11 class steam_app_*) needs two swipes; opening the
# cards from an app activates no other window on the way (10-21 minimizeAll order);
# keyboard / control centre up -> no edge; the G9 shortcut opens the cards; closing the cards without
# choosing goes back to the app they were opened from, still fullscreen (10-21 stacked view, 「关卡片回原应用」).
# What vtouch cannot show: the real panel's first contact in the 8 px strip, and how it feels.
#
# Leaves things as they were: test windows closed, cards closed, vtouch stopped, keyboard and control
# centre hidden, windows that were not minimized un-minimized, the front window active again.
set -u
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
EVAL=/usr/local/libexec/kwin-eval.sh
FIFO=/run/y700-vtouch.fifo
fails=0

rot=$("${U[@]}" kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '/Rotation:/{print $2; exit}')
case "$rot" in
    8) vrot=r270 ;; 2) vrot=r90 ;; 1) vrot=none ;;
    *) echo "unsupported rotation '$rot' (vtouch.py maps 1/2/8)"; exit 1 ;;
esac
read -r W H < <(echo 'out(workspace.virtualScreenSize.width + " " + workspace.virtualScreenSize.height)' | bash $EVAL)
[ -n "${H:-}" ] || { echo "no screen size from KWin"; exit 1; }
X=$((W / 2)); Y0=$((H - 3))
echo "screen ${W}x${H}, rotation $rot -> vtouch --rot $vrot"
PREV=$(echo 'const a = workspace.activeWindow; out(a && a.normalWindow ? a.pid + " " + a.resourceClass : "")' | bash $EVAL)
# windows shown now ("pid:class" tokens on one line: kwin-eval.sh only reads back the first line a script
# prints, so with one per line only the first came back, 2026-10-21): un-minimized again at the end (the
# cards minimize everything)
SHOWN=$(echo 'out(workspace.windowList().filter(w => w.normalWindow && !w.minimized).map(w => w.pid + ":" + w.resourceClass).join(" "))' | bash $EVAL)

if grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 1.2; fi
"${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1

systemctl stop y700-vtouch 2>/dev/null
systemd-run --unit y700-vtouch --collect python3 /usr/local/libexec/y700-vtouch.py --rot $vrot >/dev/null
for i in $(seq 20); do [ -p $FIFO ] && break; sleep 0.2; done

active() { "${U[@]}" busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects activeEffects | grep -q '"y700-taskswitcher"' && echo true || echo false; }
shortcut() { "${U[@]}" busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s y700-taskswitcher; }
closecards() { [ "$(active)" = true ] && { shortcut; sleep 1; }; }

# wait until the window of pid $1 is there (up to 10 s), then 0.5 s more for its first frames. A fixed
# sleep was not enough (10-21: a cold Konsole mapped 3.6 s after launch, the first hold ran into it)
mapped() {
    local i
    for i in $(seq 40); do
        [ -n "$(win "$1" 'out(w.resourceClass)')" ] && { sleep 0.5; return 0; }
        sleep 0.25
    done
    echo "      (window of pid $1 not there after 10 s)"
}
konsole_up() {   # a fresh test Konsole, fullscreen and active; sets PID
    "${U[@]}" systemctl --user stop y700-tstest-win 2>/dev/null
    "${U[@]}" systemd-run --user --unit y700-tstest-win --collect konsole --separate --nofork >/dev/null
    PID=$("${U[@]}" systemctl --user show -p MainPID --value y700-tstest-win)
    mapped "$PID"
    win "$PID" 'w.fullScreen = true; workspace.activeWindow = w;'; sleep 0.6
}
game_up() {   # an X11 window with a game's class (Steam/Proton: steam_app_<id>); sets GPID
    local xa; xa=$(ls /run/user/1000/xauth_* 2>/dev/null | head -1)
    "${U[@]}" systemctl --user stop y700-tstest-game 2>/dev/null
    "${U[@]}" systemd-run --user --unit y700-tstest-game --collect -E DISPLAY=:0 -E XAUTHORITY="$xa" \
        python3 -c 'import tkinter as t; r = t.Tk(className="steam_app_424242"); r.title("y700 guard test"); r.geometry("900x600"); r.mainloop()' >/dev/null
    GPID=$("${U[@]}" systemctl --user show -p MainPID --value y700-tstest-game)
    mapped "$GPID"
    win "$GPID" 'w.minimized = false; workspace.activeWindow = w;'; sleep 0.6
    # an X11 window has no text-input protocol, so y700-osk's gate shows the keyboard when it takes the
    # focus (and the edge goes off, as designed): put it away for the swipes
    "${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1; sleep 0.8
}

cleanup() {
    closecards
    "${U[@]}" busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700-tsdiag >/dev/null 2>&1; rm -f /run/y700-tsdiag.js
    echo quit > $FIFO 2>/dev/null; sleep 0.3; systemctl stop y700-vtouch 2>/dev/null
    "${U[@]}" systemctl --user stop y700-tstest-win y700-tstest-game 2>/dev/null
    "${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1
    "${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1
    [ -z "$SHOWN" ] || printf 'const ids = "%s".split(" "); for (const w of workspace.windowList()) if (w.normalWindow && ids.includes(w.pid + ":" + w.resourceClass)) w.minimized = false;\n' "$SHOWN" | bash $EVAL
    [ -z "$PREV" ] || printf 'for (const w of workspace.windowList()) if (w.pid == %s && w.resourceClass == "%s" && w.normalWindow) { workspace.activeWindow = w; break; }\n' $PREV | bash $EVAL
}
trap cleanup EXIT

win() {   # $1 pid, $2 JS with w = that window
    printf 'for (const w of workspace.windowList()) if (w.pid == %s && w.normalWindow) { %s }\n' "$1" "$2" | bash $EVAL
}
send() { printf '%s\n' "$@" > $FIFO; }
# finger up from the bottom edge by $1 px in $2 ms, slowing down like a real finger (ease-out cubic),
# then resting $3 ms with 1 px jitter before lifting. The switcher's velocity (EWMA, px/ms) is only
# updated on touch motion and "cards" needs it under 0.5 px/ms: a constant-speed drag that stops dead
# keeps its last velocity and counts as a flick (= home).
hold() {
    local d=$1 ms=$2 st=14 i j f lines=("down $X $Y0")
    for i in $(seq 1 $st); do
        f=$(( 1000 - (1000 - 1000 * i / st) ** 3 / 1000000 ))   # 1 - (1 - i/st)^3, in thousandths
        lines+=("move $X $((Y0 - d * f / 1000))" "sleep $((ms / st))")
    done
    for j in $(seq 1 $(( $3 / 60 ))); do lines+=("move $X $((Y0 - d - j % 2))" "sleep 60"); done
    lines+=("up"); send "${lines[@]}"; sleep $(( (ms + $3) / 1000 + 1 ))
}
# the same hold, but runs the command "$4 ..." halfway up, while the finger is still down
hold_with() {
    local d=$1 ms=$2 rest=$3 st=14 i j f a=("down $X $Y0") b=(); shift 3
    for i in $(seq 1 $st); do
        f=$(( 1000 - (1000 - 1000 * i / st) ** 3 / 1000000 ))
        if [ $i -le $((st / 2)) ]; then a+=("move $X $((Y0 - d * f / 1000))" "sleep $((ms / st))")
        else b+=("move $X $((Y0 - d * f / 1000))" "sleep $((ms / st))"); fi
    done
    for j in $(seq 1 $(( rest / 60 ))); do b+=("move $X $((Y0 - d - j % 2))" "sleep 60"); done
    b+=("up")
    send "${a[@]}"; sleep "$(printf '0.%03d' $((ms / 2 + 50)))"
    "$@"
    send "${b[@]}"; sleep $(( (ms / 2 + rest) / 1000 + 1 ))
}
flick() { send "drag $X $Y0 $X $((Y0 - 320)) 90 6"; sleep 1.2; }
card_up() { send "drag $X $((H / 2)) $X $((H / 2 - 420)) 200 10"; sleep "${1:-1.5}"; }
# a FAIL prints what happened since the previous check: window activations and minimize changes (from the
# y700-tsdiag script, loaded for the whole run) and the switcher's own log lines (10-21: the first hold
# failed in 2 of 4 runs and the reason could not be told afterwards)
lastcheck=$(date '+%Y-%m-%d %H:%M:%S.%N' | cut -c1-23)
is() {   # $1 name, $2 got, $3 expected
    if [ "$2" = "$3" ]; then echo "PASS  $1"; else
        echo "FAIL  $1 (got $2, expected $3)"; fails=$((fails + 1))
        "${U[@]}" journalctl --user --since "$lastcheck" --no-pager -o short-precise             | grep -E 'y700tsdiag|y700-taskswitcher:|y700-home:' | sed 's/^[^ ]* [^ ]* //; s/ [^ ]* [^ ]*: / /; s/^/        | /' | tail -20
    fi
    lastcheck=$(date '+%Y-%m-%d %H:%M:%S.%N' | cut -c1-23)
}
alive() { kill -0 "$1" 2>/dev/null && echo true || echo false; }
minimized() { win "$1" 'out(w.minimized)'; }

printf '%s
' 'workspace.windowActivated.connect(w => print("y700tsdiag activated " + (w ? w.pid + ":" + w.resourceClass : "null")));'     'function y700tsdiag(w) { if (w.normalWindow) w.minimizedChanged.connect(() => print("y700tsdiag " + w.pid + ":" + w.resourceClass + " minimized=" + w.minimized)); }'     'workspace.windowList().forEach(y700tsdiag); workspace.windowAdded.connect(y700tsdiag);' > /run/y700-tsdiag.js
chmod 644 /run/y700-tsdiag.js
did=$("${U[@]}" busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss /run/y700-tsdiag.js y700-tsdiag | awk '{print $2}')
[ -n "$did" ] && "${U[@]}" busctl --user call org.kde.KWin "/Scripting/Script$did" org.kde.kwin.Script run

konsole_up
[ -n "$(win "$PID" 'out(w.resourceClass)')" ] || { echo "test Konsole not found (pid $PID)"; exit 1; }
lastcheck=$(date '+%Y-%m-%d %H:%M:%S.%N' | cut -c1-23)

hold 300 500 600;               is "swipe up and hold over a fullscreen window: cards open" "$(active)" true
card_up;                        is "swipe the card up: Konsole closed (closeWindow)" "$(alive $PID)" false
closecards

# a keyboard mapping while the finger is still on the edge (10-21, owner: cards opened from the desktop
# "无法滑动": there KWin's input method goes active on plasmashell and y700-osk maps under the cards).
# The edge has to stay until the gesture is over and the cards are gone: unregistered mid-gesture, the
# release is lost and the switcher hangs half-open, so the card swipe below would not close anything.
konsole_up
since=$(date '+%Y-%m-%d %H:%M:%S')
hold_with 300 500 600 "${U[@]}" /usr/local/bin/y700-osk show
                                is "keyboard maps mid-gesture: cards still open" "$(active)" true
card_up;                        is "keyboard maps mid-gesture: the card swipe still closes Konsole (release not lost)" "$(alive $PID)" false
closecards
"${U[@]}" journalctl --user --since "$since" --no-pager -o cat | grep -qF 'y700-taskswitcher: edge change held' \
    && echo "PASS  keyboard maps mid-gesture: edge change held until the cards closed" \
    || { echo "FAIL  no 'edge change held' line (old QML still running? re-login after install.sh)"; fails=$((fails + 1)); }
"${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1; sleep 1.2
last=$("${U[@]}" journalctl --user --since "$since" --no-pager -o cat | grep -F 'y700-taskswitcher: bottom edge' | tail -1)
                                is "keyboard hidden again: bottom edge back on" "${last##* }" on

konsole_up
flick;                          is "flick up: home (window minimized)" "$(minimized $PID)" true
                                is "flick up: no cards left open" "$(active)" false
win "$PID" 'out(w.fullScreen)' | grep -q true && echo "PASS  still fullscreen while minimized" \
    || { echo "FAIL  fullscreen state lost"; fails=$((fails + 1)); }

send "drag $X $((H - 200)) $X $((H - 500)) 300 12"; sleep 1.2
                                is "swipe starting mid-screen: nothing" "$(active)" false

game_up
if [ -z "$(win "$GPID" 'out(w.resourceClass)')" ]; then
    echo "FAIL  game window did not appear (python3-tk / XWayland?)"; fails=$((fails + 1))
else
    echo "      game window class: $(win "$GPID" 'out(w.resourceClass)')"
    hold 300 500 600;           is "game: cards open" "$(active)" true
    card_up 1.2;                is "game: first swipe only arms it (still running)" "$(alive $GPID)" true
    card_up 1.5;                is "game: second swipe within 3 s closes it" "$(alive $GPID)" false
    closecards
    game_up; hold 300 500 600; card_up 4.2
    card_up 1.2;                is "game: swipes 4 s apart do not close it (arm expires)" "$(alive $GPID)" true
    closecards

    # "close all" really closes everything unguarded: only run it when the owner has nothing else open
    # that it would close (guarded windows like Moonlight are fine, they stay)
    konsole_up; game_up
    others=$(printf 'out(workspace.windowList().filter(w => w.normalWindow && !w.skipSwitcher && w.pid != %s && w.pid != %s && !/(^|\\s)(steam_app_|steam_proton|gamescope|livi\\b|dev\\.f-io\\.livi)|moonlight/i.test(w.resourceClass + " " + w.desktopFileName)).map(w => w.resourceClass).concat(["END"]).join(" "))\n' "$PID" "$GPID" | bash $EVAL)
    # fail closed: it runs only on a reply that came back (ends in END) and names nothing else. 10-21 the
    # reply got lost (empty), the old [ -n ] test read that as "nothing else open", and close all shut the
    # browser and video app that were open
    if [ "$others" != END ]; then
        echo "SKIP  close all (would also close: ${others:-<no answer from KWin>})"
    else
        hold 300 500 600
        send "tap $X $((H * 904 / 1000))"; sleep 0.8   # the button under the cards (ui/TaskSwitcher.qml: height * .904)
                                is "close all: first tap only asks" "$(alive $PID)" true
        send "tap $X $((H * 904 / 1000))"; sleep 1.5
                                is "close all: second tap closes the Konsole" "$(alive $PID)" false
                                is "close all: the game stays" "$(alive $GPID)" true
    fi
    closecards
    "${U[@]}" systemctl --user stop y700-tstest-game 2>/dev/null

    # opening the cards from an app must not activate another window on the way (10-21: upstream's
    # minimizeAll minimized the active window first, KWin handed the focus to the next one for a moment,
    # and Claude desktop answered by un-minimizing itself behind the cards; closing them left it in front)
    konsole_up; game_up; win "$PID" 'w.minimized = false; workspace.activeWindow = w;'; sleep 0.6
    printf '%s\n' 'workspace.windowActivated.connect(w => print("y700tsmon activated " + (w ? w.resourceClass + (w.normalWindow ? " normal" : "") : "null")));' > /tmp/y700-tsmon.js
    chmod 644 /tmp/y700-tsmon.js
    since=$(date '+%Y-%m-%d %H:%M:%S')
    mid=$("${U[@]}" busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss /tmp/y700-tsmon.js y700-tsmon | awk '{print $2}')
    "${U[@]}" busctl --user call org.kde.KWin "/Scripting/Script$mid" org.kde.kwin.Script run
    shortcut; sleep 1.2
    "${U[@]}" busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700-tsmon >/dev/null
    rm -f /tmp/y700-tsmon.js
    acts=$("${U[@]}" journalctl --user --since "$since" --no-pager -o cat | grep -o 'y700tsmon activated .*' | cut -d' ' -f3-)
                                is "cards from an app: no other window activated on the way ($(echo $acts))" "$(grep -c ' normal$' <<< "$acts")" 0
                                is "cards from an app: the window behind stays minimized" "$(minimized $GPID)" true
    closecards
    "${U[@]}" systemctl --user stop y700-tstest-game 2>/dev/null
fi

konsole_up
"${U[@]}" /usr/local/bin/y700-osk show >/dev/null 2>&1; sleep 1
hold 300 500 600;               is "keyboard up: no cards" "$(active)" false
                                is "keyboard up: window untouched" "$(minimized $PID)" false
"${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1; sleep 1.2
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter show >/dev/null; sleep 0.8
hold 300 500 600;               is "control centre open: no cards" "$(active)" false
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null; sleep 0.8
win "$PID" 'w.minimized = false; workspace.activeWindow = w;'; sleep 0.5
hold 300 500 600;               is "both closed again: cards open" "$(active)" true
closecards

win "$PID" 'w.minimized = false; workspace.activeWindow = w;'; sleep 0.5
shortcut; sleep 1;              is "shortcut y700-taskswitcher (G9 double tap) opens the cards" "$(active)" true
shortcut; sleep 1.2;            is "shortcut again: cards closed" "$(active)" false
                                is "closing the cards goes back to the app: not minimized" "$(minimized $PID)" false
                                is "closing the cards goes back to the app: it is active"                                    "$(echo 'out(workspace.activeWindow ? workspace.activeWindow.pid : 0)' | bash $EVAL)" "$PID"
                                is "closing the cards goes back to the app: still fullscreen" "$(win "$PID" 'out(w.fullScreen)')" true
closecards

echo "--- journal"
"${U[@]}" journalctl --user --since "-4min" --no-pager -o cat | grep -E 'y700-(taskswitcher|home):' | tail -12
[ $fails = 0 ] && echo "ALL PASS" || echo "$fails FAILED"
