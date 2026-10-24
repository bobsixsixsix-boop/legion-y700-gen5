#!/bin/bash
# install.sh (2026-10-18): ROOT on the tablet, from a copy of y700/linux/power/gpu-floor. Builds the daemon (Rust, no
# dependencies, offline), runs its unit tests, installs
#   /usr/local/sbin/y700-gpu-floor              the daemon
#   /etc/systemd/system/y700-gpu-floor.service  enabled and started
#   /etc/default/y700-gpu-floor                 FLOOR_MHZ etc. (an existing file is kept)
# Undo: systemctl disable --now y700-gpu-floor (ExecStopPost gives the floor back).
set -eu
H=$(cd "$(dirname "$0")" && pwd)
command -v cargo >/dev/null || { echo "cargo missing (apt install cargo: ask the owner first)" >&2; exit 2; }
find "$H" -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.sh' -o -name '*.service' -o -name '*.default' \) -exec sed -i 's/\r$//' {} +
SRC=/root/src/y700-gpu-floor
install -d $SRC
cp -r "$H/Cargo.toml" "$H/src" $SRC/
(cd $SRC && cargo build --release --offline && cargo test --release --offline --quiet)
systemctl stop y700-gpu-floor 2>/dev/null || true
install -m 755 $SRC/target/release/y700-gpu-floor /usr/local/sbin/y700-gpu-floor
install -m 644 "$H/y700-gpu-floor.service" /etc/systemd/system/y700-gpu-floor.service
[ -e /etc/default/y700-gpu-floor ] || install -m 644 "$H/y700-gpu-floor.default" /etc/default/y700-gpu-floor
systemctl daemon-reload
systemctl enable --now y700-gpu-floor
sleep 1
st=$(systemctl is-active y700-gpu-floor || true); echo "$st"
journalctl -u y700-gpu-floor -n 3 --no-pager
[ "$st" = active ] || { echo "y700-gpu-floor is not running" >&2; exit 1; }
echo "INSTALL_OK $(sha256sum /usr/local/sbin/y700-gpu-floor | cut -c1-16)"
