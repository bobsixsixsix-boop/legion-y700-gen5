#!/bin/bash
# install.sh (2026-10-20): ROOT on the tablet, from a copy of y700/linux/streaming/kwin-uclamp. Builds the daemon (Rust,
# no dependencies, offline), runs its unit tests, installs
#   /usr/local/sbin/y700-kwin-uclamp               the daemon
#   /etc/systemd/system/y700-kwin-uclamp.service   enabled and started
#   /etc/default/y700-kwin-uclamp                  UCLAMP_MIN, USER_UID, RESCAN_SEC, BOOST_* (an existing file is kept,
#                                                  the BOOST_* block is added if it has none;
#                                                  a missing key takes the built-in default)
# Undo: ./install.sh --undo  (= systemctl disable --now: ExecStopPost sets KWin back to 0; then the files go)
set -eu
H=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = --undo ]; then
    systemctl disable --now y700-kwin-uclamp 2>/dev/null || true
    rm -f /usr/local/sbin/y700-kwin-uclamp /etc/systemd/system/y700-kwin-uclamp.service /etc/default/y700-kwin-uclamp
    systemctl daemon-reload
    # the session KWin, not a headless test one (kwin_wayland --virtual of the task-switcher test bed)
    kp=$(for p in $(pgrep -x -u 1000 kwin_wayland); do tr '\0' ' ' < /proc/$p/cmdline | grep -q -- '--virtual' || echo $p; done | head -n 1)
    echo "undone; KWin: $(uclampset -p "$kp" 2>&1)"
    exit 0
fi
command -v cargo >/dev/null || { echo "cargo missing (apt install cargo: ask the owner first)" >&2; exit 2; }
find "$H" -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.sh' -o -name '*.service' -o -name '*.default' \) -exec sed -i 's/\r$//' {} +
SRC=/root/src/y700-kwin-uclamp
install -d $SRC
cp -r "$H/Cargo.toml" "$H/src" $SRC/
(cd $SRC && cargo build --release --offline && cargo test --release --offline --quiet)
systemctl stop y700-kwin-uclamp 2>/dev/null || true
install -m 755 $SRC/target/release/y700-kwin-uclamp /usr/local/sbin/y700-kwin-uclamp
install -m 644 "$H/y700-kwin-uclamp.service" /etc/systemd/system/y700-kwin-uclamp.service
[ -e /etc/default/y700-kwin-uclamp ] || install -m 644 "$H/y700-kwin-uclamp.default" /etc/default/y700-kwin-uclamp
# a file from before the touch boost (10-21): add its documented keys, the values already there stay
grep -q '^BOOST_GPU_MHZ=' /etc/default/y700-kwin-uclamp ||
    sed -n '/^# touch boost/,$p' "$H/y700-kwin-uclamp.default" >> /etc/default/y700-kwin-uclamp
systemctl daemon-reload
systemctl enable --now y700-kwin-uclamp
sleep 1
st=$(systemctl is-active y700-kwin-uclamp || true); echo "$st"
journalctl -u y700-kwin-uclamp -n 3 --no-pager -o cat
[ "$st" = active ] || { echo "y700-kwin-uclamp is not running" >&2; exit 1; }
/usr/local/sbin/y700-kwin-uclamp --status | cut -c1-160
echo "INSTALL_OK $(sha256sum /usr/local/sbin/y700-kwin-uclamp | cut -c1-16)"
