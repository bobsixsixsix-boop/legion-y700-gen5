#!/bin/sh
# ts-dragpace.sh BUILD OUT: is a finger held on the cards and dragged slowly drawn every frame? Runs an
# instrumented COPY of BUILD (taskswitcher/install.sh --build) in ts-bed.sh: open the cards from the desktop,
# then one sideways drag that never lifts (a motion every 15 ms, a bit faster than the bed's 60 Hz output,
# so every frame has a new position to draw). ts-dragpace.py decides; prints DRAGPACE_OK or DRAGPACE_FAIL.
# Headless like the scenarios (nothing on the real screen moves). Why it exists: README, 多任务卡片 → 踩坑 14.
set -u
BUILD=$(readlink -f "$1"); OUT=$(readlink -m "$2"); HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/y700-dragpace-XXXXXX)
trap 'rm -rf "$T"' EXIT
cp -r "$BUILD" "$T/build"
python3 "$HERE/ts-dragpace.py" instrument "$T/build" || exit 1
cat > "$T/scenario.sh" <<'EOF'
app Kate '#3d7bf7'
app Konsole '#2b2f36'
app Browser '#e8e8e8'
touch <<'T'
swipe 800 1001 800 650 350 250
T
sleep 1.5
mark drag
{
    echo "d 0 300 450"
    echo "s 120"
    i=1
    while [ $i -le 120 ]; do echo "m 0 $((300 + i * 5)) 450"; echo "s 15"; i=$((i + 1)); done
    echo "s 200"
    echo "u 0"
} | touch
sleep 1
mark end
EOF
[ "$(id -u)" = 0 ] && chmod -R a+rX "$T"
sh "$HERE/ts-bed.sh" "$T/build" "$T/scenario.sh" "$OUT" | grep -E '^TSBED_' || true
[ -f "$OUT/log" ] || { echo "DRAGPACE_FAIL: no log"; exit 1; }
sed -n '/TSBED-MARK drag/,/TSBED-MARK end/p' "$OUT/log" > "$OUT/drag.log"
python3 "$HERE/ts-dragpace.py" analyze "$OUT/drag.log"
