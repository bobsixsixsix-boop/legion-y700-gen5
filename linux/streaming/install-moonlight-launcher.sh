#!/bin/bash
# Install y700-moonlight as THE Moonlight launcher (root on the tablet, from /root/streaming):
#   ~/.local/bin/y700-moonlight
#   ~/.local/share/applications/com.moonlight_stream.Moonlight.desktop  (same id: overrides the flatpak export in
#       the app menu; X-Flatpak kept so Plasma still groups it with the flatpak)
#   ~/Desktop/com.moonlight_stream.Moonlight.desktop                    (the desktop icon, Exec changed)
#   ml-hud-fps.sh on                                                     (the HUD shows Moonlight's FPS)
# Backups: the desktop icon -> ~/.local/share/applications/com.moonlight_stream.Moonlight.desktop.y700bak-desktop
# (not in ~/Desktop: Plasma would show the backup as a second icon). Undo: ./install-moonlight-launcher.sh --undo
set -eu
H=/home/user
SRC=$(cd "$(dirname "$0")" && pwd)
APPS=$H/.local/share/applications
ICON=$H/Desktop/com.moonlight_stream.Moonlight.desktop
EXPORT=/var/lib/flatpak/exports/share/applications/com.moonlight_stream.Moonlight.desktop
BAK=$APPS/com.moonlight_stream.Moonlight.desktop.y700bak-desktop
u() { sudo -u user "$@"; }

if [ "${1:-}" = --undo ]; then
    rm -f "$APPS/com.moonlight_stream.Moonlight.desktop" "$H/.local/bin/y700-moonlight"
    [ -f "$BAK" ] && u cp "$BAK" "$ICON" && rm -f "$BAK"
    bash "$SRC/ml-hud-fps.sh" off >/dev/null
    u update-desktop-database "$APPS" 2>/dev/null || true
    echo "undone"; exit 0
fi

u install -m 755 "$SRC/y700-moonlight" "$H/.local/bin/y700-moonlight"
[ -f "$ICON" ] && [ ! -f "$BAK" ] && u cp -p "$ICON" "$BAK"
# the export is the template: only Exec changes
sed -e "s|^Exec=.*|Exec=$H/.local/bin/y700-moonlight|" "$EXPORT" > /tmp/y700-ml.desktop
grep -q "^Exec=$H/.local/bin/y700-moonlight$" /tmp/y700-ml.desktop
u install -m 644 /tmp/y700-ml.desktop "$APPS/com.moonlight_stream.Moonlight.desktop"
u install -m 755 /tmp/y700-ml.desktop "$ICON"
rm -f /tmp/y700-ml.desktop
u update-desktop-database "$APPS" 2>/dev/null || true
bash "$SRC/ml-hud-fps.sh" on >/dev/null
grep -H '^Exec' "$APPS/com.moonlight_stream.Moonlight.desktop" "$ICON"
