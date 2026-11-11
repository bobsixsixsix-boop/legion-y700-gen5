# ts-bed scenario: the Stage Manager KWin script (linux/stage/y700-stage) and its corner effect. Run with
#   TSBED_SCRIPTS=<checkout>/linux/stage/y700-stage TSBED_KWINRC='[Script-y700-stage]\nDebug=true' \
#   TSBED_PLUGINS=<checkout>/linux/stage/kwin-corners/build/bin sh ts-bed.sh BUILD ts-scenarios/stage.sh OUT
# (Debug: a "state" line per change, with the test windows' captions; TSBED_PLUGINS: the effect not installed yet,
# leave it out once it is.) The work area here is the whole 1600 x 1002 (no status bar): the stage is
# 220,12 1364x974, a pair 676 + 12 + 676. Cards (vivo 原子工作台): x 32..204, a single 122.8 high, a pair 119.6,
# 16 apart, the column centred on y 499 - two singles at 368..491 and 507..630, one card at 438..561 / 439..559.
# A long press opens the menu right of the card at its top (rows 48 high from top + 6, a 4 px rule between).
# On the desktop the column hides: a group comes back by activating one of its windows.
# Covers RESEARCH.md section 8: on with windows open, new window, a card's app not drawing in the background
# (still: Blue counts its frames, ts-app.py --frames), tap, drag into a pair, minimize one =
# split, both at once = the stage clears and the pair stays, task switcher pick, guarded / fullscreen
# windows left alone, portrait pause, the last window closed, the menu, off restores the geometry ledger.
geo() {
    eval_js 'workspace.windowList().filter(w => w.normalWindow && w.caption && !/^y700-stage /.test(w.caption)).forEach(w => { const g = w.frameGeometry; print("tsbed geo " + w.caption + " " + Math.round(g.x) + "," + Math.round(g.y) + " " + Math.round(g.width) + "x" + Math.round(g.height) + (w.minimized ? " min" : "") + (w.maximizeMode === 3 ? " max" : "") + " |"); })'
}
tap() { printf 'd 0 %s %s\ns 60\nu 0\n' "$1" "$2" | touch; }
press() { printf 'd 0 %s %s\ns 700\nu 0\n' "$1" "$2" | touch; }   # long press (0.5 s)
# drag X1 Y1 X2 Y2: a finger, 12 steps of 16 ms, held 400 ms before it lifts (a shot can catch the hold)
drag() {
    python3 -I -c 'import sys
x1, y1, x2, y2 = map(float, sys.argv[1:])
print("d 0 %d %d" % (x1, y1)); print("s 80")
for i in range(1, 13):
    t = i / 12; print("m 0 %d %d" % (x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)); print("s 16")
print("s 400"); print("u 0")' "$@" | touch
}
js() { eval_js "const W = n => workspace.windowList().find(w => w.caption === n); $*"; }
show() { js "W(\"$1\").minimized = false; workspace.activeWindow = W(\"$1\")"; }
# the tap switches since the last mark: how many, and the last one. One tap must switch once: 11-10 a card fading
# out of the column (its remove transition) still took the tap under the card that came in its place, two switches
taps() { tail -n +$((MARK + 1)) "$LOG" | grep -o 'state tap staged=[A-Za-z]* strip=[A-Za-z,+]*'; }
ntaps() { n=$(taps | wc -l); [ "$n" -eq "$1" ] || { echo "TSBED_EXPECT_FAIL: $1 tap switch(es), got $n"; FAIL=1; }; }
lasttap() { l=$(taps | tail -1); [ "$l" = "$1" ] || { echo "TSBED_EXPECT_FAIL: last tap switch $1, got $l"; FAIL=1; }; }

expect 'y700-stage: loaded, off'
mark windows-before
app Red '#c0392b'
# Blue animates (ts-app.py --frames): it draws only as KWin sends it frame callbacks, which the "still" step counts
app Blue '#2c6fd6' --frames "$T/run/blue.frames"
# the ledger's two kinds: Red a plain window, Blue maximized
js 'const r = W("Red"); r.setMaximize(false, false); r.frameGeometry = { x: 200, y: 100, width: 800, height: 600 }; W("Blue").setMaximize(true, true)'
sleep 0.8
eval_js 'workspace.windowList().forEach(w => print("tsbed all " + (w.caption || "-") + " class=" + (w.resourceClass || "-") + " normal=" + w.normalWindow + " min=" + w.minimizable + " skipS=" + w.skipSwitcher))'
geo
expect 'tsbed geo Red 200,100 800x600 |'
expect 'tsbed geo Blue 0,0 1600x1002 max |'

