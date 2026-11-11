# sb-bed scenario (11-09): the Stage Manager script (linux/stage) and the shellbar's backdrop together. stageback.sh
# drives the backdrop by hand and ts-bed's stage.sh runs the script with no shellbar, so neither saw it: on the tablet
# (11-09 02:50, the owner's screenshot) the backdrop, a whole-screen y700-shellbar window, counted as a blocker in
# Stage.qml (the rule meant for the shellbar's big windows over the apps) and hid the card column the moment it came up.
# The bed's KWin runs the stage script: SB_STAGE=<a checkout's y700-stage/> (copied into the bed's own XDG_DATA_HOME,
# which KWin looks in first; no BuildId, so its main.qml loads contents/ui/Stage.qml), or else the INSTALLED one (the
# live kwinrc's BuildId, as stagetile.sh). It is turned on through the bed's kwinrc (Active=true before the load) and
# off by its shortcut, as the tile does. The one tap (swap) is on the bed's own column, so it can run while the owner
# uses the tablet.
#   SB_STAGE=/tmp/y700st4/stage/y700-stage sh ./sb-bed.sh stagestrip.sh /tmp/y700st4/out-strip     (root; chmod -R a+rX
#   the checkout first: the bed runs as user)
# Steps and shots (OUT/*.png):
#   on      two apps, the script loads on: one app on the stage, the other a card in the column. The script tells the
#           shellbar (stage on), the backdrop maps under the apps (the wins line, bottom first: backdrop, apps, status
#           bar) and the column stays up: no "strip hidden (blocker)". k1-on: the card over the blurred wallpaper.
#           The card's window, never on the stage, is laid out in the slot all the same (11-10): no black bands
#   cc     the control centre over it is still a blocker: the column hides, the backdrop stays (k2-cc); hidden again,
#           the column is back
#   swap    Kate's card tapped (one finger on the column, ctap): Kate on the stage, Blue the card, and no dock window
#           mapped all through the flight (k3-swap). Needs the shellbar's holdDock (11-09): an older bar fails here
#   kbd     a band that reserves the bottom 389 px (kbzone.py, as the docked keyboard): Kate laid out in the slot above
#           it (k4-kbd), and back in the full slot when it goes; so is Blue, the card (11-10; k4b-kbd-gone)
#   tall   a third app that will not go under 689 high (ts-app.py --min-height, Telegram's minimum): above the band
#           it ends on the slot's bottom, taller than the slot (k5-tall); back in the slot when the band goes
#   cards   11-10, the keyboard as the tablet has it: the column hidden while it is up (the control centre stands in
#           as the blocker; kbzone.py is none). Three cards, one of them an app that animates (Live, ts-app.py
#           --frames: minimized it waits for a frame callback, so it commits a new size only while its card is
#           taken). After the band every card's window is back in the full slot (k7-cards: no black bands) without
#           one request more once the column is back (none drew the squeezed size first: Stage.qml's "told again"),
#           and Live draws nothing once the cards are taken
#   off     Active=false and the off shortcut: windows restored, stage off, the backdrop gone (k6-off)
# About 60 s. A failed check prints SBBED_EXPECT_FAIL; "stagestrip.sh: ..." lines are notes (the stacking places among them).
LIVE=$HOME/.local/share/kwin/scripts/y700-stage
BACK='y700-shellbar/@0,0+1600x1002'   # the backdrop (a layer window: no caption)

say() { echo "stagestrip.sh: $*"; echo "stagestrip.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: stagestrip.sh: $*"; echo "stagestrip.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
stagekey() { qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut "$1" >/dev/null 2>&1 || say "shortcut $1 failed"; }
wl() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -F "sbbed wins:" | tail -n 1; }
# pos LINE NEEDLE: the place of the first window whose entry holds NEEDLE, bottom first (0: none)
pos() { printf '%s\n' "$1" | awk -v n="$2" '{ sub(/^.*sbbed wins: /, ""); k = split($0, a, / [|] /)
    for (i = 1; i <= k; i++) if (index(a[i], n)) { print i; exit } print 0 }'; }
