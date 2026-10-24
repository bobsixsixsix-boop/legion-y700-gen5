#!/bin/bash
# ts-boost-measure.sh [ROUNDS] [VARIANTS...]: do the card gestures drop frames, and would a touch boost help?
# Root on the tablet, MOVES THE SCREEN (~20 s a variant): ask the owner first; no other session may be
# testing gestures at the same time. Opens a test Konsole fullscreen, then per round: swipe up and hold
# (cards open), two sideways drags over the cards, tap the card (back to the app), flick up (home), and
# brings the Konsole back. ts-frames.py traces frames and clocks; one block per variant.
# Variants (each set for its run only, restored after):
#   base     as it is (KWin threads uclamp.min 512 from y700-kwin-uclamp)
#   uclamp   KWin threads uclamp.min 1024
#   big      big cores (policy6) scaling_min_freq 3.13 GHz
#   gpu      GPU devfreq min_freq 600 MHz
#   gpu9     GPU devfreq min_freq 902 MHz
#   all      uclamp + big + gpu
# BG=video: a 1280x720 30 fps test video (mpv, lavfi testsrc2) plays in a window behind the Konsole, like a
# video left playing in an app: its card is live, KWin redraws it 30 times a second while the cards are up.
# 10-21 the first runs had that (a video app left open, ~40 frames/s on the panel while idle) and showed 24 %
# repeated frames in the hold against 2 % once it had stopped.
set -u
R=${1:-5}; shift 2>/dev/null
VARIANTS=("${@:-base uclamp big gpu all}"); VARIANTS=(${VARIANTS[*]})
D=$(dirname "$(readlink -f "$0")")
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
EVAL=/usr/local/libexec/kwin-eval.sh
FIFO=/run/y700-vtouch.fifo
P6=/sys/devices/system/cpu/cpufreq/policy6
GPU=/sys/class/devfreq/3d00000.gpu
read -r W H < <(echo 'out(workspace.virtualScreenSize.width + " " + workspace.virtualScreenSize.height)' | bash $EVAL) \
    || { echo "no answer from KWin"; exit 1; }
X=$((W / 2)); Y0=$((H - 1))
KW=$(pgrep -x -u 1000 kwin_wayland | while read -r p; do tr '\0' ' ' < /proc/$p/cmdline | grep -q -- --virtual || echo $p; done | head -1)

systemctl stop y700-vtouch 2>/dev/null
systemd-run --unit y700-vtouch --collect python3 /usr/local/libexec/y700-vtouch.py --rot r270 >/dev/null
for i in $(seq 20); do [ -p $FIFO ] && break; sleep 0.2; done
send() { printf '%s\n' "$@" > $FIFO; }
win() { printf 'for (const w of workspace.windowList()) if (w.pid == %s && w.normalWindow) { %s }\n' "$1" "$2" | bash $EVAL; }
active() { "${U[@]}" busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects activeEffects | grep -q '"y700-taskswitcher"' && echo true || echo false; }
closecards() { [ "$(active)" = true ] && { "${U[@]}" busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s y700-taskswitcher; sleep 1; }; }
hold() {   # same finger as taskswitcher-test.sh: 300 px ease-out in 500 ms, rest 600 ms
    local st=14 i j f lines=("down $X $Y0")
    for i in $(seq 1 $st); do f=$(( 1000 - (1000 - 1000 * i / st) ** 3 / 1000000 )); lines+=("move $X $((Y0 - 300 * f / 1000))" "sleep 35"); done
    for j in $(seq 1 10); do lines+=("move $X $((Y0 - 300 - j % 2))" "sleep 60"); done
    lines+=("up"); send "${lines[@]}"
}
fr() { python3 "$D/ts-frames.py" "$@"; }

restore() {
    for t in /proc/$KW/task/*; do uclampset -m 512 -p "${t##*/}" >/dev/null 2>&1; done
    [ -n "${P6MIN:-}" ] && echo "$P6MIN" > $P6/scaling_min_freq
    [ -n "${GMIN:-}" ] && echo "$GMIN" > $GPU/min_freq
}
cleanup() {
    restore; closecards
    [ -d /sys/kernel/tracing/instances/y700-tsframes ] && fr stop aborted >/dev/null 2>&1
    echo quit > $FIFO 2>/dev/null; sleep 0.3; systemctl stop y700-vtouch 2>/dev/null
    "${U[@]}" systemctl --user stop y700-tstest-win y700-tstest-bg 2>/dev/null
}
trap cleanup EXIT
P6MIN=$(cat $P6/scaling_min_freq); GMIN=$(cat $GPU/min_freq)

if [ "${BG:-}" = video ]; then
    "${U[@]}" systemctl --user stop y700-tstest-bg 2>/dev/null
    "${U[@]}" systemd-run --user --unit y700-tstest-bg --collect mpv --no-audio --loop --geometry=1280x720         --title=y700-tstest-bg 'av://lavfi:testsrc2=size=1280x720:rate=30' >/dev/null
    sleep 2
fi
"${U[@]}" systemctl --user stop y700-tstest-win 2>/dev/null
"${U[@]}" systemd-run --user --unit y700-tstest-win --collect konsole --separate --nofork >/dev/null
PID=$("${U[@]}" systemctl --user show -p MainPID --value y700-tstest-win)
for i in $(seq 40); do [ -n "$(win $PID 'out(w.resourceClass)')" ] && break; sleep 0.25; done
front() { win $PID 'w.minimized = false; w.fullScreen = true; workspace.activeWindow = w;'; sleep 1; }

for v in "${VARIANTS[@]}"; do
    restore
    case $v in
        uclamp|all) for t in /proc/$KW/task/*; do uclampset -m 1024 -p "${t##*/}" >/dev/null 2>&1; done ;;&
        big|all) echo 3129600 > $P6/scaling_min_freq ;;&
        gpu|all) echo 600000000 > $GPU/min_freq ;;
        gpu9) echo 902000000 > $GPU/min_freq ;;
    esac
    front; sleep 2     # let the clocks settle down to idle first
    fr start >/dev/null
    for r in $(seq "$R"); do
        fr mark "hold$r"; hold; sleep 1.6
        fr mark "scroll$r"; send "drag $((W * 3 / 4)) $((H / 2)) $((W / 4)) $((H / 2)) 250 12"; sleep 0.9
        send "drag $((W / 4)) $((H / 2)) $((W * 3 / 4)) $((H / 2)) 250 12"; sleep 0.9
        fr mark "tap$r"; send "tap $X $((H / 2))"; sleep 1.2
        fr mark "x$r"   # putting the test window back, not a gesture
        [ "$(active)" = true ] && { echo "  (round $r: cards still open after the tap)"; closecards; }
        front
        fr mark "flick$r"; send "drag $X $Y0 $X $((Y0 - 320)) 90 6"; sleep 1.2
        fr mark "x$r"; closecards; front; sleep 0.8
    done
    fr stop "$v"
done
