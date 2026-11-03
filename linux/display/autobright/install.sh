#!/bin/sh
# Build, test and install y700-autobright on the tablet (run as root from this directory):
#   /usr/local/libexec/y700-autobright                              (the one it replaces: /root/y700-autobright.bak-<time>)
#   /home/user/.config/systemd/user/y700-autobright.service     (../y700-autobright.service; enabled or not is
#                                                                    the owner's, from the control centre's tile)
# The unit it replaces is kept as /root/y700-autobright.service.bak-<time>. try-restart: a service the owner switched
# off stays off.
# Rollback to Python (git ea2b225 linux/display/y700-autobright, still at ~/.local/bin/y700-autobright; same
# preference file, so nothing to convert):
#   install -o user -g user -m644 /root/y700-autobright.service.bak-<time> /home/user/.config/systemd/user/y700-autobright.service
#   systemctl --user -M user@ daemon-reload && systemctl --user -M user@ try-restart y700-autobright
set -e
cd "$(dirname "$0")"
cargo build --release --offline
cargo test --release --offline
now=$(date +%Y%m%d-%H%M%S)
bin=/usr/local/libexec/y700-autobright
unit=/home/user/.config/systemd/user/y700-autobright.service
[ -e $bin ] && cp -p $bin /root/y700-autobright.bak-$now
[ -e $unit ] && cp -p $unit /root/y700-autobright.service.bak-$now
install -m755 target/release/y700-autobright $bin.new
mv $bin.new $bin
install -o user -g user -m644 ../y700-autobright.service $unit
sync
systemctl --user -M user@ daemon-reload
systemctl --user -M user@ try-restart y700-autobright
echo INSTALL_OK
