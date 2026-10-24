# ts-bed scenario: a game card (steam_app_*) survives "clear all" and needs two swipes to close;
# a fullscreen game's card is the window's shape
wins() { eval_js 'print("tsbed wins=" + workspace.stackingOrder.filter(w => w.normalWindow && !w.deleted).map(w => w.caption).sort().join(",") + " active=" + (workspace.activeWindow ? workspace.activeWindow.caption : "none"))'; }
app Kate '#3d7bf7'
app Game '#c0392b' steam_app_1 --fullscreen
mark clear
shortcut
sleep 1
shot 20-recents-game
touch <<'T'
d 0 800 905
s 60
u 0
s 400
d 0 800 905
s 60
u 0
T
sleep 2.5
shot 21-after-clear
wins
expect 'tsbed wins=Game '
mark swipe1
touch <<'T'
swipe 800 500 800 80 160
T
sleep 0.5
shot 22-armed
wins
expect 'tsbed wins=Game '
mark swipe2
touch <<'T'
swipe 800 500 800 80 160
T
sleep 2.5
shot 23-after-swipe2
wins
expect 'tsbed wins= active=none'
