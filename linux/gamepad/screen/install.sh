#!/bin/sh
# Build, test and install y700-gamepad-screen on the tablet (run as root from this directory):
#   /usr/local/libexec/y700-gamepad-screen          (the one it replaces: /root/y700-gamepad-screen.bak-<time>)
#   /etc/systemd/system/y700-gamepad-screen.service
# Restarting the service while a G9 is plugged in and the screen is dark flashes its lights once.
# Rollback (the Python version reads and writes the same state.json):
#   install -m755 /root/y700-gamepad-screen.bak-<time> /usr/local/libexec/y700-gamepad-screen
#   systemctl restart y700-gamepad-screen
set -e
cd "$(dirname "$0")"
cargo build --release --offline
cargo test --release --offline
bin=/usr/local/libexec/y700-gamepad-screen
[ -e $bin ] && cp -p $bin /root/y700-gamepad-screen.bak-$(date +%Y%m%d-%H%M%S)
install -m755 target/release/y700-gamepad-screen $bin.new
mv $bin.new $bin
install -Dm644 y700-gamepad-screen.service /etc/systemd/system/y700-gamepad-screen.service
sync
systemctl daemon-reload
systemctl restart y700-gamepad-screen
echo INSTALL_OK