# geo LINE NEEDLE: the geometry (x,y+wxh) of the first window whose entry holds NEEDLE
geo() { printf '%s\n' "$1" | awk -v n="$2" '{ sub(/^.*sbbed wins: /, ""); k = split($0, a, / [|] /)
    for (i = 1; i <= k; i++) if (index(a[i], n)) { s = a[i]; sub(/^[^@]*@/, "", s); sub(/ .*$/, "", s); print s; exit } }'; }
# area: KWin's work area (x,y+wxh); slotof AREA: one window's place on the stage in it (Stage.qml padL 220, padT 12,
# padR 16, padB 16)
area() { n0=$(wc -l < "$LOG")
    eval_js 'const a = workspace.clientArea(KWin.MaximizeArea, workspace.activeScreen, workspace.currentDesktop);
print("sbbed area " + Math.round(a.x) + "," + Math.round(a.y) + "+" + Math.round(a.width) + "x" + Math.round(a.height))'
    l=$(tail -n +$((n0 + 1)) "$LOG" | grep -F "sbbed area " | tail -n 1); echo "${l##*sbbed area }"; }
slotof() { echo "$1" | awk -F'[,+x]' '{ printf "%d,%d+%dx%d\n", $1 + 220, $2 + 12, $3 - 236, $4 - 28 }'; }
# ctap X Y: one finger, no holding one (the column is KWin's own window: the first-touch miss of tap() is a client's)
ctap() { printf 'd 0 %s %s\ns 60\nu 0\n' "$1" "$2" | touch; }
# bar LINE: the place of the status bar (y700-shellbar at 0,0, full width, under 100 px tall)
bar() { printf '%s\n' "$1" | awk '{ sub(/^.*sbbed wins: /, ""); k = split($0, a, / [|] /)
    for (i = 1; i <= k; i++) if (a[i] ~ /^y700-shellbar\/@0,0[+]1600x[1-9][0-9]?( |$)/) { print i; exit } print 0 }'; }

# ---------------- the script into the bed's KWin
if [ -n "${SB_STAGE:-}" ]; then
    if [ ! -f "$SB_STAGE/contents/ui/Stage.qml" ]; then bad "SB_STAGE=$SB_STAGE has no contents/ui/Stage.qml"; return 0; fi
    mkdir -p "$T/data/kwin/scripts" && cp -r "$SB_STAGE" "$T/data/kwin/scripts/y700-stage"
    say "the candidate script from $SB_STAGE"
else
    BID=$(kreadconfig6 --file $HOME/.config/kwinrc --group Script-y700-stage --key BuildId)
    if [ -z "$BID" ] || [ ! -f "$LIVE/contents/build-$BID/ui/Stage.qml" ]; then
        bad "y700-stage is not installed (linux/stage/install.sh) and no SB_STAGE"; return 0
    fi
    kwriteconfig6 --file kwinrc --group Script-y700-stage --key BuildId "$BID"
    say "the installed script, build $BID"
fi
kwriteconfig6 --file kwinrc --group Plugins --key y700-stageEnabled true
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active true
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Debug true
# the desktop's picture, as stageback.sh (a Chinese file name, as the tablet's own)
cp "$T/wall.png" "$T/data/测试壁纸.png"
printf '[Containments][1]\nwallpaperplugin=org.kde.image\n\n[Containments][1][Wallpaper][org.kde.image][General]\nImage=file://%s\n' \
    "$T/data/测试壁纸.png" > "$T/config/plasma-org.kde.plasma.desktop-appletsrc"

# ---------------- on
app Kate '#3d7bf7'
app Blue '#2c6fd6'
mark on
qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1
sleep 3
expect 'y700-stage: loaded, on'
expect 'y700-stage: strip shown'
reject 'strip hidden (blocker)'
sbexpect 'stage on'
sbreject 'no wallpaper found'
W=$(wl)
b=$(pos "$W" "$BACK"); k=$(pos "$W" 'ts-kate/'); u=$(pos "$W" 'ts-blue/'); s=$(bar "$W")
say "on: stacking places (bottom first): backdrop $b, Kate $k, Blue $u, status bar $s"
if [ "$b" = 0 ]; then bad "on: no backdrop window"
elif [ "$k" = 0 ] || [ "$u" = 0 ] || [ "$s" = 0 ] || [ "$b" -gt "$k" ] || [ "$b" -gt "$u" ] || [ "$s" -lt "$k" ] || [ "$s" -lt "$u" ]; then
    bad "on: the stacking is not backdrop < apps < status bar"