mark on
shortcut y700-stage-on
sleep 1
geo
shot 01-on
expect 'y700-stage: on, 2 windows'
expect 'state on staged=Blue strip=Red'
expect 'tsbed geo Blue 220,12 1364x974 |'
expect 'y700-stage: strip shown'
expect 'y700-stagecorners: 1 window(s) rounded'

mark new
app Green '#27ae60'
sleep 0.5
geo
shot 02-new
expect 'state new staged=Green strip=Blue,Red'
expect 'tsbed geo Green 220,12 1364x974 |'
expect 'tsbed geo Blue 220,12 1364x974 min |'

mark still
# Blue is a card now. Its card keeps a live thumbnail only until the picture is taken (0.6 s on screen, Card.qml):
# a live KWin thumbnail makes KWin send its minimized window frame callbacks at the output's refresh rate, so an
# app that animates keeps drawing in the background (11-09 on the tablet: Chrome, wiliwili, 6-8 W; README 踩坑 24)
frames() { cat "$T/run/blue.frames" 2>/dev/null || echo 0; }
sleep 1.5
f1=$(frames); sleep 3; f2=$(frames)
echo "tsbed still: Blue drew $((f2 - f1)) frames in 3 s as a card ($f2 in all)" >> "$LOG"
[ "$f2" -gt 30 ] || { echo "TSBED_EXPECT_FAIL: still: Blue's frame count ($f2) never went up: ts-app.py --frames not working"; FAIL=1; }
[ $((f2 - f1)) -le 6 ] || { echo "TSBED_EXPECT_FAIL: still: Blue drew $((f2 - f1)) frames in 3 s as a card: a live thumbnail holds it"; FAIL=1; }
shot 02b-still

mark tap
tap 118 430 &    # 2 cards: card 0 = Blue
sleep 0.25
shot 03a-tap-flight
wait $!
sleep 0.5
# the group that just left grabs the focus back within 1 s: refused
show Green
sleep 1
geo
shot 03-tap
expect 'state tap staged=Blue strip=Green,Red'
expect 'grab-back refused (ts-green)'
expect 'tsbed geo Blue 220,12 1364x974 |'
expect 'tsbed geo Green 220,12 1364x974 min |'

mark retarget
# taps in quick succession (11-10). The overlay is up over the column during a flight: until outputOnly it took
# every tap, and only the first card came (state stays staged=Green). Now each tap mid-flight applies the state
# at once and the copies turn from where they are (interrupt / carry): Green's card, then mid-flight Red's (in
# that flight the column is Blue, Red), then mid-flight the top slot again, Green flying back there
tap 118 430 &    # card 0 = Green
t=$!
sleep 0.25
tap 118 568      # card 1 = Red: Green turns back to card 0, Blue flies on to card 1
sleep 0.1
tap 118 430      # card 0 = Green again, in the air: Red turns back to card 0, Blue still on to card 1
sleep 0.05
shot 03b-retarget
wait $t          # this tap only: a bare wait waits for the test apps too (they never end)
sleep 1
geo
shot 03c-retarget-end
expect 'flight taken on mid-way: 3 copies, 1 carried on'
expect 'state tap staged=Red strip=Green,Blue'
expect 'state tap staged=Green strip=Red,Blue'
expect 'tsbed geo Green 220,12 1364x974 |'
expect 'tsbed geo Red 220,12 1364x974 min |'
expect 'tsbed geo Blue 220,12 1364x974 min |'
ntaps 3
lasttap 'state tap staged=Green strip=Red,Blue'
tap 118 568      # card 1 = Blue: back to what the steps below start from
sleep 1
expect 'state tap staged=Blue strip=Green,Red'

mark merge
drag 118 568 1300 500 &  # card 1 = Red, onto the right half
sleep 0.45
shot 04a-dragging
wait $!
sleep 1
geo
shot 04-merge
expect 'state merge staged=Blue+Red strip=Green'
expect 'tsbed geo Blue 220,12 676x974 |'
expect 'tsbed geo Red 908,12 676x974 |'
expect 'y700-stagecorners: 2 window(s) rounded'

mark split
js 'W("Red").minimized = true'
sleep 1
geo
expect 'state split staged=Blue strip=Red,Green'
expect 'tsbed geo Blue 220,12 1364x974 |'

mark merge-left
drag 118 430 400 500     # card 0 = Red, onto the left half
sleep 1
geo
expect 'state merge staged=Red+Blue strip=Green'
expect 'tsbed geo Red 220,12 676x974 |'
expect 'tsbed geo Blue 908,12 676x974 |'

