#!/bin/sh
# cc-stall-run.sh [OUT]: the cc-stall scenario (cc-stall.sh: the control centre with peers that never answer, README
# 「控制中心」第十七轮) in the headless bed (sb-bed.sh) against the INSTALLED control centre, or SB_CC=BIN for another
# build (installed under its own prefix, as vol-open-run.sh says). The control centre runs through a wrapper that puts
# cc-stall-bin/ (bluetoothctl, tailscale and pw-cli stand-ins, see each) first on its PATH; its children inherit it.
# Nothing else in the bed sees them. fake-brightness.py goes along for the scenario to start (steps b1-b3).
# Root; nothing is tapped and the screen is not touched, so it can run while the owner uses the tablet. About 75 s.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); U=user; OUT=${1:-/home/$U/cc-stall}
CC=$(readlink -f "${SB_CC:-/usr/local/bin/y700-control-center}")
D=$(mktemp -d /tmp/y700-ccstall-XXXXXX)
for f in bluetoothctl tailscale pw-cli; do
    install -m 755 "$HERE/cc-stall-bin/$f" "$D/$f" \
        || { echo "SBBED_FAIL: no $HERE/cc-stall-bin/$f (copy cc-stall-bin/ along with the tests)"; rm -rf "$D"; exit 1; }
done
# PowerDevil's brightness for steps b1-b3 (started by the scenario, on the bed's own bus)
install -m 644 "$HERE/fake-brightness.py" "$D/fake-brightness.py" || { echo "SBBED_FAIL: no $HERE/fake-brightness.py"; rm -rf "$D"; exit 1; }
printf '#!/bin/sh\n# cc-stall-run.sh: the control centre with the stand-ins first on its PATH\nPATH=%s:$PATH exec %s "$@"\n' "$D" "$CC" > "$D/y700-control-center"
chmod 755 "$D" "$D/y700-control-center"
SB_CC="$D/y700-control-center" sh "$HERE/sb-bed.sh" "$HERE/cc-stall.sh" "$OUT"; rc=$?
rm -rf "$D"
exit $rc
