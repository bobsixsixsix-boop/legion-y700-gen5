#!/bin/sh
# Build, test and install y700-kmsg-watch on the tablet (run as root from this directory, in a copy of the repo's
# linux/ tree: cargo test reads ../y700-*-watchdog*, ../y700-kmsg-watch.service, ../y700-watchdog-safety.conf
# and ../../power/cx-collapse/crash-0341-lastkmsg.log; ../../kernel-y8/inventory/dmesg, the author's boot log, is
# kept local (inventory/.gitignore) and without it T2/T3 print SKIP instead of failing):
#   /usr/local/libexec/y700-kmsg-watch                  (the one it replaces: /root/y700-kmsg-watch.bak-<time>)
#   /etc/systemd/system/y700-kmsg-watch.service         (../y700-kmsg-watch.service, only if it differs; the old one:
#                                                        /root/y700-kmsg-watch.service.bak-<time>)
# try-restart: a watcher someone stopped stays stopped. Every start of the watcher starts both watchdogs once (catch-up
# for the lines logged while nothing was reading), as every restart of the Python one did; so does the --selftest at
# the end (the same ping the daily checklist sends).
# Rollback to Python (git 1814212 linux/net/y700-kmsg-watch; no state to convert):
#   install -m755 /root/y700-kmsg-watch.bak-<time> /usr/local/libexec/y700-kmsg-watch
#   (only if a unit backup was made) install -m644 /root/y700-kmsg-watch.service.bak-<time> /etc/systemd/system/y700-kmsg-watch.service && systemctl daemon-reload
#   systemctl try-restart y700-kmsg-watch && sleep 1 && /usr/local/libexec/y700-kmsg-watch --selftest
set -e
cd "$(dirname "$0")"
# the realtest build's compile-time replacements (src/main.rs) must never reach the installed binary
unset Y700KW_RT_SYSTEMCTL Y700KW_RT_RESULT Y700KW_RT_TAG
cargo build --release --offline
cargo test --release --offline
now=$(date +%Y%m%d-%H%M%S)
bin=/usr/local/libexec/y700-kmsg-watch
unit=/etc/systemd/system/y700-kmsg-watch.service
[ -e $bin ] && cp -p $bin /root/y700-kmsg-watch.bak-$now
install -m755 target/release/y700-kmsg-watch $bin.new
mv $bin.new $bin
if ! cmp -s ../y700-kmsg-watch.service $unit; then
	[ -e $unit ] && cp -p $unit /root/y700-kmsg-watch.service.bak-$now
	install -m644 ../y700-kmsg-watch.service $unit
	sync
	systemctl daemon-reload
fi
sync
systemctl try-restart y700-kmsg-watch
if systemctl -q is-active y700-kmsg-watch; then
	sleep 1      # it reads /dev/kmsg from its end: a ping written before it opened it is never seen
	$bin --selftest
fi
echo INSTALL_OK
