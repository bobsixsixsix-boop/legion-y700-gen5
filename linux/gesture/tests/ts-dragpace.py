#!/usr/bin/env python3
"""Is a held drag over the cards drawn every frame? Two halves for ts-dragpace.sh (any machine with python3):

  ts-dragpace.py instrument BUILD   adds logging to BUILD/contents/ui/TaskSwitcher.qml (a COPY of a build):
                                    every touch move of a sideways scroll, every frame() and, from a second
                                    animation that always runs, one line per KWin frame with the scroll
                                    position render() last drew
  ts-dragpace.py analyze LOG        per frame of the middle 2/3 of the drag: did the picture move, and was
                                    every touch position drawn? Prints DRAGPACE_OK or DRAGPACE_FAIL

10-21 「滑动不松手就很卡」: the frame clock stopped once nothing was animating and every touch event restarted
it; the restart drew one event at once and left the next to the following frame, where the one after it was
drawn over it. Before the fix this printed 43 of 84 frames without movement and 52 of 115 positions never
drawn, after it 0 and 0.
"""
import re, statistics, sys

L = 'console.info("y700-taskswitcher: '


def instrument(build):
    p = build + "/contents/ui/TaskSwitcher.qml"
    s = open(p).read()

    def rep(a, b):
        nonlocal s
        if s.count(a) != 1:
            sys.exit(f"DRAGPACE_FAIL: TaskSwitcher.qml changed, cannot instrument at: {a.strip()[:60]}")
        s = s.replace(a, b)
    rep("    onClockChanged: frame()\n",
        "    onClockChanged: frame()\n"
        "    property real diagS: 0\n"
        "    property real diagT: 0\n"
        "    NumberAnimation on diagT { running: true; from: 0; to: 3600000; duration: 3600000; loops: Animation.Infinite }\n"
        "    onDiagTChanged: if (gesture && gesture.kind === \"scroll\") " + L + "TSD \" + Date.now() + \" \" + diagT.toFixed(1) + \" \" + diagS.toFixed(4))\n")
    rep("        const g = geo, zz = spr.z.v, L = 1 + (g.k - 1) * zz;\n",
        "        diagS = spr.s.v;\n        const g = geo, zz = spr.z.v, L = 1 + (g.k - 1) * zz;\n")
    rep("    function move(p): void {\n        const g = gesture;\n        if (!g) return;\n",
        "    function move(p): void {\n        const g = gesture;\n        if (!g) return;\n        const was = ticker.running;\n")
    # the last line of move(), at its own closing brace (the first "    }" at 4 spaces after its head: its blocks
    # are indented deeper). Not "move()'s end followed by up()": 10-22 the B+ dockReveal DBusCall went in between
    # and this failed to instrument every build from 3258dd7 on
    head = "    function move(p): void {\n"
    i = s.find(head)
    j = s.find("\n    }\n", i) if i >= 0 else -1
    if s.count(head) != 1 or j < 0:
        sys.exit("DRAGPACE_FAIL: TaskSwitcher.qml changed, cannot instrument at: the end of move()")
    s = (s[:j] + "\n        if (g.kind === \"scroll\") " + L + "TSM \" + Date.now() + \" \" + spr.s.v.toFixed(4)"
         " + \" ran=\" + was + \" drawn=\" + (diagS === spr.s.v));" + s[j:])
    rep("        const now = clock;\n",
        "        const now = clock;\n        if (gesture && gesture.kind === \"scroll\") " + L + "TSF \" + Date.now() + \" \" + now.toFixed(1));\n")
    open(p, "w").write(s)
    print("instrumented", p)


def analyze(log):
    ev = []
    for line in open(log, errors="replace"):
        m = re.search(r"y700-taskswitcher: (TS[DMF]) (.*)", line)
        if m:
            ev.append((m.group(1), m.group(2).split()))
    ticks = [e[1] for e in ev if e[0] == "TSD"]
    moves = [e[1] for e in ev if e[0] == "TSM"]
    if len(ticks) < 30 or len(moves) < 30:
        print(f"DRAGPACE_FAIL: only {len(ticks)} frames / {len(moves)} moves logged (no drag?)")
        return 1
    shown = [float(t[2]) for t in ticks]                  # what the previous frame ended up showing
    steps = [b - a for a, b in zip(shown, shown[1:])]
    mid = steps[len(steps) // 6: -(len(steps) // 6)]
    still = sum(1 for d in mid if abs(d) < 1e-6)
    seen = {round(v, 4) for v in shown}
    lost = sum(1 for m in moves if round(float(m[1]), 4) not in seen)
    restarts = sum(1 for m in moves if "ran=false" in m)
    pos = [d for d in mid if abs(d) >= 1e-6]
    even = statistics.pstdev(pos) / abs(statistics.mean(pos)) if len(pos) > 2 and statistics.mean(pos) else 0
    print(f"{len(ticks)} frames, {len(moves)} touch moves ({restarts} restarted the frame clock); middle of the drag: "
          f"{still} of {len(mid)} frames without movement, step stdev/mean {even:.2f}; "
          f"{lost} of {len(moves)} touch positions never drawn")
    ok = still <= len(mid) * .1 and lost <= len(moves) * .1
    print("DRAGPACE_OK" if ok else "DRAGPACE_FAIL: a held drag is not drawn every frame")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "instrument":
        instrument(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "analyze":
        sys.exit(analyze(sys.argv[2]))
    else:
        sys.exit(__doc__)
