#!/bin/sh
# Build, test and install y700-speaker-guard on the tablet (run as root from this directory):
#   /usr/local/libexec/y700-speaker-guard            (the one it replaces: /root/y700-speaker-guard.bak-<time>)
#   /etc/systemd/user/y700-speaker-guard.service     (../y700-speaker-guard.service; pipewire.service wants it)
# The service belongs to the session user's manager: restarted with `systemctl --user -M user@`.
# Rollback (the bash version, git 05ebb3c linux/audio/y700-speaker-guard, keeps no state either):
#   install -m755 /root/y700-speaker-guard.bak-<time> /usr/local/libexec/y700-speaker-guard
#   systemctl --user -M user@ restart y700-speaker-guard
set -e
cd "$(dirname "$0")"
cargo build --release --offline
cargo test --release --offline
bin=/usr/local/libexec/y700-speaker-guard
[ -e $bin ] && cp -p $bin /root/y700-speaker-guard.bak-$(date +%Y%m%d-%H%M%S)
install -m755 target/release/y700-speaker-guard $bin.new
mv $bin.new $bin
install -Dm644 ../y700-speaker-guard.service /etc/systemd/user/y700-speaker-guard.service
sync
systemctl --user -M user@ daemon-reload
systemctl --user -M user@ restart y700-speaker-guard
echo INSTALL_OK
