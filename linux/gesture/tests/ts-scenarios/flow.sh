# ts-bed scenario: tap a card opens it; swipe a card up closes it and the cards stay; Esc after the
# origin app was closed lands on the desktop; edge swipe from an app opens the cards, Esc goes back to
# that app; two taps on the clear button close everything and leave the desktop
wins() { eval_js 'print("tsbed wins=" + workspace.stackingOrder.filter(w => w.normalWindow && !w.deleted).map(w => w.caption).sort().join(",") + " active=" + (workspace.activeWindow ? workspace.activeWindow.caption : "none"))'; }
app Kate '#3d7bf7'
app Konsole '#2b2f36'
app Browser '#1fa27a'
mark tap
shortcut
sleep 1
touch <<'T'
d 0 200 450
s 60
u 0
T
sleep 1
shot 10-after-tap
wins
expect 'active=Konsole'
mark close
shortcut
sleep 1
shot 11-recents
touch <<'T'
swipe 800 500 800 80 160
T
sleep 2
shot 12-after-close
wins
expect 'tsbed wins=Browser,Kate active=none'
mark esc-origin-gone
touch <<'T'
k 1
T
sleep 1
wins
expect 'tsbed wins=Browser,Kate active=none'
mark edge
shortcut
sleep 1
touch <<'T'
d 0 200 450
s 60
u 0
T
sleep 1
wins
expect 'active=Kate'
touch <<'T'
swipe 800 1001 800 600 300 250
T
sleep 1
expect 'open from an app, 2 cards, edge swipe'
shot 13-edge
touch <<'T'
k 1
T
sleep 1
wins
expect 'active=Kate'
mark clear
shortcut
sleep 1
touch <<'T'
d 0 800 905
s 60
u 0
s 400
d 0 800 905
s 60
u 0
T
sleep 0.3
shot 14-clearing
sleep 2.5
shot 15-after-clear
wins
expect 'tsbed wins= active=none'
