#!/bin/sh
# chatgpt-wayland-ime.sh [--undo]: make the screen keyboard work in OpenAI's ChatGPT desktop app (2026-10-22).
#
# The deb's launcher (/usr/share/applications/chatgpt.desktop, Exec=chatgpt %U) runs the Electron app on XWayland
# with GTK3 and no GTK_IM_MODULE: GTK picks im-xim, fcitx5 never gets an input context, KWin sees no text-input,
# so y700-osk has nothing to pop on a tap in the chat box (the Steam case of 10-12, same cause). Started as a native
# Wayland client with Chromium's IME switches it binds text-input v3 like Chrome: the keyboard pops on a tap in the
# box, candidates work, and it goes away with the box.
#
# Writes two files for user, both the deb's entry with the Exec line changed:
#   ~/.local/share/applications/chatgpt.desktop   same id as the deb's, so the menu / dock grid / URL handler use it
#   ~/Desktop/chatgpt.desktop                      the desktop icon (Plasma runs the file it shows)
# The original desktop icon is kept once as ~/.local/share/applications/chatgpt.desktop.y700bak-im (not on the
# Desktop: Plasma would show it as a second icon). Idempotent. Run again after a ChatGPT upgrade that changed the
# deb's entry (y700-checklist reports the mismatch). --undo removes the override and puts the deb's entry back as
# the icon. A ChatGPT already running keeps its old command line: quit it and start it again.
# Also a KWin window rule (~/.config/kwinrulesrc, group y700-chatgpt-max): as a Wayland client ChatGPT restores
# its X11-era window size, 1623x972 logical px, 23 px wider than the screen (the icons at the top right were cut
# off), and its "close" only hides the window, so the state never gets saved maximized. The rule maximizes it
# when it appears (rule 3 = apply initially; the owner can still un-maximize).
# Run as root on the tablet (scp it over, e.g. to /root/daily/).
set -eu
U=user; H=/home/$U; APPS=$H/.local/share/applications
SYS=/usr/share/applications/chatgpt.desktop
FLAGS='--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3'
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 HOME=$H"
RULE=y700-chatgpt-max
kwrule() { $RUN kwriteconfig6 --file kwinrulesrc --group "$1" --key "$2" "$3"; }
[ -f "$SYS" ] || { echo "no $SYS: ChatGPT (the deb) is not installed"; exit 1; }
if [ "${1:-}" = --undo ]; then
    rm -f "$APPS/chatgpt.desktop"
    if [ -f "$APPS/chatgpt.desktop.y700bak-im" ]; then cp "$APPS/chatgpt.desktop.y700bak-im" "$H/Desktop/chatgpt.desktop"
    else cp "$SYS" "$H/Desktop/chatgpt.desktop"; fi
    chown $U:$U "$H/Desktop/chatgpt.desktop"; chmod 755 "$H/Desktop/chatgpt.desktop"
    if [ "$($RUN kreadconfig6 --file kwinrulesrc --group General --key rules)" = "$RULE" ]; then
        for k in Description maximizehoriz maximizehorizrule maximizevert maximizevertrule wmclass wmclassmatch wmclasscomplete; do
            $RUN kwriteconfig6 --file kwinrulesrc --group "$RULE" --key "$k" --delete
        done
        kwrule General count 0; kwrule General rules ""
        $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    else
        echo "note: kwinrulesrc holds other rules too; remove the $RULE group by hand (System Settings > Window Rules)"
    fi
    echo "undone: override removed, the desktop icon is the deb's entry again"
    exit 0
fi
mkdir -p "$APPS"
[ -f "$APPS/chatgpt.desktop.y700bak-im" ] || { [ -f "$H/Desktop/chatgpt.desktop" ] && cp -p "$H/Desktop/chatgpt.desktop" "$APPS/chatgpt.desktop.y700bak-im"; } || true
tmp=$(mktemp)
# every Exec line of the deb's entry gets the switches once (a second run changes nothing)
sed -E "s|^(Exec=[^ ]*chatgpt)( $FLAGS)?( .*)?$|\1 $FLAGS\3|" "$SYS" > "$tmp"
grep -q -- "--enable-wayland-ime" "$tmp" || { echo "FAIL: no 'Exec=...chatgpt' line in $SYS to change (the deb's entry changed shape: fix the sed above)"; rm -f "$tmp"; exit 1; }
changed=
for f in "$APPS/chatgpt.desktop" "$H/Desktop/chatgpt.desktop"; do
    if ! cmp -s "$tmp" "$f"; then cp "$tmp" "$f"; changed="$changed $f"; fi
done
rm -f "$tmp"
chown $U:$U "$APPS/chatgpt.desktop" "$H/Desktop/chatgpt.desktop" "$APPS/chatgpt.desktop.y700bak-im" 2>/dev/null || true
chmod 644 "$APPS/chatgpt.desktop"; chmod 755 "$H/Desktop/chatgpt.desktop"
if [ -n "$changed" ]; then echo "installed:$changed"; else echo "already installed (nothing changed)"; fi
grep '^Exec=' "$APPS/chatgpt.desktop"
# the window rule: only when kwinrulesrc has no rule of ours yet (the list in [General] is comma-separated; ours
# is appended to whatever the owner made in System Settings)
if [ "$($RUN kreadconfig6 --file kwinrulesrc --group "$RULE" --key wmclass)" != chatgpt ]; then
    kwrule "$RULE" Description "ChatGPT 窗口最大化（y700，10-22）"
    kwrule "$RULE" maximizehoriz true; kwrule "$RULE" maximizehorizrule 3
    kwrule "$RULE" maximizevert true;  kwrule "$RULE" maximizevertrule 3
    kwrule "$RULE" wmclass chatgpt; kwrule "$RULE" wmclassmatch 1; kwrule "$RULE" wmclasscomplete false
    have=$($RUN kreadconfig6 --file kwinrulesrc --group General --key rules)
    if [ -n "$have" ]; then kwrule General rules "$have,$RULE"; else kwrule General rules "$RULE"; fi
    kwrule General count "$(( $($RUN kreadconfig6 --file kwinrulesrc --group General --key count --default 0) + 1 ))"
    $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    echo "window rule $RULE written (maximize ChatGPT when it appears)"
else
    echo "window rule $RULE already there"
fi
