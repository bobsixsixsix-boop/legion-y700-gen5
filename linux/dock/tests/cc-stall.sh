# sb-bed scenario (10-31, run by cc-stall-run.sh): the control centre with peers that never answer (10-31 audit C1;
# src/backend.cpp STATUS_CMD / refresh / runCapture, README「控制中心」第十七轮). Until 10-31 one command of the status
# pipeline that never returned (bluetoothctl with bluetoothd masked or gone, tailscale with tailscaled hung) kept the
# pipeline "running" for good: refresh() returned at its first line from then on, and the whole sheet froze silently.
#   sh ./cc-stall-run.sh /root/sb-cc-stall          (root; about 75 s; SB_CC=BIN for a candidate build)
# The stand-ins (cc-stall-bin/, first on the control centre's PATH) log each call to $XDG_RUNTIME_DIR/cc-stall.calls
# as "<pid> <command> <args>": bluetoothctl and `tailscale status` wait for ever; pw-cli (the ===REC section, after
# both) answers, or waits for ever while $XDG_RUNTIME_DIR/cc-stall.pwhang exists. Nothing is tapped.
#   h1  open 20 s, bluetoothd and tailscaled hung   -> 2 or more pipelines get past both (pw-cli calls; the old
#                                                      backend: 0, stuck in its first bluetoothctl); 9 s after closing
#                                                      (past the pipeline's 8 s bound) no stand-in left waiting
#   h2  the same with pw-cli hanging too            -> the 8 s bound cuts the pipeline 2 or more times ("status: timed
#                                                      out in section REC" in the log: the lock is released each time,
#                                                      the grandchild killed); 9 s after closing none left waiting
# b1-b3 (C2, src/backend.cpp readBrightness): fake-brightness.py (copied along by the runner) is PowerDevil's
# org.kde.ScreenBrightness on the bed's bus; shots OUT/b1-open.png, b3-open.png, read as pill-drag.sh reads a pill.
#   b1  open on 6000 of 10000                       -> the brightness pill 60 %
#   b2  the fake stopped (kill -STOP: holds its name, never answers): show and hide over D-Bus each answered within
#       2 s (the old backend: show blocked in its synchronous read, up to 25 s per property; busctl gives up at 5 s)
#   b3  the fake on again, set to 3000 by another client; reopen -> the pill 30 % (nothing left stuck by b2)
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "cc-stall.sh: ..." lines are notes.
CALLS=$XDG_RUNTIME_DIR/cc-stall.calls
FAKE=$(dirname "$CC")           # the runner's wrapper sits with the stand-ins
say() { echo "cc-stall.sh: $*"; echo "cc-stall.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: cc-stall.sh: $*"; echo "cc-stall.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
if [ ! -x "$FAKE/bluetoothctl" ] || [ ! -x "$FAKE/pw-cli" ]; then
    bad "no stand-ins next to $CC (run cc-stall-run.sh, not sb-bed.sh directly)"
    return 0
fi
: >> "$CALLS"
n() { grep -c " $1 " "$CALLS"; }
# a logged pid still the stand-in's `sleep 600` (checked before a kill too: a pid that died may have been reused)
waiting() { [ "$(tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline")" = "sleep 600 " ]; }
left() { c=0; for p in $(cut -d' ' -f1 "$CALLS"); do waiting "$p" && c=$((c + 1)); done; echo $c; }
since() { tail -n +$((MARK + 1)) "$LOG" | grep -c -- "$1"; }

# ---------------- h1: bluetoothd and tailscaled hung
mark h1
p0=$(n pw-cli)
cc show; sleep 20; cc hide; sleep 9
p=$(( $(n pw-cli) - p0 )); l=$(left)
say "h1: $p pipelines past both stalls, $(n bluetoothctl) bluetoothctl and $(n tailscale) tailscale calls, $l left waiting"
[ "$p" -ge 2 ] || bad "h1: $p status pipelines got past bluetoothctl and tailscale in 20 s open, want 2 or more (stuck)"
[ "$l" = 0 ] || bad "h1: $l stand-ins still waiting 9 s after closing (no timeout reached them)"

# ---------------- h2: a command without a timeout of its own hangs too: the outer bound
mark h2
: > "$XDG_RUNTIME_DIR/cc-stall.pwhang"     # not `touch`: in a bed scenario that is the ftouch helper (sb-bed.sh)
cc show; sleep 20; cc hide; sleep 9
t=$(since "status: timed out in section REC"); l=$(left)
say "h2: $t pipelines cut in section REC, $l left waiting"
[ "$t" -ge 2 ] || bad "h2: the pipeline was cut $t times in 20 s open, want 2 or more (the lock not released?)"
[ "$l" = 0 ] || bad "h2: $l stand-ins still waiting 9 s after closing (the bound did not reach the grandchild)"
rm -f "$XDG_RUNTIME_DIR/cc-stall.pwhang"

# ---------------- b1-b3: the brightness read at an opening (C2), against fake-brightness.py on the bed's bus
BF=$FAKE/fake-brightness.py
# pill SHOT: the brightness pill's fill (x 1204-1544, centre y 420) off OUT/SHOT.png, read as pill-drag.sh's fill();
# nothing when the pill's chip is not where it should be (the curtain not up, the layout moved)
pill() {
    python3 - "$OUT/$1.png" 2>> "$LOG" <<'PY'
import sys
import numpy as np
from PIL import Image
im = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
X0, X1, CY = 1204, 1544, 420
c = im[CY, 1218]
if c[0] < 110 and c[2] > 190:
    white = im[CY - 21:CY - 18, X0:X1].min(axis=0).min(axis=1) >= 200
    w = float(white.nonzero()[0][-1] + 1) if white.any() else 0.0
    w = 310 + ((w - 310) ** 2 + 100) / 20 if w > 310 else w
    print("%.3f" % min(1.0, w / (X1 - X0)))
PY
}
near() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a ~ /^[0-9.]+$/ && a - b < 0.012 && b - a < 0.012) }'; }
# show / hide timed: "RC MS"
timed() {
    t0=$(date +%s%N)
    busctl --user --timeout=5 call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1
    echo "$? $(( ($(date +%s%N) - t0) / 1000000 ))"
}
mark b1
BP=
if [ ! -f "$BF" ]; then
    bad "b: no $BF next to $CC (cc-stall-run.sh copies it along)"
