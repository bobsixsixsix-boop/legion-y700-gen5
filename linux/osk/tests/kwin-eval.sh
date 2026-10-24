#!/bin/bash
# kwin-eval.sh: run a KWin JavaScript snippet (stdin) in the owner's live session and print what it
# print()s. For tests that need to find, activate, move or maximize windows without guessing taps.
# Run as root on the tablet:   echo 'for (const w of workspace.windowList()) print(w.resourceClass)' | kwin-eval.sh
# KWin scripts print to KWin's stderr; we read them back from the journal by a unique tag.
set -e
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
tag="y700eval$$"
f=$(mktemp /tmp/kwin-eval-XXXXXX.js)
{ echo "function out(s) { print('$tag ' + s); }"; cat; echo; echo "print('$tag-end');"; } > "$f"
chmod 644 "$f"
since=$(date '+%Y-%m-%d %H:%M:%S')
id=$("${U[@]}" busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss "$f" "$tag" | awk '{print $2}')
"${U[@]}" busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script run
# read until the end marker is in the journal (up to 3 s). A fixed 0.4 s lost the answer when journald
# lagged (10-21, under a test's log load): callers got "", and taskswitcher-test.sh took that for
# "no other windows" and closed the owner's apps. No marker after 3 s: exit 3 (the script threw, or KWin
# is stuck), so a caller can tell "no answer" from an empty one.
out="" ok=0
for i in $(seq 15); do
    sleep 0.2
    out=$("${U[@]}" journalctl --user --since "$since" --no-pager -o cat | grep -F "$tag" || true)
    if grep -q -- "$tag-end\$" <<< "$out"; then ok=1; break; fi
done
"${U[@]}" busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s "$tag" >/dev/null
rm -f "$f"
grep -F "$tag " <<< "$out" | sed "s/^.*$tag //"
[ $ok = 1 ] || exit 3
