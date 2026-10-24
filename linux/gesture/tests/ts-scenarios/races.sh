# ts-bed scenario: things that happen while the cards are up. A window that appears gets a card (and
# can be opened); a game that quits while its card is under the finger flies off, the release opens
# nothing; a window that refuses to close comes back as a card even if its 1.5 s check lands while a
# finger is down (it waits for the lift).
wins() { eval_js 'print("tsbed wins=" + workspace.stackingOrder.filter(w => w.normalWindow && !w.deleted).map(w => w.caption + (w.minimized ? "-" : "")).sort().join(",") + " active=" + (workspace.activeWindow ? workspace.activeWindow.caption : "none"))'; }
app Kate '#3d7bf7'
app Game '#c0392b' steam_app_1
mark appear
shortcut
sleep 1
app Late '#8e44ad'
sleep 0.5
expect 'card added for a new window'
shot 40-late-card
touch <<'T'
d 0 800 450
s 60
u 0
T
sleep 1
wins
expect 'active=Late'
mark quit-mid-swipe
shortcut
sleep 1
( sleep 0.6; pkill -f 'ts-app.py Game' ) &
touch <<'T'
d 0 200 450
s 30
m 0 200 420
s 30
m 0 200 380
s 30
m 0 200 300
s 1200
m 0 200 200
s 30
u 0
T
sleep 1
shot 41-after-quit
wins
expect 'tsbed wins=Kate-,Late- active=none'
touch <<'T'
k 1
T
sleep 1
mark refuse
app Stubborn '#e67e22' ts-stubborn --refuse-close
shortcut
sleep 1
touch <<'T'
swipe 800 500 800 80 160
s 300
d 0 700 450
s 30
m 0 710 450
s 30
m 0 720 450
s 2000
u 0
T
sleep 1
expect 'card back, its window did not close'
shot 42-card-back
