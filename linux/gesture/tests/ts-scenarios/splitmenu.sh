# ts-bed scenario (11-10): the task cards' ▾ menu, 「分屏」 (linux/split). Run with the split screen script:
#   TSBED_SCRIPTS=<checkout>/linux/split/y700-split \
#   TSBED_KWINRC='[Windows]\nElectricBorderTiling=false\nElectricBorderMaximize=false\n[Script-y700-split]\nDebug=true' \
#   sh ts-bed.sh BUILD ts-scenarios/splitmenu.sh OUT
# Without the script (every other scenario) no card has a ▾ and a tap on the header opens the app, as before.
# Two apps, the cards from Blue: Blue's card in front, centred (x 320.6 .. 1280.6, top 174 at scale 1: the work area
# is the whole 1600 x 1002 here, cw 960 = 0.6 x 1600), its header at y 134..164 from x 329.6 (icon, 「Blue」, ▾).
# The menu: under the header, left-aligned with its icon, 8 px down (330,172, 150 x 60, its row y 178..226).
tap() { printf 'd 0 %s %s\ns 60\nu 0\n' "$1" "$2" | touch; }
geo() {
    eval_js 'workspace.windowList().filter(w => w.normalWindow && w.caption && !/^y700-/.test(w.caption)).forEach(w => { const g = w.frameGeometry; print("tsbed geo " + w.caption + " " + Math.round(g.x) + "," + Math.round(g.y) + " " + Math.round(g.width) + "x" + Math.round(g.height) + (w.minimized ? " min" : "") + (w.maximizeMode === 3 ? " max" : "") + " |"); })'
}

expect 'y700-split: loaded'
app Red '#c0392b'
app Blue '#2c6fd6'
sleep 0.5

mark open
shortcut
sleep 1
expect 'y700-taskswitcher: open from an app, 2 cards, shortcut'
shot 01-cards          # the ▾ after 「Blue」

mark menu
# a tap on the header's name: the menu, the cards stay
tap 380 149
sleep 0.7
shot 02-menu
expect 'y700-taskswitcher: menu 330,172'

mark away
# a tap anywhere else closes it and only that: no card opens, the cards stay (the header opens the menu again)
tap 1300 850
sleep 0.5
shot 03-menu-gone
tap 380 149
sleep 0.7
expect 'y700-taskswitcher: menu 330,172'

mark esc
# Esc closes the menu, not the cards
touch <<'T'
k 1
T
sleep 0.5
tap 380 149
sleep 0.7
expect 'y700-taskswitcher: menu 330,172'

mark split
# 「分屏」: Blue's card opens, then the split shortcut: Blue on the left half, the picker on the right
tap 400 202
sleep 1.8
geo
shot 04-pick
expect 'y700-taskswitcher: menu split'
expect 'y700-split: state pick mode=pick pair= pick=Blue/0'
expect 'tsbed geo Blue 0,0 797x1002 |'

mark choose
# Red from the picker (its still picture, the first of 「已打开」, as split.sh)
tap 1013 250
sleep 1.2
geo
shot 05-split
expect 'state choose mode=split pair=Blue+Red'
expect 'tsbed geo Red 803,0 797x1002 |'

mark picture
# the picture of a card still opens its app, the header aside: the front card's picture, no menu
shortcut
sleep 1
tap 800 600
sleep 1.2
eval_js 'const a = workspace.activeWindow; print("tsbed active=" + (a ? a.caption : "none") + (a && a.normalWindow ? " normal" : ""))'
expect ' normal'
if tail -n +$((MARK + 1)) "$LOG" | grep -qF 'y700-taskswitcher: menu'; then echo "TSBED_EXPECT_FAIL: a picture tap opened the menu"; FAIL=1; fi
