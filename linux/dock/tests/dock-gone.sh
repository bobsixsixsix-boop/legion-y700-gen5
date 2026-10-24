# sb-bed scenario (10-23): a dock window that goes away while the task switcher's view is up must not make the view's
# PanelGlass throw. The cards are opened from the desktop (the dock is on the desktop layer, a PanelGlass delegate),
# then the app's card is tapped: the app goes active, y700-shellbar unmaps its dock in an app (B+: the dock is only
# on the desktop), KWin removes that window while the card still grows to full screen. Before 10-23 the delegate
# lived on with modelData turned null when KWin destroyed the window, and every binding of it threw
# (TaskSwitcher.qml x/y/width/height/internalId: "TypeError: Cannot read property ... of null", 219 lines in the
# tablet's journal 10-21..10-23). Also logs, for each dock KWin removes, whether it is still in stackingOrder and
# marked deleted at windowRemoved (refreshDocks() rebuilds its list from stackingOrder right then).
# Run: sh sb-bed.sh dock-gone.sh OUT (root); SB_FX=DIR for a build from taskswitcher/install.sh --build DIR.
fx_active() { busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects activeEffects 2>/dev/null | grep -q y700-taskswitcher; }
eval_js 'workspace.windowRemoved.connect(w => { if (w && w.dock) print("sbbed dock removed: " + w.resourceClass + " " + Math.round(w.y) + "+" + Math.round(w.height) + " deleted=" + w.deleted + " inStacking=" + workspace.stackingOrder.includes(w)); });'
app Kate '#3d7bf7'
sleep 1
# to the desktop without the home flick (dock-glass.sh: the bed's software rendering can read a flick as a slow swipe)
eval_js 'workspace.stackingOrder.filter(w => w.caption == "Kate").forEach(w => { w.minimized = true; })'
sleep 1.5
wins
expect "y700-shellbar/@0,882"
mark cards
touch <<'T'
swipe 800 1001 800 840 350 600
T
sleep 1.6
expect "y700-taskswitcher: open from the desktop, 1 cards"
fx_active || echo "dock-gone: the cards did not open (the switcher is not active)" >> "$LOG"
shot 01-cards
# the one card sits in the middle of the work area; one finger only (tap() puts a second one down first, and the
# view takes one finger)
mark open-app
touch <<'T'
d 0 800 480
s 60
u 0
T
sleep 3
wins
shot 02-app
expect "Kate@0,28+1600x974 ACT"
expect "sbbed dock removed: y700-shellbar 882+120"
reject "TaskSwitcher.qml"
fx_active && echo "dock-gone: the switcher is still active after the card opened" >> "$LOG" && FAIL=1
grep -F 'sbbed dock removed' "$LOG" | sed 's/^/dock-gone: /'
grep -F 'TaskSwitcher.qml' "$LOG" | head -6 | sed 's/^/dock-gone: /'
true
