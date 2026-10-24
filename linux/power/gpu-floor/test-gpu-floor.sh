#!/bin/bash
# test-gpu-floor.sh [BINARY] (2026-10-18): the y700-gpu-floor daemon against a FAKE sysfs (a temp dir; needs no root, touches
# no real GPU), with a stub tb323fu-ctl and a process called "chrome" (a copy of sleep) standing in for the browser.
# Checks: floor raised on playing+fullscreen, held, given back after RELEASE_S (screen off, fullscreen=0, state file
# gone, browser dead), raised again when someone resets it, never lowers a higher profile floor (performance), ignores
# other players, `--release` after a kill -9, no-helper fallback to the lowest OPP, a state directory that appears later,
# no ceiling while the wait-boost shim is loaded in the browser (and the ceiling back when its switch says Y0), the 10 s
# look while a video plays (panel back on / switch flipped without a state-file write), the floor not stuck when a reset
# is noticed without the helper, a FIFO in the state directory not hanging the daemon. Takes about a minute.
# LIVE=1 (root, on the tablet, the daemon installed): also one pass on the real GPU with a fake state file.
BIN=${1:-$(dirname "$0")/target/release/y700-gpu-floor}
[ -x "$BIN" ] || BIN=/usr/local/sbin/y700-gpu-floor
echo "testing $BIN"
T=$(mktemp -d /tmp/y700-gf-test.XXXX)
fails=0; DPID=
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
SLP="sleep 3000.$$"   # unique: cleanup kills only this test's sleeps
cleanup() { [ -n "$DPID" ] && kill $DPID 2>/dev/null; pkill -f "^$T/chrome" 2>/dev/null; pkill -x -f "$SLP" 2>/dev/null; rm -rf $T; }
trap cleanup EXIT
G=$T/gpu; V=$T/video; mkdir -p $G $V
echo "160000000 191000000 222000000 282000000 342000000 1200000000" > $G/available_frequencies
echo 160000000 > $G/min_freq; echo 1200000000 > $G/max_freq
echo On > $T/dpms; echo balanced > $T/profile
printf 'FLOOR_MHZ=282\nRELEASE_S=1\nCEIL_MHZ=400\n' > $T/conf
cat > $T/ctl <<'EOF'
#!/bin/bash
D=$(dirname "$0")
if [ "$1 $2" = "gpu limits" ]; then echo "$*" >> $D/ctl.calls; echo $(( $4 * 1000000 )) > $D/gpu/min_freq; echo $(( $5 * 1000000 )) > $D/gpu/max_freq; exit 0; fi
P=$(cat $D/profile)
printf 'Gpu:\n  CpuBoost: true\n  CpuLimits: \n      balanced: 384 3628 768 4396\n  Floors: \n      balanced: 160 1200\n      performance: 461 1200\n      power-saver: 160 726\n  FollowPowerProfiles: false\n  Profile: %s\n  WifiAvailable: true\n' "$P"
EOF
chmod +x $T/ctl
cp /bin/bash $T/chrome   # comm "chrome" (the Ubuntu sleep is a multi-call binary and would not run under that name)
fake_chrome() { "$T/chrome" -c "$SLP; :" & }
fake_chrome; CPID=$!
export Y700_GPU_DIR=$G Y700_VIDEO_DIR=$V Y700_DPMS=$T/dpms Y700_STATE=$T/state Y700_CTL=$T/ctl Y700_CONF=$T/conf
min() { local v; v=$(<$G/min_freq); echo $(( ${v:-0} / 1000000 )); }   # empty while someone rewrites it
max() { local v; v=$(<$G/max_freq); echo $(( ${v:-0} / 1000000 )); }
want() { # EXPECTED_MHZ SECONDS: min_freq reaches the value in time
	local i; for i in $(seq $(( $2 * 10 ))); do [ "$(min)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
wantmax() { # EXPECTED_MHZ SECONDS: the same for max_freq
	local i; for i in $(seq $(( $2 * 10 ))); do [ "$(max)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
state() { # NAME PID PLAYING FULLSCREEN: written like the native host (tmp + rename)
	printf 'pid=%s\nplaying=%s\nfullscreen=%s\nosd=0\n' "$2" "$3" "$4" > $V/$1.tmp; mv $V/$1.tmp $V/$1; }
start() { "$BIN" > $T/log 2>&1 & DPID=$!; sleep 0.5; }
# the switch file next to the video dir says Y0 until the shim part below: with the shim in /etc/ld.so.preload every fake
# browser maps it too, and Y0 is what makes the daemon treat it as absent (no preload: not mapped, same result)
SW=$T/y700-no-waitboost.ctl; printf Y0 > $SW

start
[ "$(min)" = 160 ] && ok "idle: floor untouched (160 MHz)" || bad "idle min $(min)"
state chrome-$CPID $CPID 1 1
want 282 2 && ok "chrome playing full screen: floor 282 MHz" || bad "floor not raised (min $(min)); $(cat $T/log)"
wantmax 342 2 && ok "ceiling lowered (CEIL_MHZ=400 -> the OPP 342)" || bad "ceiling not lowered (max $(max))"
[ -s $T/state ] && ok "state file written for --release" || bad "no state file"
sleep 2.5
[ "$(min)" = 282 ] && ok "held while the video plays (longer than RELEASE_S)" || bad "floor lost while playing (min $(min))"
echo Off > $T/dpms; state chrome-$CPID $CPID 1 1
want 160 3 && ok "screen off: floor given back" || bad "screen off, min $(min)"
grep -q 'gpu limits balanced 160 1200' $T/ctl.calls && ok "given back through the helper (gpu limits balanced 160 1200)" || bad "no helper call: $(cat $T/ctl.calls 2>&1)"
[ "$(max)" = 1200 ] && ok "ceiling given back with the floor (max 1200)" || bad "ceiling left at $(max)"
[ ! -e $T/state ] && ok "state file removed on release" || bad "state file left"
echo On > $T/dpms; state chrome-$CPID $CPID 1 1
want 282 2 && ok "screen on again: raised again" || bad "not raised again (min $(min))"
state chrome-$CPID $CPID 1 0
want 160 3 && wantmax 342 3 && ok "playing, not full screen: floor given back, ceiling kept" || bad "fullscreen=0, min $(min) max $(max)"
state chrome-$CPID $CPID 0 0; sleep 0.4
[ "$(max)" = 342 ] && ok "not playing: still held before RELEASE_S (1 s)" || bad "released before RELEASE_S (max $(max))"
wantmax 1200 4 && ok "not playing: ceiling given back after RELEASE_S" || bad "not playing, max $(max)"
state chrome-$CPID $CPID 1 1; want 282 2 >/dev/null
echo 160000000 > $G/min_freq; state chrome-$CPID $CPID 1 1   # the helper re-applies its profile; the host rewrites the file
want 282 3 && ok "floor reset by someone else: raised again" || bad "reset not noticed (min $(min))"
echo 1200000000 > $G/max_freq; state chrome-$CPID $CPID 1 1
wantmax 342 3 && ok "ceiling raised by someone else: lowered again" || bad "max reset not noticed (max $(max))"
rm $V/chrome-$CPID
want 160 3 && ok "state file removed (browser closed): given back" || bad "state file removed, min $(min)"
state chrome-$CPID $CPID 1 1; want 282 2 >/dev/null
fake_chrome; CPID2=$!; kill $CPID; wait $CPID 2>/dev/null; state chrome-$CPID2 $CPID2 0 0   # the first browser is dead, state file stale
want 160 3 && [ -e $V/chrome-$CPID ] && ok "browser gone (its state file still says playing): given back" || bad "browser gone, min $(min)"
rm -f $V/chrome-$CPID
kill $CPID2 2>/dev/null
fake_chrome; CPID=$!
state mpv-$CPID $CPID 1 1; sleep 1
[ "$(min)" = 160 ] && ok "other players (mpv-<pid>) ignored" || bad "mpv state raised the floor (min $(min))"
rm -f $V/mpv-$CPID
echo performance > $T/profile; state chrome-$CPID $CPID 1 1; sleep 1.5
[ "$(min)" = 160 ] && [ "$(max)" = 1200 ] && grep -q 'nothing to do' $T/log && ok "performance profile (461 >= 282): nothing done, ceiling too" || bad "performance profile, min $(min) max $(max)"
echo balanced > $T/profile; rm -f $V/chrome-$CPID; sleep 0.5; state chrome-$CPID $CPID 1 1; want 282 2 >/dev/null
kill -9 $DPID; wait $DPID 2>/dev/null; sleep 0.3
[ "$(min)" = 282 ] && [ "$(max)" = 342 ] && [ -s $T/state ] && ok "kill -9 leaves the floor and ceiling up (as ExecStopPost expects)" || bad "after kill -9: min $(min) max $(max)"
"$BIN" --release >> $T/log 2>&1
[ "$(min)" = 160 ] && [ "$(max)" = 1200 ] && [ ! -e $T/state ] && ok "--release gives both back" || bad "--release: min $(min) max $(max)"
rm -f $V/chrome-$CPID
state chrome-$CPID $CPID 1 1; Y700_CTL=/nonexistent start; want 282 2 >/dev/null
echo 1200000000 > $G/max_freq; state chrome-$CPID $CPID 1 1
wantmax 342 3 && want 282 2 && ok "no helper: ceiling raised by someone else, both set again" || bad "no helper, reset: min $(min) max $(max)"
rm $V/chrome-$CPID; want 160 3 && [ "$(max)" = 1200 ] && grep -q 'helper unavailable' $T/log && ok "no helper: lowest OPP, highest OPP as ceiling (floor not stuck)" || bad "no helper fallback, min $(min) max $(max)"
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
printf 'FLOOR_MHZ=282\nRELEASE_S=1\nCEIL_MHZ=0\n' > $T/conf   # ceiling off
start; state chrome-$CPID $CPID 1 1
want 282 2 && sleep 0.3 && [ "$(max)" = 1200 ] && ok "CEIL_MHZ=0: floor raised, ceiling left alone" || bad "CEIL_MHZ=0: min $(min) max $(max)"
rm $V/chrome-$CPID; want 160 3 >/dev/null
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
printf 'FLOOR_MHZ=282\nRELEASE_S=1\nCEIL_MHZ=400\nCEIL_WHEN=fullscreen\n' > $T/conf   # ceiling only in full screen
start; state chrome-$CPID $CPID 1 0; sleep 1.5
[ "$(max)" = 1200 ] && [ "$(min)" = 160 ] && ok "CEIL_WHEN=fullscreen: playing alone touches nothing" || bad "CEIL_WHEN=fullscreen, playing: min $(min) max $(max)"
state chrome-$CPID $CPID 1 1
wantmax 342 2 && ok "CEIL_WHEN=fullscreen: full screen sets floor and ceiling" || bad "CEIL_WHEN=fullscreen, full screen: max $(max)"
rm $V/chrome-$CPID; want 160 3 >/dev/null
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
printf 'FLOOR_MHZ=282\nRELEASE_S=1\nCEIL_MHZ=400\n' > $T/conf
V0=$V; V=$T/late; export Y700_VIDEO_DIR=$V; start
mkdir $V; state chrome-$CPID $CPID 1 1
want 282 7 && ok "state directory appears later: watched within 5 s" || bad "late directory, min $(min)"
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null; DPID=
# the wait-boost shim (a library named y700-no-waitboost.so mapped in the browser process, switch file next to the video dir)
# removes the storm at its source: no ceiling then, the floor stays. Y0 in the switch file brings the ceiling back.
V=$V0; export Y700_VIDEO_DIR=$V; printf Y1 > $SW
LIB=$(ls /lib/*-linux-gnu/libz.so.1 /usr/lib/*-linux-gnu/libz.so.1 2>/dev/null | head -1)
cp "$LIB" $T/y700-no-waitboost.so
LD_PRELOAD=$T/y700-no-waitboost.so "$T/chrome" -c "$SLP; :" & SPID=$!; sleep 0.4
grep -q y700-no-waitboost /proc/$SPID/maps && ok "test setup: the fake browser has the shim library mapped" || bad "test setup: shim library not mapped in $SPID"
start; state chrome-$SPID $SPID 1 1
want 282 2 && sleep 0.5 && [ "$(max)" = 1200 ] && ok "shim loaded: floor raised, no ceiling (nothing to cap)" || bad "shim loaded, full screen: min $(min) max $(max)"
printf Y0 > $SW; state chrome-$SPID $SPID 1 1
wantmax 342 3 && ok "shim switched off (Y0): ceiling comes back" || bad "Y0 not noticed (max $(max))"
printf Y1 > $SW; state chrome-$SPID $SPID 1 1
wantmax 1200 3 && want 282 2 && ok "shim switched on again (Y1): ceiling given back, floor set again" || bad "Y1 not noticed (min $(min) max $(max))"
state chrome-$SPID $SPID 1 0; want 160 3 && [ "$(max)" = 1200 ] && ok "shim loaded, playing in the page: nothing held" || bad "shim, fullscreen=0: min $(min) max $(max)"
printf Y0 > $SW   # no state-file write: only the 10 s look can see it
wantmax 342 12 && ok "shim switched off while playing in the page, no state write: ceiling within 10 s" || bad "Y0 without a state write not seen (max $(max))"
printf Y1 > $SW; state chrome-$SPID $SPID 1 1; want 282 2 >/dev/null
echo Off > $T/dpms; state chrome-$SPID $SPID 1 1; want 160 3 >/dev/null
echo On > $T/dpms   # panel back on, the state file unchanged
want 282 12 && ok "panel back on during a full-screen video, no state write: floor within 10 s" || bad "panel on not seen (min $(min))"
state chrome-$SPID $SPID 1 1; want 282 3 >/dev/null   # held, whatever the step above did
mkfifo $V/chrome-fifo; state chrome-$SPID $SPID 1 0   # a FIFO read would block forever: the release below would never come
want 160 3 && kill -0 $DPID && ok "a FIFO in the state directory does not hang the daemon" || bad "daemon gone or stuck with a FIFO present (min $(min))"
rm -f $V/chrome-fifo $V/chrome-$SPID; sleep 0.3
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null; DPID=
kill $SPID 2>/dev/null

if [ "${LIVE:-0}" = 1 ]; then
	U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
	unset Y700_GPU_DIR Y700_VIDEO_DIR Y700_DPMS Y700_STATE Y700_CTL Y700_CONF
	RG=/sys/class/devfreq/3d00000.gpu; RV=/run/user/1000/y700-video; DP=$(ls /sys/class/drm/card*-DSI-1/dpms | head -1)
	dpms0=$(cat $DP); [ "$dpms0" = Off ] && { "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 3; }
	systemctl is-active --quiet y700-gpu-floor || bad "LIVE: y700-gpu-floor is not running"
	f=$(sed -n 's/^FLOOR_MHZ=//p' /etc/default/y700-gpu-floor | head -1); f=${f:-282}
	base=$(( $(cat $RG/min_freq) / 1000000 ))
	state chrome-$CPID $CPID 1 1 2>/dev/null; V=$RV; state chrome-$CPID $CPID 1 1
	sleep 1.5; m=$(( $(cat $RG/min_freq) / 1000000 ))
	[ "$m" -ge "$f" ] && ok "LIVE: floor raised ($base -> $m MHz, config $f)" || bad "LIVE: floor not raised ($base -> $m)"
	c=$(sed -n 's/^CEIL_MHZ=//p' /etc/default/y700-gpu-floor | head -1); c=${c:-500}; mx=$(( $(cat $RG/max_freq) / 1000000 ))
	[ "$c" = 0 ] || { [ "$mx" -le "$c" ] && ok "LIVE: ceiling lowered (max $mx MHz, config $c)" || bad "LIVE: ceiling not lowered (max $mx, config $c)"; }
	rm -f $RV/chrome-$CPID; sleep 5; m=$(( $(cat $RG/min_freq) / 1000000 )); mx=$(( $(cat $RG/max_freq) / 1000000 ))
	[ "$m" -le "$base" ] && [ "$mx" -ge 1200 ] && ok "LIVE: floor and ceiling given back ($m..$mx MHz)" || bad "LIVE: not given back (min $m MHz was $base, max $mx)"
	journalctl -u y700-gpu-floor -n 6 --no-pager | tail -4
	[ "$dpms0" = Off ] && "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
fi
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