fi
# 11-10: Kate was never on the stage (maximized, put away as the script came on). Its card showed it at its own
# aspect between black bands; every window of the column is laid out as the stage would have it
g=$(geo "$W" 'ts-kate/'); e=$(slotof "$(area)")
say "on: Kate, the card, $g (the slot $e)"
[ "$g" = "$e" ] || bad "on: Kate (a card, never staged) is $g, not laid out in the slot $e"
shot k1-on

# ---------------- cc: a real blocker still hides the column; the backdrop stays under it
mark cc
cc show; sleep 1.2
expect 'strip hidden (blocker)'
sbreject 'stage off'
shot k2-cc
mark cc-gone
cc hide; sleep 1.2
expect 'strip shown'
reject 'strip hidden'

# ---------------- swap: Kate's card tapped, the groups change places; the dock stays away all through. 11-09 (the
# owner: 「切换的时候，底下那个 Dock 栏会闪弹」): the flight put Blue down as it started and brought Kate up only as
# it landed, 0.5 s on; the shellbar, counting no window up, took that for the desktop and slid the dock in and out.
# A KWin script notes every dock window KWin maps or unmaps (the dock's window is only mapped while it shows)
eval_js 'const d = w => w && w.resourceClass == "y700-shellbar" && w.y > 800;
workspace.windowAdded.connect(w => { if (d(w)) print("sbbed dock mapped " + Date.now()) });
workspace.windowRemoved.connect(w => { if (d(w)) print("sbbed dock unmapped " + Date.now()) });'
mark swap
ctap 118 513       # the only card: the column is centred on y 513 here (the status bar's 28 above the area)
sleep 1.8
expect 'y700-stage: state tap staged=Kate strip=Blue'
reject 'sbbed dock mapped'
shot k3-swap

# ---------------- kbd: the docked keyboard's exclusive zone (kbzone.py, 389 high as on the tablet 11-09) squeezes the
# work area: the staged window is laid out again above it and gets the room back when it goes. 11-09 (the owner:
# 「输入法放下去以后，它又不会再展开，就只占了半个屏幕」): KWin squeezed the staged windows (they are not maximized)
# and never gave the room back; the script laid out only on a screen change
A0=$(area)
mark kbd
LD_PRELOAD=libgtk4-layer-shell.so.0 python3 "$T/bin/kbzone.py" 389 >> "$LOG" 2>&1 &
ZP=$!
sleep 1.5
A1=$(area)
say "kbd: area $A0 -> $A1"
[ "$A1" != "$A0" ] || bad "kbd: the band did not change the work area ($A1)"
W=$(wl); g=$(geo "$W" 'ts-kate/'); e=$(slotof "$A1")
say "kbd up: Kate $g (the slot $e)"
[ "$g" = "$e" ] || bad "kbd up: Kate is $g, not the slot above the keyboard $e"
shot k4-kbd
kill $ZP; sleep 1.5
W=$(wl); g=$(geo "$W" 'ts-kate/'); e=$(slotof "$A0")
say "kbd gone: Kate $g (the slot $e)"
[ "$g" = "$e" ] || bad "kbd gone: Kate is $g, not back in the full slot $e"
# 11-10 (the owner: 「键盘切出来再弹回去，它就又出现黑边了」): KWin squeezes the minimized windows too, and the card,
# taken again as its height comes back, showed the squeezed window between black bands
g=$(geo "$W" 'ts-blue/')
say "kbd gone: Blue, the card, $g (the slot $e)"
[ "$g" = "$e" ] || bad "kbd gone: Blue (the card) is $g, not back in the full slot $e"
shot k4b-kbd-gone