else
    python3 "$BF" 6000 >> "$LOG" 2>&1 &
    BP=$!
    i=0; while [ "$(since 'FAKEBRIGHT up as')" = 0 ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
fi
if [ -n "$BP" ] && [ "$(since 'FAKEBRIGHT up as')" != 0 ]; then
    cc show; sleep 1.2; shot b1-open; cc hide; sleep 0.8
    f=$(pill b1-open); g=$(since "FAKEBRIGHT get Brightness")
    say "b1: the pill at '$f' after opening on 6000 of 10000 ($g reads)"
    [ "$g" -ge 1 ] || bad "b1: the opening did not read the brightness"
    near "$f" 0.60 || bad "b1: the pill at '$f' after opening on 6000 of 10000, want 0.60"

    # b2: PowerDevil holds its name and never answers: the D-Bus calls the control centre answers on its GUI thread
    # must not wait for it (the old backend: show blocked in its synchronous read, busctl gave up after 5 s)
    mark b2
    kill -STOP "$BP"
    s=$(timed show); h=$(timed hide)
    say "b2: brightness hung: show answered rc/ms $s, hide $h"
    fast() { [ "${2% *}" = 0 ] && [ "${2#* }" -lt 2000 ] || bad "b2: $1 rc ${2% *} after ${2#* } ms with the brightness hung, want 0 within 2 s"; }
    fast show "$s"; fast hide "$h"
    kill -CONT "$BP"; sleep 1.5

    # b3: answering again, at another level: the next opening reads it (the hung read left nothing stuck)
    mark b3
    busctl --user call org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display \
        SetBrightness iu 3000 0 >/dev/null 2>&1 || say "b3: SetBrightness on the fake failed"
    cc show; sleep 1.2; shot b3-open; cc hide; sleep 0.8
    f=$(pill b3-open)
    say "b3: the pill at '$f' after reopening on 3000 of 10000"
    near "$f" 0.30 || bad "b3: the pill at '$f' after reopening on 3000 of 10000, want 0.30"
else
    [ -z "$BP" ] || bad "b: fake-brightness.py not up: $(grep -F FAKEBRIGHT "$LOG" | tail -n 1)"
fi
[ -z "$BP" ] || kill "$BP" 2>/dev/null

# the old backend leaves its stand-ins waiting: they must not outlive the bed. Its unbounded pipeline shell (the
# stand-in's parent, reparented to init when the bed's control centre goes) too: with only the stand-in killed it went
# on to the next one and waited there for another 10 min (10-31, seen after an old-backend run)
for p in $(cut -d' ' -f1 "$CALLS"); do
    waiting "$p" || continue
    pp=$(ps -o ppid= -p "$p" | tr -d ' ')
    case $(tr '\0' ' ' 2>/dev/null < "/proc/$pp/cmdline") in "/bin/sh -c tb323fu-ctl"*) kill "$pp" ;; esac
    kill "$p"
done
say "done (FAIL=$FAIL)"
