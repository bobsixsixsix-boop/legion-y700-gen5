#!/bin/bash
# App-side configuration.  Every step here has bitten someone already.
# (y700: reference copy from code002-2/sm8750-video-accel; configs/ lives next to this script here.
#  Chrome on the tablet is configured through its .desktop launchers' Exec= flags, not by this script: the flags
#  in configs/chrome-flags.conf with --ozone-platform=wayland for the hint, plus --enable-wayland-ime
#  --wayland-text-input-version=3 and WebRtcPipeWireCamera,PlatformHEVCDecoderSupport in --enable-features.)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
U=${1:-$(id -un 1000 2>/dev/null || echo piano)}
H=$(getent passwd "$U" | cut -d: -f6)
[ -d "$H" ] || { echo "no home for user $U" >&2; exit 1; }

echo "== mpv =="
install -d -o "$U" -g "$U" "$H/.config/mpv"
cp "$HERE/configs/mpv.conf" "$H/.config/mpv/mpv.conf"
chown "$U:$U" "$H/.config/mpv/mpv.conf"
echo "  $H/.config/mpv/mpv.conf"

echo "== firefox =="
for d in /etc/firefox/policies /etc/firefox-esr/policies; do
  mkdir -p "$d"
  cp "$HERE/configs/firefox-policies.json" "$d/policies.json"
done
echo "  policies installed in /etc/firefox*/policies/"
# user.js must go into the profile Firefox actually uses.  Find it, never guess:
# profiles.ini can list several, and the [Install...] section decides which one wins.
found=0
for p in $(find "$H/.mozilla/firefox" -maxdepth 1 -type d -name '*.default*' 2>/dev/null); do
  cp "$HERE/configs/firefox-user.js" "$p/user.js"
  chown "$U:$U" "$p/user.js"
  echo "  $p/user.js"
  found=$((found+1))
done
[ "$found" = 0 ] && echo "  no profile yet - start Firefox once, then re-run this step"

echo "== chrome =="
install -d -o "$U" -g "$U" "$H/.config"
cp "$HERE/configs/chrome-flags.conf" "$H/.config/chrome-flags.conf"
chown "$U:$U" "$H/.config/chrome-flags.conf"
echo "  $H/.config/chrome-flags.conf"

# Patch the launcher so the flags apply when started from the menu.
# TWO THINGS MATTER:
#   1. Exec= must START with the executable.  Flags in front still pass
#      desktop-file-validate but make GNOME drop the menu entry entirely.
#   2. Desktop files run without the user's shell config, so chrome-flags.conf
#      is not read by Chrome itself (that is a Chromium-wrapper feature).
F=/usr/share/applications/google-chrome.desktop
if [ -f "$F" ]; then
  [ -f "$F.orig" ] || cp -a "$F" "$F.orig"
  FLAGS=$(grep -vE '^\s*#|^\s*$' "$HERE/configs/chrome-flags.conf" | tr '\n' ' ')
  python3 - "$F" "$FLAGS" <<'PY'
import re, sys
path, flags = sys.argv[1], sys.argv[2].strip()
s = open(path).read()
out, n = [], 0
for line in s.splitlines(True):
    if line.startswith('Exec=') and 'google-chrome' in line:
        parts = line[len('Exec='):].rstrip('\n').split(' ', 1)
        exe, rest = parts[0], (parts[1] if len(parts) > 1 else '')
        # strip anything we added previously, keep --incognito and field codes
        for opt in ('--enable-features=', '--ozone-platform-hint=', '--enable-zero-copy',
                    '--ignore-gpu-blocklist', '--enable-gpu-rasterization'):
            rest = re.sub(re.escape(opt) + r'\S*\s*', '', rest)
        line = f"Exec={exe} {flags}" + (f" {rest.strip()}" if rest.strip() else "") + "\n"
        n += 1
    out.append(line)
open(path, 'w').writelines(out)
print(f"  patched {n} Exec line(s) in {path}")
PY
  echo "  --- verify the way the menu does: first token must be executable ---"
  grep '^Exec=' "$F" | sed 's/^Exec=//' | awk '{print $1}' | sort -u | while read -r e; do
    printf '    %-36s %s\n' "$e" "$([ -x "$e" ] && echo 'executable' || echo 'NOT EXECUTABLE - the menu will hide this entry')"
  done
  command -v desktop-file-validate >/dev/null && desktop-file-validate "$F" && echo "  desktop-file-validate: OK"
  update-desktop-database /usr/share/applications 2>/dev/null || true
  echo "  menu database refreshed"
else
  echo "  google-chrome.desktop not found - skipping the launcher patch"
fi

echo
echo "Fully close and reopen the browsers for this to take effect."
