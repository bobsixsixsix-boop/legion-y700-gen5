# ts-bed scenario: the touch sequences of the on-device self-test (taskswitcher-test.sh, through vtouch),
# so a failure there can be replayed here first. vtouch's "drag" waits 30 ms after the last motion before
# lifting; its "hold" rises ease-out and then rests with 1 px jitter.
wins() { eval_js 'print("tsbed wins=" + workspace.stackingOrder.filter(w => w.normalWindow && !w.deleted).map(w => w.caption + (w.minimized ? "-" : "")).sort().join(",") + " active=" + (workspace.activeWindow ? workspace.activeWindow.caption : "none"))'; }
fx() { echo "tsbed fx=$(qdbus6 org.kde.KWin /Effects org.freedesktop.DBus.Properties.Get org.kde.kwin.Effects activeEffects 2>&1 | grep -c y700-taskswitcher)" >> "$LOG"; }
app Kate '#3d7bf7'
app Konsole '#2b2f36'   # not fullscreen: the bed has no fullscreen edge (y700-home's setup)
eval_js 'print("tsbed screen=" + workspace.virtualScreenSize.width + "x" + workspace.virtualScreenSize.height + " " + workspace.screens.map(o => o.name + "@" + o.scale).join(" "))'
mark hold
# hold 300 500 600: 14 ease-out steps of 35 ms up 300 px, then 10 x 60 ms resting with 1 px jitter
touch <<'T'
d 0 800 1001
m 0 800 937
s 35
m 0 800 884
s 35
m 0 800 840
s 35
m 0 800 803
s 35
m 0 800 774
s 35
m 0 800 751
s 35
m 0 800 733
s 35
m 0 800 719
s 35
m 0 800 709
s 35
m 0 800 703
s 35
m 0 800 701
s 35
m 0 800 700
s 35
m 0 800 699
s 35
m 0 800 699
s 35
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
u 0
T
sleep 1
fx
wins
shot 40-hold
expect 'tsbed fx=1'
touch <<'T'
k 1
T
sleep 1
mark flick
# flick: drag 320 px in 90 ms, 6 steps, 30 ms before the lift
touch <<'T'
d 0 800 1001
s 30
m 0 800 946
s 15
m 0 800 892
s 15
m 0 800 839
s 15
m 0 800 786
s 15
m 0 800 732
s 15
m 0 800 679
s 45
u 0
T
sleep 1.2
fx
wins
shot 41-flick
expect 'tsbed fx=0'
# a window that maps while the finger is still on the edge (10-21 on the device: a cold Konsole took 3.6 s
# to show, the self-test's first hold ran into it): its card comes once the stack settles, and Esc back to
# the app minimizes it like every other card
touch <<'T'
k 1
T
sleep 1
eval_js 'for (const w of workspace.windowList()) if (w.caption == "Konsole") { w.minimized = false; workspace.activeWindow = w; }'
sleep 0.5
mark late-hold
python3 "$T/bin/ts-app.py" Late1 '#8e44ad' --delay 500 >/dev/null 2>&1 &
touch <<'T'
d 0 800 1001
m 0 800 937
s 35
m 0 800 884
s 35
m 0 800 840
s 35
m 0 800 803
s 35
m 0 800 774
s 35
m 0 800 751
s 35
m 0 800 733
s 35
m 0 800 719
s 35
m 0 800 709
s 35
m 0 800 703
s 35
m 0 800 701
s 35
m 0 800 700
s 35
m 0 800 699
s 35
m 0 800 699
s 35
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
m 0 800 698
s 60
m 0 800 699
s 60
u 0
T
sleep 1
fx
wins
shot 42-late-hold
expect 'tsbed fx=1'
expect 'card added for a new window'
touch <<'T'
k 1
T
sleep 1
wins
expect 'tsbed wins=Kate-,Konsole,Late1- active=Konsole'
eval_js 'for (const w of workspace.windowList()) if (w.caption == "Konsole") { w.minimized = false; workspace.activeWindow = w; }'
sleep 0.5
mark late-flick
python3 "$T/bin/ts-app.py" Late2 '#16a085' --delay 250 >/dev/null 2>&1 &
touch <<'T'
d 0 800 1001
s 30
m 0 800 946
s 15
m 0 800 892
s 15
m 0 800 839
s 15
m 0 800 786
s 15
m 0 800 732
s 15
m 0 800 679
s 45
u 0
T
sleep 1.5
fx
wins
shot 43-late-flick
expect 'tsbed fx=0'
