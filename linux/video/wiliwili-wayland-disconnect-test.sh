#!/bin/sh
# wiliwili-wayland-disconnect-test.sh [BIN] [TERM|KILL]: does wiliwili quit when its Wayland compositor goes away?
#
# Starts a throwaway headless KWin (virtual backend; its own runtime dir, D-Bus session, config and data:
# nothing on the screen, the running session untouched), runs BIN (default /usr/local/bin/wiliwili) on it
# with a throwaway config/cache (logged out, no proxy, no sound: its runtime dir has no PipeWire), waits until
# KWin shows its window, then stops that KWin with SIGTERM (what a logout does, default) or SIGKILL (a crash)
# and watches wiliwili for 15 s. Only TERM makes the old binary spin (7/7 on 10-21; KILL 0/3): a KWin that shuts
# down sends its last events before it closes the socket, a killed one sends nothing, and the spin needs events
# left in the queue (see below).
#   PASS  wiliwili exited within 10 s with status 0 (prints after how long and the CPU it used meanwhile)
#   FAIL  still running after 15 s (prints CPU % per second and the main thread's stack), or it died from a
#         signal / non-zero status (prints the status and the log tail)
# Logs of the last run stay in /tmp/y700-wwdisc-last/ (kwin.log, wili.log).
#
# Why (2026-10-21): after `systemctl restart sddm` the wiliwili of the previous login survived (systemd --user
# had not stopped), lost its Wayland connection with KWin and spun one core at 100 % for an hour without a
# window: libwayland had a fatal error (EPIPE) while events were still queued, so in GLFW's handleEvents
# wl_display_prepare_read() kept failing with EAGAIN and wl_display_dispatch_pending() kept failing with -1,
# forever. Fixed in GLFW by linux/video/wiliwili-glfw-wayland-disconnect.patch (README "wiliwili 断线退出").
# Run with the old binary (/root/wiliwili.bin.bak-20261021-wldisc) to see the spin; the fixed one exits in 0.75 s.
#
# Run as root (switches to user). Takes about 20-30 s; puts about one core of load on the tablet for the
# 15 s watch when the binary spins.
set -u
BIN=${1:-/usr/local/bin/wiliwili}; SIG=${2:-TERM}; U=user; LIMIT=10; WATCH=15
[ "$(id -u)" = 0 ] || { echo "FAIL: run as root"; exit 2; }
[ -x "$BIN" ] || { echo "FAIL: $BIN not executable"; exit 2; }
case $SIG in TERM|KILL) ;; *) echo "FAIL: signal must be TERM or KILL"; exit 2 ;; esac
T=$(mktemp -d /tmp/y700-wwdisc-XXXXXX) && [ -d "$T" ] || { echo "FAIL: mktemp"; exit 2; }
mkdir -p "$T/run" "$T/home" "$T/kconfig" "$T/kdata"
chmod 755 "$T"; chmod 700 "$T/run"; chown -R $U:$U "$T"
SOCK="y700-wwdisc-$$"
HZ=$(getconf CLK_TCK)
BASE="HOME=$T/home PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 XDG_RUNTIME_DIR=$T/run"

kwin_pid() { pgrep -u $U -f "^kwin_wayland --virtual .*--socket $SOCK\$"; }
wili_pid() { [ -s "$T/wpid" ] && [ -d "/proc/$(cat "$T/wpid")" ] && [ ! -s "$T/wexit" ] && cat "$T/wpid"; }   # $! of the sh below
ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null; }   # utime + stime of the whole process
cleanup() {
    w=$(wili_pid); [ -n "$w" ] && { kill "$w" 2>/dev/null; sleep 1; kill -9 "$w" 2>/dev/null; }
    k=$(kwin_pid); [ -n "$k" ] && { kill "$k" 2>/dev/null; sleep 1; kill -9 "$k" 2>/dev/null; }
    rm -rf /tmp/y700-wwdisc-last; mkdir -p /tmp/y700-wwdisc-last
    cp "$T/kwin.log" "$T/wili.log" /tmp/y700-wwdisc-last/ 2>/dev/null
    rm -rf "$T"
}
fail() { echo "FAIL: $1"; echo "  wiliwili log tail:"; tail -n 12 "$T/wili.log" 2>/dev/null | sed 's/^/  | /'; cleanup; exit 1; }

# 1. the test KWin. KDE_DEBUG=1: no KCrash handler restarting it. The wrapper saves its bus address for step 3.
sudo -u $U env -i $BASE XDG_CONFIG_HOME="$T/kconfig" XDG_DATA_HOME="$T/kdata" XDG_DATA_DIRS=/usr/local/share:/usr/share \
    KDE_DEBUG=1 timeout 120 dbus-run-session -- sh -c 'echo "$DBUS_SESSION_BUS_ADDRESS" > "$0"; exec kwin_wayland --virtual \
    --no-lockscreen --no-global-shortcuts --width 1600 --height 2560 --socket "$1"' "$T/kbus" "$SOCK" > "$T/kwin.log" 2>&1 &
