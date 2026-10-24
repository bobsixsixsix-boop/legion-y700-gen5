# sb-bed scenario (10-22): the game performance numbers - a widget on the desktop (qml/HudWidget.qml), a line in
# the status bar in an app (qml/HudLine.qml), the bar over a fullscreen app (Main.qml barOverlay); src/hud.cpp
# reads them. No sampler runs in the bed: the files `y700-hud-overlay --sampler` and y700-hud-toggle would write
# are written here, into the bed's own XDG_RUNTIME_DIR. Screenshots h0-h9; `wins` lines in the log show where the
# widget is ("y700-shellbar/@22,46+316x136": mapped, full) and whether the bar is over a fullscreen window.
#   SB_BAR=/opt/y700-next/bin/y700-shellbar sh ./sb-bed.sh hud.sh /root/sb-hud
KV=$XDG_RUNTIME_DIR/y700-hud.txt.kv
MODE=$XDG_RUNTIME_DIR/y700-hud.mode
WIDGET="y700-shellbar/@22,46+316x"
# hudkv k=v ...: one sample, written as the sampler writes it (a rename into the directory)
hudkv() { printf '%s\n' "$@" > "$KV.tmp" && mv "$KV.tmp" "$KV"; sleep 0.7; }
IDLE="fps= hz=30 cpu=1 cpu_mhz=4396 cpu_c=72 gpu=0 gpu_mhz=160 gpu_c=36 skin_c=35 thr=0 sys_w=1.5 bat_w= on=0 in_w=0.0 in_v=0.00 in_a=0.00 adapter= bat_pct=83"
GAME="fps=58 hz=120 cpu=91 cpu_mhz=3400 cpu_c=96 gpu=99 gpu_mhz=700 gpu_c=88 skin_c=51 thr=1 sys_w=13.2 bat_w= on=0 in_w=0.0 in_v=0.00 in_a=0.00 adapter= bat_pct=62"

# HUD off: nothing
wins
reject "$WIDGET"
shot h0-desktop-off

# on, on the desktop: the widget under the clock, nothing in the bar
mark desktop
echo full > "$MODE"
# shellcheck disable=SC2086
hudkv $IDLE
wins
expect "${WIDGET}136"
sbexpect "hud widget: shown full 316x136"
sbreject "hud line:"
shot h1-desktop-full
mark mini
echo mini > "$MODE"; sleep 0.7
sbexpect "hud widget: mini 316x75"
shot h2-desktop-mini
echo full > "$MODE"; sleep 0.7

# on a PD charger: 快充 +15.6 W (the draw is not in this sample: —)
hudkv "fps=" "hz=60" "cpu=4" "cpu_mhz=1228" "cpu_c=41" "gpu=2" "gpu_mhz=160" "gpu_c=33" "skin_c=40" "thr=0" "sys_w=" "bat_w=15.6" "on=1" "in_w=19.9" "in_v=8.0" "in_a=2.5" "adapter=PD" "bat_pct=91"
shot h3-desktop-charging
# a game drawing at 58 FPS, hot and throttling (a game on the desktop cannot be; this is the widget's colours)
# shellcheck disable=SC2086
hudkv $GAME
shot h4-desktop-hot

# an app: the widget goes, the line comes into the (now solid) bar
mark app
app Kate '#3d7bf7'
sleep 0.8
wins
reject "$WIDGET"
sbexpect "hud widget: hidden"
sbexpect "hud line:"
shot h5-app-game

# the cards from the app (a long slow bottom-edge swipe): minimizeAll() puts the desktop up under them, the widget
# maps with the dock and the switcher draws both on its desktop layer; a tap on the card goes back, widget away
mark cards
# shellcheck disable=SC2086
hudkv $IDLE
touch <<'T'
swipe 800 1001 800 520 700 300
T
sleep 1
shot h6-cards
tap 800 470
sleep 1
wins
expect "ts-kate/Kate@0,28+1600x974 ACT"
reject "$WIDGET"

# a fullscreen app: KWin raises it above the Top layer; with the HUD on the bar moves to Overlay and stays in view
mark fullscreen
app Game '#1c1d22' ts-game --fullscreen
sleep 1.2
# shellcheck disable=SC2086
hudkv $GAME
wins
sbexpect "status bar: overlay layer"
shot h7-fullscreen-on

# HUD off: the sampler's file goes (the unit's ExecStopPost), the line goes, the bar is back under the game
mark off
rm -f "$KV"
sleep 1
wins
sbexpect "status bar: top layer"
shot h8-fullscreen-off

# back on the desktop with the HUD off: no widget
mark desktop-off
eval_js 'workspace.stackingOrder.filter(w => w.caption == "Kate" || w.caption == "Game").forEach(w => { w.minimized = true; })'
sleep 1
wins
reject "$WIDGET"
shot h9-desktop-off