# ---------------- tall: an app that will not go under 689 (Telegram's minimum on the tablet). Above the keyboard it
# keeps its bottom on the slot's (the text field stays over the keyboard; its top goes up under the status bar), and
# goes back into the slot after. 11-09: 「Telegram 输入框有被键盘顶起来，但是显示不全」
app Tall '#8a4fd6' ts-tall --min-height 689
mark tall
LD_PRELOAD=libgtk4-layer-shell.so.0 python3 "$T/bin/kbzone.py" 389 >> "$LOG" 2>&1 &
ZP=$!
sleep 1.5
A1=$(area)
W=$(wl); g=$(geo "$W" 'ts-tall/')
y=${g#*,}; y=${y%%+*}; hh=${g##*x}
bot=$(echo "$A1" | awk -F'[,+x]' '{ print $2 + $4 - 16 }')
say "tall up: Tall $g, bottom $((y + hh)) (the slot's $bot)"
[ "$((y + hh))" = "$bot" ] && [ "$hh" -ge 689 ] || bad "tall up: Tall $g does not end on the slot's bottom $bot"
shot k5-tall
kill $ZP; sleep 1.5
W=$(wl); g=$(geo "$W" 'ts-tall/'); e=$(slotof "$A0")
say "tall gone: Tall $g (the slot $e)"
[ "$g" = "$e" ] || bad "tall gone: Tall is $g, not back in the slot $e"

# ---------------- cards: the keyboard as on the tablet, the column hidden while it is up (y700-osk is a blocker; here
# the control centre is). Live animates: once minimized it waits for a frame callback that only its card's thumbnail
# brings, so what it was asked while the column was hidden it commits as the card is taken, the stale size first
app Live '#d6812c' ts-live --frames "$T/run/live.frames"
mark cards
ctap 118 513       # three cards (Tall, Kate, Blue), the middle one: Kate up, Live into the column
sleep 2.5
expect 'y700-stage: state tap staged=Kate strip=Live,Tall,Blue'
cc show; sleep 1.2
expect 'strip hidden (blocker)'
LD_PRELOAD=libgtk4-layer-shell.so.0 python3 "$T/bin/kbzone.py" 389 >> "$LOG" 2>&1 &
ZP=$!
sleep 1.5
W=$(wl)
say "cards, kbd up: Live $(geo "$W" 'ts-live/'), Tall $(geo "$W" 'ts-tall/'), Blue $(geo "$W" 'ts-blue/')"
kill $ZP; sleep 1.5
W=$(wl)
say "cards, kbd gone, column hidden: Live $(geo "$W" 'ts-live/'), Tall $(geo "$W" 'ts-tall/'), Blue $(geo "$W" 'ts-blue/')"
n1=$(wc -l < "$LOG")
cc hide; sleep 2.5
r=$(tail -n +$((n1 + 1)) "$LOG" | grep -c 'y700-stage: rest: ' || true)
say "cards: $r requests to the column's windows once it was back"
[ "$r" = 0 ] || bad "cards: a window of the column drew an older size first when the column came back ($r asked again): black bands for a moment"
W=$(wl); e=$(slotof "$A0")
for n in live tall blue; do
    g=$(geo "$W" "ts-$n/")
    say "cards: $n $g (the slot $e)"
    [ "$g" = "$e" ] || bad "cards: $n (a card) is $g after the keyboard, not the full slot $e"
done
shot k7-cards
f1=$(cat "$T/run/live.frames"); sleep 3; f2=$(cat "$T/run/live.frames")
say "cards: Live drew $((f2 - f1)) frames in 3 s as a card ($f2 in all)"
[ "$f2" -gt 30 ] || bad "cards: Live's frame count ($f2) never went up: ts-app.py --frames not working"
[ $((f2 - f1)) -le 6 ] || bad "cards: Live drew $((f2 - f1)) frames in 3 s as a card: its card is still being taken"

# ---------------- off: as the tile turns it off
mark off
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active false
stagekey y700-stage-off
sleep 1.5
expect 'y700-stage: off, restored'
sbexpect 'stage off'
W=$(wl)
[ "$(pos "$W" "$BACK")" = 0 ] || bad "off: the backdrop is still there 1.5 s on"
shot k6-off
say "done (FAIL=$FAIL)"
