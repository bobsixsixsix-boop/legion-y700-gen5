#!/bin/sh
# kcm-never-test.sh: does opening KDE's power page (kcmshell6 kcm_mobile_power, powerdevil 6.6.6) rewrite the idle
# dim / screen-off times? It does when the [AC] profile says "never" without times: load() reads only [AC]
# (kcm_mobile/mobilepower.cpp, "we assume that the [AC], [Battery], and [LowBattery] groups have the same value"),
# the combo boxes' onCurrentIndexChanged (ui/main.qml:124/134) fire while the page loads, and since the remembered
# time is not 0 the setter saves "never" into all three profiles. 10-30 20:12:46 the battery pill's first page did
# exactly that (journal: "Setting to never screen off" / "never dim"), and from then on the screen stayed on when not
# switched off by hand. With [AC] times written as 0 the setters return early and nothing is saved.
# Runs the page offscreen against copies in a throwaway config dir and on its own session bus: neither the real
# powerdevilrc nor the running PowerDevil sees it, nothing shows on the screen. Root on the tablet (switches to
# user). Prints PASS / FAIL per case and the diff of a changed copy; exit 0 = both as expected. ~25 s.
#   live  the tablet's own powerdevilrc                               -> the page must leave it byte for byte
#   1024  10-24's file ([AC] never without times, battery 2 / 5 min)  -> the page turns battery screen-off to never
set -u
U=user; LIVE=/home/$U/.config/powerdevilrc
T=$(mktemp -d /tmp/y700-kcmnever-XXXXXX); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/live" "$T/1024"
cp "$LIVE" "$T/live/powerdevilrc" || { echo "FAIL: cannot read $LIVE"; exit 1; }
cat > "$T/1024/powerdevilrc" <<'EOF'
[AC][Display]
DimDisplayWhenIdle=false
LockBeforeTurnOffDisplay=false
TurnOffDisplayWhenIdle=false

[AC][SuspendAndShutdown]
AutoSuspendAction=0
PowerButtonAction=128

[Battery][Display]
DimDisplayIdleTimeoutSec=120
LockBeforeTurnOffDisplay=false
TurnOffDisplayIdleTimeoutSec=300

[Battery][SuspendAndShutdown]
AutoSuspendAction=0
PowerButtonAction=128
EOF
for c in live 1024; do
    cp "$T/$c/powerdevilrc" "$T/$c.before"
    mkdir -m 700 "$T/$c-rt"
done
chown -R "$U" "$T"; chmod 755 "$T"
for c in live 1024; do
    # timeout ends the page; 124 is the normal way out
    runuser -u "$U" -- env -i HOME=/home/$U PATH=/usr/bin:/bin XDG_CONFIG_HOME="$T/$c" XDG_RUNTIME_DIR="$T/$c-rt" \
        QT_QPA_PLATFORM=offscreen dbus-run-session -- timeout 10 kcmshell6 kcm_mobile_power > "$T/$c.log" 2>&1
done
rc=0
if cmp -s "$T/live.before" "$T/live/powerdevilrc"; then
    echo "PASS live: the page left the tablet's file as it was"
else
    echo "FAIL live: the page rewrote it:"; diff "$T/live.before" "$T/live/powerdevilrc"; rc=1
fi
if grep -A6 '^\[Battery\]\[Display\]' "$T/1024/powerdevilrc" | grep -qx 'TurnOffDisplayWhenIdle=false'; then
    echo "PASS 1024: the page set battery screen-off to never (the 10-30 bug reproduced, so the live case means something)"
else
    echo "FAIL 1024: the page did not write never; the live case proves nothing. Its log:"; tail -5 "$T/1024.log"; rc=1
fi
exit $rc
