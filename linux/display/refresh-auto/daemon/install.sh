#!/bin/sh
# Build, test and install the Rust y700-refresh-auto on the tablet (run as root from this directory):
#   /usr/local/libexec/y700-refresh-auto                              (one it replaces: /root/y700-refresh-auto.bak-<time>)
#   /home/user/.config/systemd/user/y700-refresh-auto.service     (../y700-refresh-auto.service: ExecStart and
#                                                                      ExecStopPost --restore point at the binary above)
# The unit it replaces is kept as /root/y700-refresh-auto.service.bak-<time>. try-restart: a stopped service stays
# stopped; a running one gets SIGTERM (the old daemon puts the base rate back itself, ExecStopPost --restore too) and
# the new one starts. Only the daemon changes: the KWin script, the mpv script, wiliwili's patch, the Chrome host, the
# config file (~/.config/y700-refresh-auto.json), the state files and the fg log stay as they are.
# On a fresh tablet run this before ../install.sh (unit, KWin and mpv scripts, display watchdog, wiliwili), which exits
# if this binary is missing; to update only the daemon, this script alone is enough.
# Rollback to Python (git 669f79f linux/display/refresh-auto/y700-refresh-auto, still at ~/.local/bin/y700-refresh-auto;
# same config and state files, nothing to convert):
#   install -o user -g user -m644 /root/y700-refresh-auto.service.bak-<time> /home/user/.config/systemd/user/y700-refresh-auto.service
#   systemctl --user -M user@ daemon-reload && systemctl --user -M user@ try-restart y700-refresh-auto
set -e
cd "$(dirname "$0")"
cargo build --release --offline
cargo test --release --offline
now=$(date +%Y%m%d-%H%M%S)
bin=/usr/local/libexec/y700-refresh-auto
unit=/home/user/.config/systemd/user/y700-refresh-auto.service
[ -e $bin ] && cp -p $bin /root/y700-refresh-auto.bak-$now
[ -e $unit ] && cp -p $unit /root/y700-refresh-auto.service.bak-$now
install -m755 target/release/y700-refresh-auto $bin.new
mv $bin.new $bin
install -o user -g user -m644 ../y700-refresh-auto.service $unit
sync
systemctl --user -M user@ daemon-reload
systemctl --user -M user@ try-restart y700-refresh-auto
echo INSTALL_OK
