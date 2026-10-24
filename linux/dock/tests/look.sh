# sb-bed scenario: each state's look (screenshots) and the dock's rules around the bottom edge (expects).
# No app icon is tapped: see sb-bed.sh. "y700-shellbar/@0,882" in a wins line = the dock window is mapped.
shot 01-desktop
# the all-apps button: first in the dock; with no recents the dock is drawer + 6 pinned = 572 px wide.
# Open, the grid is KWin's active window (ACT: a Top-layer surface that accepts the keyboard is activated as KWin
# adds it; main.cpp asks on demand from the start) and the back key closes it: the control centre's fake Esc, as
# the side-edge swipe sends it (y700-edge -> fyi.y700.ControlCenter back). Beware the holding finger here: it
# rests on sb-wall.py, which asks for nothing; on the live screen the wallpaper is plasmashell, which asks KWin
# for the focus about 0.8 s after a touch on it (real-look.sh is one-fingered for that reason)
tap 560 938
sleep 0.7
wins
expect "y700-shellbar/@0,0+1600x1002 ACT"
shot 02-grid
mark back
busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter back sb y700-shellbar false
sleep 0.7
wins
reject "y700-shellbar/@0,0+1600x1002"
# ... and a tap on its empty background closes it too
mark bgtap
tap 560 938
sleep 0.7
tap 800 40
sleep 0.5
wins
reject "y700-shellbar/@0,0+1600x1002"
mark app
app Kate '#3d7bf7'
sleep 1
wins
reject "y700-shellbar/@0,882"
shot 03-app

# B+: a short slow swipe from the bottom edge, back to the same app, the dock comes up (one finger: the switcher)
mark reveal
touch <<'T'
swipe 800 1001 800 955 420 150
T
sleep 0.9
wins
expect "ts-kate/Kate@0,28+1600x974 ACT"
expect "y700-shellbar/@0,882"
sbexpect "reveal"
shot 04-revealed
# ... and goes away by itself after 4 s
mark autohide
sleep 4.5
wins
reject "y700-shellbar/@0,882"
shot 05-autohidden

# a fast flick is still "home" (the switcher minimizes everything): the dock is up as the desktop's, no reveal
mark flick
touch <<'T'
swipe 800 1001 800 820 90
T
sleep 1
wins
expect "Kate@0,28+1600x974 MIN"
expect "y700-shellbar/@0,882"
sbreject "reveal"
eval_js 'workspace.stackingOrder.filter(w => w.caption == "Kate").forEach(w => { w.minimized = false; workspace.activeWindow = w; })'
sleep 1

# a long slow swipe still opens the cards, no reveal; a tap on the card goes back to the app, dock away
mark cards
touch <<'T'
swipe 800 1001 800 520 700 300
T
sleep 1
shot 07-cards
sbreject "reveal"
tap 800 470
sleep 1
wins
expect "ts-kate/Kate@0,28+1600x974 ACT"
reject "y700-shellbar/@0,882"

# pull down from the right half of the status bar: the control centre
pull 1200 10 640 450
sleep 1
shot 06-cc
