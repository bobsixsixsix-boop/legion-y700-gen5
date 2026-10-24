# ts-bed scenario: bottom-edge gestures. A fast flick up from an app goes home; a slow swipe from the
# desktop opens the cards; a sideways drag scrolls the stack and a tap opens the card in front; a
# sideways flick right on the edge switches to the app used before (as on iOS); a tiny nudge goes back to the app.
wins() { eval_js 'print("tsbed wins=" + workspace.stackingOrder.filter(w => w.normalWindow && !w.deleted).map(w => w.caption + (w.minimized ? "-" : "")).sort().join(",") + " active=" + (workspace.activeWindow ? workspace.activeWindow.caption : "none"))'; }
app Kate '#3d7bf7'
app Konsole '#2b2f36'
app Browser '#1fa27a'
mark flick-home
touch <<'T'
swipe 800 1001 800 560 110
T
sleep 1.2
shot 30-home
wins
expect 'tsbed wins=Browser-,Kate-,Konsole- active=none'
mark desk-open
touch <<'T'
swipe 800 1001 800 650 350 250
T
sleep 1
expect 'open from the desktop, 3 cards, edge swipe'
shot 31-desk-recents
mark scroll
touch <<'T'
swipe 500 450 1100 450 400 150
T
sleep 1
shot 32-scrolled
touch <<'T'
d 0 800 450
s 60
u 0
T
sleep 1
wins
expect 'tsbed wins=Browser-,Kate-,Konsole active=Konsole'
mark side-flick
touch <<'T'
swipe 800 1000 1150 985 120
T
sleep 1
shot 33-side-flick
wins
expect 'tsbed wins=Browser,Kate-,Konsole- active=Browser'
mark nudge
touch <<'T'
swipe 800 1001 800 975 250 100
T
sleep 1
wins
expect 'tsbed wins=Browser,Kate-,Konsole- active=Browser'
