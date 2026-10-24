#!/bin/sh
# smoke.sh DIR: start the task-switcher effect in DIR (contents/ + metadata.json, what install.sh builds)
# in a throwaway headless KWin and check that it comes up. Virtual backend, its own D-Bus session, config,
# data and runtime dirs: nothing on the screen, nothing shared with the running session, none of our
# other plugins or scripts loaded (effects enabled by default still are, e.g. the installed upscale
# effect). Prints SMOKE_OK, or SMOKE_FAIL with the reason and the log tail.
#
# Why (2026-10-21): KWin caches compiled QML by file URL until the next login, so a reinstall never runs
# the new QML in the live session, and every test after it still exercises the old one. A null
# dereference in the new main.qml crash-looped kwin_wayland at the next login until SDDM gave up and
# showed the greeter. This runs the new QML before the real session ever does; install.sh calls it
# before it replaces anything.
#
# Run as root (switches to user) or as user. Takes about 5 s, at most 25 s.
# smoke.sh --control: the same test KWin with no effect of ours, alive after 5 s = SMOKE_CONTROL_OK. Tells "our QML
# breaks" from "a test KWin cannot start here at all" (y700-taskswitcher-aptcheck, after a KWin upgrade, 10-23).
set -u
DIR=$1; U=user
CONTROL=; [ "$DIR" = --control ] && CONTROL=1
[ -n "$CONTROL" ] || [ -f "$DIR/contents/ui/main.qml" ] || { echo "SMOKE_FAIL: $DIR/contents/ui/main.qml missing"; exit 1; }
T=$(mktemp -d /tmp/y700-tssmoke-XXXXXX)
mkdir -p "$T/config" "$T/data/kwin/effects" "$T/run"
[ -n "$CONTROL" ] || cp -r "$DIR" "$T/data/kwin/effects/y700-taskswitcher"
# as the real session (install.sh): y700-home gives up the bottom edge. It is in user's ~/.local/share and
# does not load here; written anyway so the config stays the real one (see tests/ts-bed.sh)
printf '[Plugins]\ny700-taskswitcherEnabled=true\n\n[Script-y700-home]\nBottomEdge=false\n' > "$T/config/kwinrc"
printf '[General]\nnavigationPanelEnabled=false\nconvergenceModeEnabled=true\n' > "$T/config/plasmamobilerc"
chmod 700 "$T/run"
[ "$(id -u)" = 0 ] && chown -R $U:$U "$T"
SOCK="y700-smoke-$$"
as_user() { if [ "$(id -u)" = 0 ]; then sudo -u $U "$@"; else "$@"; fi; }
# KDE_DEBUG=1: no KCrash handler, so a crash ends the process instead of restarting it
as_user env -i HOME=/home/$U PATH=/usr/bin:/bin LANG=C.UTF-8 XDG_RUNTIME_DIR="$T/run" \
    XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_DATA_DIRS=/usr/local/share:/usr/share KDE_DEBUG=1 \
    timeout 25 dbus-run-session -- kwin_wayland --virtual --no-lockscreen --no-global-shortcuts \
    --width 1600 --height 2560 --socket "$SOCK" > "$T/log" 2>&1 &
done_() { pkill -u $U -f "^kwin_wayland --virtual .*--socket $SOCK" 2>/dev/null; sleep 0.5; rm -rf "$T"; }
fail() { echo "SMOKE_FAIL: $1"; tail -n 15 "$T/log" | sed 's/^/  | /'; done_; exit 1; }

if [ -n "$CONTROL" ]; then
    sleep 5
    pgrep -u $U -f "^kwin_wayland --virtual .*--socket $SOCK" >/dev/null || fail "test KWin (no effect of ours) exited within 5 s"
    echo "SMOKE_CONTROL_OK"
    done_
    exit 0
fi

i=0
while ! grep -q 'y700-taskswitcher: loaded' "$T/log"; do
    i=$((i + 1)); [ $i -gt 60 ] && fail "no 'y700-taskswitcher: loaded' within 15 s"
    pgrep -u $U -f "^kwin_wayland --virtual .*--socket $SOCK" >/dev/null || [ $i -lt 8 ] || fail "test KWin exited before the effect loaded"
    sleep 0.25
done
sleep 3   # what crashed at login ran right after the load; give the rest of the start-up time too
pgrep -u $U -f "^kwin_wayland --virtual .*--socket $SOCK" >/dev/null || fail "test KWin died after loading the effect"
grep -q 'y700-taskswitcher: bottom edge on' "$T/log" || fail "the effect never set its bottom edge (no 'bottom edge on')"
err=$(grep -E 'y700-taskswitcher/contents/ui/[A-Za-z]+\.qml:[0-9]+:.*(Error|is not defined|Cannot (read|assign|call))' "$T/log")
[ -z "$err" ] || fail "QML errors: $(echo "$err" | head -3)"
echo "SMOKE_OK $(grep -o 'y700-taskswitcher: loaded .*' "$T/log" | head -1 | cut -d' ' -f3)"
done_
exit 0
