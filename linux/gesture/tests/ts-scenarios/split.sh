# ts-bed scenario: split screen (linux/split/y700-split) and its part of the corner effect. Run with
#   TSBED_SCRIPTS='<checkout>/linux/split/y700-split <checkout>/linux/stage/y700-stage' \
#   TSBED_KWINRC='[Windows]\nElectricBorderTiling=false\nElectricBorderMaximize=false\n[Script-y700-split]\nDebug=true' \
#   TSBED_PLUGINS=<checkout>/linux/stage/kwin-corners/build/bin sh ts-bed.sh BUILD ts-scenarios/split.sh OUT
# (linux/split/README.md 测试). The work area here is the whole 1600 x 1002 (no status bar): halves 797 + 6 + 797
# (0..797 and 803..1600), the handle's window 48 x 90 at 776,456; at 70 % 1116 + 6 + 478. No shellbar here: the
# picker has no wallpaper and no 「其他应用」, and only the open windows to pick from.
geo() {
    eval_js 'workspace.windowList().filter(w => w.normalWindow && w.caption && !/^y700-/.test(w.caption)).forEach(w => { const g = w.frameGeometry; print("tsbed geo " + w.caption + " " + Math.round(g.x) + "," + Math.round(g.y) + " " + Math.round(g.width) + "x" + Math.round(g.height) + (w.minimized ? " min" : "") + (w.maximizeMode === 3 ? " max" : "") + " |"); })'
}
# where split screen's own windows are (off screen = parked at -32000)
iw() {
    eval_js 'workspace.windowList().filter(w => /^y700-split /.test(w.caption)).forEach(w => { const g = w.frameGeometry; print("tsbed iw " + w.caption + " " + Math.round(g.x) + "," + Math.round(g.y) + " " + Math.round(g.width) + "x" + Math.round(g.height) + " |"); })'
}
tap() { printf 'd 0 %s %s\ns 60\nu 0\n' "$1" "$2" | touch; }
# path X1 Y1 X2 Y2 [X3 Y3 ...]: a finger down at the first point, through the others (12 steps of 16 ms each),
# held 400 ms before it lifts (a shot can catch the hold)
path() {
    python3 -I -c 'import sys
p = list(map(float, sys.argv[1:]))
pts = list(zip(p[0::2], p[1::2]))
print("d 0 %d %d" % pts[0]); print("s 80")
for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
    for i in range(1, 13):
        t = i / 12; print("m 0 %d %d" % (x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)); print("s 16")
print("s 400"); print("u 0")' "$@" | touch
}
js() { eval_js "const W = n => workspace.windowList().find(w => w.caption === n); $*"; }
show() { js "W(\"$1\").minimized = false; workspace.activeWindow = W(\"$1\")"; }
state() { tail -n +$((MARK + 1)) "$LOG" | grep -o 'y700-split: state .*' | tail -1; }

expect 'y700-split: loaded'
mark api
# what this KWin offers (the script falls back where it is missing): raiseWindow, stackingOrderChanged; and the
# internal windows the stage and split screen open, with their captions
eval_js 'print("tsbed api raiseWindow=" + typeof workspace.raiseWindow + " stackingOrderChanged=" + typeof workspace.stackingOrderChanged)'
eval_js 'workspace.windowList().filter(w => /^y700-/.test(w.caption)).forEach(w => print("tsbed internal " + w.caption + " class=" + (w.resourceClass || "-") + " skipS=" + w.skipSwitcher + " skipT=" + w.skipTaskbar))'
expect 'tsbed internal y700-stage strip class=-'
expect 'tsbed internal y700-split handle class=- skipS=true skipT=true'

mark windows
app Red '#c0392b'
app Blue '#2c6fd6'
sleep 0.5
geo
expect 'tsbed geo Red 0,0 1600x1002 max |'
expect 'tsbed geo Blue 0,0 1600x1002 max |'

mark tile
# the control centre's tile / the task cards' 「分屏」: the active app (Blue) to the left half, the picker right
shortcut y700-split
sleep 1
geo
iw
shot 01-pick
expect 'state pick mode=pick pair= pick=Blue/0'
expect 'tsbed geo Blue 0,0 797x1002 |'
expect 'tsbed iw y700-split picker 803,0 797x1002 |'
expect 'y700-stagecorners: 1 window(s) rounded'

mark again
shortcut y700-split
sleep 0.5
expect 'toast: 已经在分屏里了'

mark choose
# the picker: 「选择另一个应用」, 「已打开」 and Red's still picture, 2 a row 356 x 223 from 835,~132
tap 1013 250
sleep 1.2
geo
iw
shot 02-split
expect 'state choose mode=split pair=Blue+Red'
expect 'tsbed geo Blue 0,0 797x1002 |'
expect 'tsbed geo Red 803,0 797x1002 |'
expect 'y700-stagecorners: 2 window(s) rounded'
expect 'tsbed iw y700-split handle 776,456 48x90 |'
expect 'tsbed iw y700-split bar 797,0 6x1002 |'

mark divider
# the handle dragged 350 right (r 0.72): the windows under still copies with their veils, then the nearest fitting
# snap, 70 %
path 800 501 1150 501 &
sleep 0.55
shot 03a-divider-held
wait $!
sleep 1
geo
shot 03b-divider-70
expect 'state snap 0.7'
expect 'tsbed geo Blue 0,0 1116x1002 |'
expect 'tsbed geo Red 1122,0 478x1002 |'