mark burst
js 'W("Red").minimized = true; W("Blue").minimized = true'
sleep 1
expect 'state cleared staged=- strip=Red+Blue,Green'
expect 'strip hidden (desktop)'
shot 05-cleared
show Red        # the pair comes back whole (the dock, a desktop icon, the task cards)
sleep 1
geo
shot 06-pair-back
expect 'state activated staged=Red+Blue strip=Green'
expect 'strip shown'
expect 'tsbed geo Red 220,12 676x974 |'
expect 'tsbed geo Blue 908,12 676x974 |'

mark switcher
shortcut
sleep 1
shot 07-switcher
expect 'open from an app, 3 cards'
tap 200 450
sleep 1.5
geo
shot 08-switcher-pick
expect 'state regroup staged=Red+Blue strip=Green'
expect 'tsbed geo Red 220,12 676x974 |'
expect 'tsbed geo Blue 908,12 676x974 |'

mark guarded
app Game '#8e44ad' steam_app_42
sleep 0.5
geo
shot 09-game
expect 'strip hidden (fullscreen/guarded)'
kill $!
sleep 1
expect 'strip shown'

mark portrait
kscreen-doctor output.Virtual-0.rotation.left >> "$LOG" 2>&1
sleep 1.5
geo
shot 10-portrait
expect 'strip hidden (portrait)'
expect 'tsbed geo Red 0,0 1002x1600 max |'
expect 'tsbed geo Blue 0,0 1002x1600 max |'
mark landscape
kscreen-doctor output.Virtual-0.rotation.none >> "$LOG" 2>&1
sleep 1.5
geo
shot 11-landscape
expect 'strip shown'
expect 'tsbed geo Red 220,12 676x974 |'
expect 'tsbed geo Blue 908,12 676x974 |'

mark close-last
app Yellow '#f1c40f'
sleep 0.5
expect 'state new staged=Yellow strip=Red+Blue,Green'
js 'W("Yellow").closeWindow()'
sleep 1.5
geo
shot 12-empty
expect 'state closed staged=- strip=Red+Blue,Green'
expect 'strip hidden (desktop)'

mark menu
show Green
sleep 1
expect 'state activated staged=Green strip=Red+Blue'
press 118 499 &  # the pair's card (the only one, top 439)
sleep 0.95
shot 14-menu
wait $!
tap 280 469     # 「拆开」: the first row
sleep 1
expect 'state unpair staged=Green strip=Red,Blue'
tap 118 430     # card 0 = Red to the stage, Green to card 0
sleep 1
expect 'state tap staged=Red strip=Green,Blue'
press 118 430   # Green's card (top 368)
sleep 0.4
tap 280 398     # 「关闭」, the only row
sleep 1.5
expect 'state closed staged=Red strip=Blue'

mark off
shortcut y700-stage-off
sleep 1
expect 'y700-stage: off, restored 1, 1 when shown'
expect 'y700-stagecorners: 0 window(s) rounded'
js 'W("Red").minimized = false; W("Blue").minimized = false'
sleep 1.5
geo
shot 13-off
expect 'tsbed geo Red 200,100 800x600 |'
expect 'tsbed geo Blue 0,0 1600x1002 max |'

mark slow-flight
# a tap's flight photographed halfway: the script reloaded on, every animation 10x slower (5 s)
kwriteconfig6 --file kwinrc --group Script-y700-stage --key DebugSpeed 10
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active true
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript y700-stage >/dev/null 2>&1
qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1
sleep 2
expect 'y700-stage: loaded, on'
expect 'y700-stage: on, 2 windows'
shot 15a-slow-on
sleep 3.5        # the column slides in, 10x slower too (3 s)
tap 118 499 &    # 1 card
sleep 2.6
shot 15-flight-mid
wait $!
sleep 3.5
expect 'state tap staged='
shot 16-flight-end

mark slow-retarget
# the one card again with the flight under way (11-10, still 10x slower): both copies turn where they are and fly
# back. 17a just before the second tap, 17b just after: the copies about where they were, at neither end (a jump
# to the ends was the old land-then-fly)
was=$(grep -o 'state tap staged=[A-Za-z]* strip=[A-Za-z,+]*' "$LOG" | tail -1)
tap 118 499 &
sleep 2.2
shot 17a-before-turn
tap 118 499      # the column's one card: the group flying there
shot 17b-after-turn
sleep 6
shot 17c-turned-end
expect 'flight taken on mid-way: 2 copies, 0 carried on'
expect "$was"
# the second tap lands where the first one's card is fading out (remove transition, 4 s at 10x): one switch, not
# two (11-10 it switched back and then again, ending where the first tap had gone)
ntaps 2
lasttap "$was"
