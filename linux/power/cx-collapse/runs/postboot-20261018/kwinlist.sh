#!/bin/bash
# 2026-10-18: run /tmp/y700win.js once in KWin (as the session user), print its lines, unload it
export LC_ALL=C
B="sudo -u user DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus busctl --user"
chmod 644 /tmp/y700win.js
since=$(date '+%F %T')
$B call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700win >/dev/null 2>&1
id=$($B call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss /tmp/y700win.js y700win | awk '{print $2}')
echo "script id $id"
$B call org.kde.KWin /Scripting/Script$id org.kde.kwin.Script run
sleep 1
$B call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700win
journalctl --since "$since" --no-pager -o cat | grep Y700WIN | sed 's/.*Y700WIN //' | cut -c1-300