mark menu
# a tap on the handle: the menu right of it, 「对调应用」 / 「退出分屏」 (rows 48 high from 445 + 6, a 4 px rule)
tap 1119 501
sleep 0.6
iw
shot 04-menu
expect 'tsbed iw y700-split menu 0,0 1600x1002 |'
tap 1220 475
sleep 1.2
geo
shot 05-swapped
expect 'state swap mode=split pair=Red+Blue'
expect 'tsbed geo Red 0,0 1116x1002 |'
expect 'tsbed geo Blue 1122,0 478x1002 |'

mark park
# the one in use put away (as the home flick does): the other one with it; one of them shown = both back
js 'workspace.activeWindow = W("Red")'
sleep 0.3
js 'W("Red").minimized = true'
sleep 0.6
geo
expect 'tsbed geo Red 0,0 1116x1002 min |'
expect 'tsbed geo Blue 1122,0 478x1002 min |'
show Blue
sleep 0.8
geo
expect 'tsbed geo Red 0,0 1116x1002 |'
expect 'tsbed geo Blue 1122,0 478x1002 |'

mark title-swap
# Red's title bar dragged into Blue's half: the card under the finger, 「松手对调」, then they swap
path 500 12 700 300 1350 400 &
sleep 0.62   # the hold: the card under the finger, the drop hint
shot 06a-title-card
wait $!
sleep 1.2
geo
shot 06b-title-swapped
expect 'title drag: card from split'
expect 'title drag let go: swap'
expect 'state swap mode=split pair=Blue+Red'
expect 'tsbed geo Blue 0,0 1116x1002 |'
expect 'tsbed geo Red 1122,0 478x1002 |'

mark title-full
# Blue's title bar down out of the top zone and back up to it: 「松手进入全屏」, Blue full, Red back as it was
path 500 12 500 400 500 10 &
sleep 0.62   # the hold: the card under the finger, the drop hint
shot 07a-title-full-hint
wait $!
sleep 1.2
geo
expect 'title drag let go: full'
expect 'state exit title mode=off'
expect 'tsbed geo Blue 0,0 1600x1002 max |'
expect 'tsbed geo Red 0,0 1600x1002 max |'
expect 'y700-stagecorners: 0 window(s) rounded'

mark title-in
# from full screen: Blue's title bar to the left edge, 「松手进入分屏」, Blue to the left half and the picker
js 'workspace.activeWindow = W("Blue")'
sleep 0.3
path 800 12 400 400 12 500 &
sleep 0.62   # the hold: the card under the finger, the drop hint
shot 08a-title-in-hint
wait $!
sleep 1.2
geo
shot 08b-title-in
expect 'title drag: card from full'
expect 'title drag let go: split 0'
expect 'state pick mode=pick pair= pick=Blue/0'
expect 'tsbed geo Blue 0,0 797x1002 |'

mark cancel
# a tap on the picker's blank: Blue back to full screen
tap 1300 900
sleep 1
geo
expect 'state cancel mode=off'
expect 'tsbed geo Blue 0,0 1600x1002 max |'

mark dismiss
# into split screen again, then the handle to the right end: Blue full, Red put away, still open
shortcut y700-split
sleep 1
tap 1013 250
sleep 1.2
expect 'state choose mode=split pair=Blue+Red'
path 800 501 1590 501 &
sleep 0.55
shot 09a-dismiss-guide
wait $!
sleep 1.2
geo
expect 'state exit dismiss mode=off'
expect 'tsbed geo Blue 0,0 1600x1002 max |'
expect 'tsbed geo Red 803,0 797x1002 min |'
show Red
sleep 0.8
geo
expect 'tsbed geo Red 0,0 1600x1002 max |'

mark close
# a member closed: the other one full
shortcut y700-split
sleep 1
tap 1013 250
sleep 1.2
expect 'state choose mode=split'
app Green '#27ae60' --small
sleep 0.3
geo
mark close-it
js 'W("Green").closeWindow()'
sleep 0.5
js 'const a = workspace.activeWindow; print("tsbed active " + (a ? a.caption : "-"))'
geo
mark close-member
js 'W("Red").closeWindow()'
sleep 1.2
geo
expect 'state exit closed mode=off'
expect 'tsbed geo Blue 0,0 1600x1002 max |'

mark stage
# the stage manager on: split screen stands aside (the stage takes the windows as they stand); the tile says so
app Red '#c0392b'
show Blue
sleep 0.3
shortcut y700-split
sleep 1
tap 1013 250
sleep 1.2
expect 'state choose mode=split pair=Blue+Red'
kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active true
shortcut y700-stage-on
sleep 1.5
expect 'y700-split: stage manager on: split screen stands aside'
expect 'state dropped mode=off'
expect 'y700-stagecorners: 1 window(s) rounded'
shortcut y700-split
sleep 0.5
expect 'toast: 台前调度开着，把卡片拖到舞台上就能并排'
shot 10-stage-on
shortcut y700-stage-off
sleep 1.5
expect 'y700-split: stage manager off'
