# ts-bed scenario: open from an app with the shortcut, look, Esc goes back to that app; open again,
# tap a card, it opens; from the desktop
app Kate '#3d7bf7'
app Konsole '#2b2f36'
app Browser '#1fa27a'
shot 00-app
mark open-shortcut
shortcut
sleep 1
expect 'y700-taskswitcher: open from an app, 3 cards, shortcut'
shot 01-recents
mark esc
touch <<'T'
k 1
T
sleep 1
shot 02-after-esc
eval_js 'print("tsbed active=" + (workspace.activeWindow ? workspace.activeWindow.caption : "none"))'
expect 'tsbed active=Browser'
