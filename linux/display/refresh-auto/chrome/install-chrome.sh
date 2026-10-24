#!/bin/bash
# install-chrome.sh (2026-10-18): ROOT on the tablet, from a copy of y700/linux/display/refresh-auto/chrome. Lets
# y700-refresh-auto lower the panel for Chrome videos too:
#   ~/src/y700-chrome-video-state/        build tree of the native host (host/, Rust, no dependencies)
#   ~/.local/bin/y700-chrome-video-state  the host
#   ~/.config/google-chrome/NativeMessagingHosts/fyi.y700.video_state.json   allows only our extension id
#   /usr/local/share/y700-chrome-video-state/y700-video-state.crx            ext/ packed with the fixed key
#   /usr/share/google-chrome/extensions/<id>.json                           Chrome's "external extension" pointer
# Chrome 137+ ignores --load-extension in branded builds, so the extension is installed the documented Linux way
# (external_crx). Chrome reads that at start: after the first install, restart Chrome and confirm "enable" in the
# prompt (menu) once; a version bump in ext/manifest.json + this script updates it at a later start.
# The signing key (/root/y700-chrome-ext-key.pem; keep a backup copy outside the repo) fixes the id
# cgphccdichbpkkdlbnekjojganogdimg, which must match manifest.json "key". Without it the script stops.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
O=user; HD=/home/$O; SRC=$HD/src/y700-chrome-video-state
ID=cgphccdichbpkkdlbnekjojganogdimg
KEY=/root/y700-chrome-ext-key.pem
SH=/usr/local/share/y700-chrome-video-state; EXTD=/usr/share/google-chrome/extensions
NMH=$HD/.config/google-chrome/NativeMessagingHosts
[ -r $KEY ] || { echo "no signing key $KEY (restore it from your own backup)" >&2; exit 2; }
command -v cargo >/dev/null || { echo "cargo missing (apt install cargo)" >&2; exit 2; }
find "$H" -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.js' -o -name '*.json' -o -name '*.sh' \) -exec sed -i 's/\r$//' {} +
# 1. the host, built and tested as the owner (offline: no dependencies)
install -d -o $O -g $O $HD/src $SRC
cp -r "$H/host/." $SRC/
chown -R $O:$O $SRC
sudo -u $O -H sh -c "cd $SRC && cargo build --release --offline && cargo test --release --offline --quiet"
install -d -o $O -g $O $HD/.local $HD/.local/bin
install -o $O -g $O -m 755 $SRC/target/release/y700-chrome-video-state $HD/.local/bin/y700-chrome-video-state
install -d -o $O -g $O -m 700 $NMH
cat > $NMH/fyi.y700.video_state.json <<EOF
{
  "name": "fyi.y700.video_state",
  "description": "Y700: full-screen video state for y700-refresh-auto",
  "path": "$HD/.local/bin/y700-chrome-video-state",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$ID/"]
}
EOF
chown $O:$O $NMH/fyi.y700.video_state.json
# 2. the extension, packed as the owner (Chrome will not run as root) with a temporary copy of the key
W=$(mktemp -d /tmp/y700-pack.XXXX); trap 'rm -rf $W' EXIT   # holds a copy of the private key: gone on any exit
cp -r "$H/ext" $W/ext; install -m 600 $KEY $W/key.pem; chown -R $O:$O $W
sudo -u $O env HOME=$HD timeout 60 /opt/google/chrome/chrome --ozone-platform=headless --headless=new \
  --user-data-dir=$W/prof --pack-extension=$W/ext --pack-extension-key=$W/key.pem >$W/pack.log 2>&1 || true
[ -s $W/ext.crx ] || { cat $W/pack.log >&2; echo "packing failed" >&2; exit 1; }
VER=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$H/ext/manifest.json")
install -d -m 755 $SH $EXTD
install -m 644 $W/ext.crx $SH/y700-video-state.crx
printf '{\n  "external_crx": "%s/y700-video-state.crx",\n  "external_version": "%s"\n}\n' $SH "$VER" > $EXTD/$ID.json
chmod 644 $EXTD/$ID.json
echo "INSTALL_OK host $(sha256sum $HD/.local/bin/y700-chrome-video-state | cut -c1-16), extension $ID version $VER"
echo "Chrome picks the extension up at its next start (then: enable it once in the menu prompt)."