i=0
while [ ! -S "$T/run/$SOCK" ]; do
    i=$((i + 1)); [ $i -gt 60 ] && fail "test KWin did not create its socket within 15 s ($(tail -n 3 "$T/kwin.log" | tr '\n' ' '))"
    sleep 0.25
done
KPID=$(kwin_pid); [ -n "$KPID" ] || fail "test KWin process not found"

# 2. wiliwili on it, under its own D-Bus session (like the real one, whose session bus outlives KWin). The sh in
#    between records the exit status ($? is 128 + N when killed by signal N). No core files (core_pattern=core).
sudo -u $U env -i $BASE WAYLAND_DISPLAY="$SOCK" XDG_SESSION_TYPE=wayland XDG_CONFIG_HOME="$T/home/.config" \
    XDG_CACHE_HOME="$T/home/.cache" XDG_DATA_HOME="$T/home/.local/share" \
    timeout 150 dbus-run-session -- sh -c 'ulimit -c 0; cd "$3"; "$1" & echo $! > "$0"; wait $!; echo $? > "$2"' \
    "$T/wpid" "$BIN" "$T/wexit" "$T/home" > "$T/wili.log" 2>&1 &

# 3. wait for its window: KWin's krunner interface lists windows by caption
win_up() {
    sudo -u $U env DBUS_SESSION_BUS_ADDRESS="$(cat "$T/kbus")" dbus-send --session --print-reply --dest=org.kde.KWin \
        /WindowsRunner org.kde.krunner1.Match string:wiliwili 2>/dev/null | grep -q '"wiliwili"'
}
i=0
until win_up; do
    i=$((i + 1)); [ $i -gt 60 ] && fail "no wiliwili window in the test KWin within 30 s"
    [ -z "$(wili_pid)" ] && [ $i -gt 4 ] && fail "wiliwili exited before its window appeared (status $(cat "$T/wexit" 2>/dev/null))"
    sleep 0.5
done
sleep 4   # let it settle into its main loop (first frames, network requests)
WPID=$(wili_pid); [ -n "$WPID" ] || fail "wiliwili exited on its own before the disconnect (status $(cat "$T/wexit" 2>/dev/null))"
echo "wiliwili $WPID up on test KWin $KPID ($BIN); sending SIG$SIG to KWin"

# 4. the disconnect
t0=$(ticks "$WPID"); kill -s "$SIG" "$KPID"
s=0; per=""; prev=$t0
while [ $s -lt $((WATCH * 4)) ]; do
    sleep 0.25; s=$((s + 1))
    if [ ! -d "/proc/$WPID" ]; then
        i=0; while [ ! -s "$T/wexit" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
        st=$(cat "$T/wexit" 2>/dev/null)
        secs=$(awk -v s=$s 'BEGIN{printf "%.2f", s / 4}')
        cpu=$(awk -v a="$t0" -v b="$prev" -v hz="$HZ" 'BEGIN{printf "%.2f", (b - a) / hz}')
        [ $s -gt $((LIMIT * 4)) ] && fail "wiliwili exited only after ${secs} s (status $st)"
        [ "$st" = 0 ] || fail "wiliwili exited after ${secs} s but with status $st$( [ "${st:-0}" -gt 128 ] 2>/dev/null && echo " (signal $((st - 128)))")"
        echo "PASS: wiliwili exited ${secs} s after SIG$SIG to KWin, status 0, ${cpu} s CPU meanwhile"
        cleanup; exit 0
    fi
    cur=$(ticks "$WPID"); [ -n "$cur" ] && prev=$cur
    [ $((s % 4)) = 0 ] && { per="$per $(awk -v a="$t0" -v b="$prev" -v hz="$HZ" -v n=$((s / 4)) 'BEGIN{printf "%d", (b - a) / hz / n * 100}')"; }
done
echo "  average CPU % of wiliwili since the disconnect, after 1..${WATCH} s:$per"
echo "  main thread: state $(awk '{print $3}' /proc/$WPID/stat) wchan $(cat /proc/$WPID/wchan 2>/dev/null)"
if command -v gdb >/dev/null; then
    timeout 30 gdb -p "$WPID" -batch -ex 'bt 12' 2>/dev/null | grep -E '^#' | sed 's/^/  | /'
fi
fail "wiliwili still running ${WATCH} s after SIG$SIG to KWin"
