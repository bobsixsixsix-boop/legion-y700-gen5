#!/bin/bash
# install.sh: build the game overlay (overlay/, Rust) on the tablet and install it with its scripts. ROOT, from a
# copy of y700/linux/games/hud on the tablet (scp -r it over, then `bash install.sh`). 2026-10-17.
#   ~/src/y700-hud-overlay/        the build tree (a copy of overlay/; target/ stays, a rebuild takes ~1 s)
#   ~/.local/bin/y700-hud-overlay  the binary; y700-hudinfo, y700-hud-toggle, y700-gl-hud next to it
#   ~/.config/systemd/user/y700-hud-overlay.service   (never enabled: y700-hud-toggle / the control centre start it)
#   ~/.config/MangoHud/MangoHud.conf                   (the FPS source for Vulkan games)
# Replaced files are backed up to /root/<name>.bak-<stamp>. A running overlay is restarted on the new binary.
# The service runs `y700-hud-overlay --sampler` since 10-22 (the status bar shows the numbers): a stopped one's
# cache files are removed here - a unit from before had no ExecStopPost, and the status bar would show the
# stale numbers for good.
# Build dependencies come from the official archive; installing them is the owner's call (2026-10-16: 243
# packages, 45 MB download, 457 MB on disk), so a missing one stops the script with the apt command.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
O=user; HD=/home/$O; B=$HD/.local/bin; SRC=$HD/src/y700-hud-overlay; UD=$HD/.config/systemd/user
U=(sudo -u $O env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
STAMP=$(date +%Y%m%d-%H%M%S)
missing=$(for p in cargo libgtk-4-dev libgtk4-layer-shell-dev librust-gtk4-dev librust-gtk4-layer-shell-dev; do
	dpkg -s $p >/dev/null 2>&1 || echo -n "$p "; done)
if [ -n "$missing" ]; then
	echo "build packages missing: apt install ${missing}(ask the owner first)" >&2; exit 2
fi
# build as the owner (cargo's offline Ubuntu registry: overlay/.cargo/config.toml); copies from Windows may be CRLF
install -d -o $O -g $O $HD/src $SRC
cp -r "$H/overlay/." $SRC/
find $SRC -path $SRC/target -prune -o -type f \( -name '*.rs' -o -name '*.toml' -o -name .gitignore \) -exec sed -i 's/\r$//' {} +
chown -R $O:$O $SRC
sudo -u $O -H sh -c "cd $SRC && cargo build --release && cargo test --release --quiet"
bak() { if [ -e "$1" ]; then cp -p "$1" "/root/$(basename "$1").bak-$STAMP"; fi; }
for f in y700-hud-overlay y700-hudinfo y700-hud-toggle y700-gl-hud; do bak $B/$f; done
install -o $O -g $O -m 755 $SRC/target/release/y700-hud-overlay $B/y700-hud-overlay
for f in y700-hudinfo y700-hud-toggle y700-gl-hud; do
	sed 's/\r$//' "$H/$f" > $B/$f.new && chown $O:$O $B/$f.new && chmod 755 $B/$f.new && mv $B/$f.new $B/$f
done
# the Python era's sampler module: nothing imports it any more
if [ -e $B/y700_hud_sampler.py ]; then mv $B/y700_hud_sampler.py /root/y700_hud_sampler.py.bak-$STAMP; fi
install -d -o $O -g $O $UD $HD/.config/MangoHud
bak $UD/y700-hud-overlay.service; bak $HD/.config/MangoHud/MangoHud.conf
sed 's/\r$//' "$H/y700-hud-overlay.service" > $UD/y700-hud-overlay.service; chown $O:$O $UD/y700-hud-overlay.service
sed 's/\r$//' "$H/MangoHud.conf" > $HD/.config/MangoHud/MangoHud.conf; chown $O:$O $HD/.config/MangoHud/MangoHud.conf
"${U[@]}" systemctl --user daemon-reload
"${U[@]}" systemctl --user try-restart y700-hud-overlay.service
"${U[@]}" systemctl --user is-active --quiet y700-hud-overlay.service || rm -f /run/user/1000/y700-hud.txt /run/user/1000/y700-hud.txt.kv
echo "installed $(sha256sum $B/y700-hud-overlay | cut -c1-16) (backups /root/*.bak-$STAMP); overlay $("${U[@]}" systemctl --user is-active y700-hud-overlay.service)"
"${U[@]}" $B/y700-hudinfo
