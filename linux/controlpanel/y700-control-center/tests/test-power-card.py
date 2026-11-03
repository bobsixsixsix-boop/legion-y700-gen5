#!/usr/bin/env python3
# test-power-card.py [SRC]: the power card (qml/Main.qml, the far column's bottom line) offers nothing that can only
# fail, and still lines up (10-31 audit C3; README「控制中心」第十七轮). Offline, no Qt: reads SRC/qml/Main.qml and
# SRC/qml/icons/ (SRC = the y700-control-center source dir, default this script's parent; an old checkout's copy shows
# the old card fail).
#   - no button runs systemctl suspend / hibernate / hybrid-sleep / suspend-then-hibernate: those targets are masked
#     since 10-15 (README 续航「永不休眠」), such a button fails every time, and its error toast lands on a closing curtain
#   - the card's two-column grid (wide = both columns) has no half-empty row, and keeps its 3 rows (the far column's
#     trayRoom, Main.qml, was laid out with the card's height)
#   - reboot and power off still ask twice; every icon the card names is in qml/icons/, and sleep.svg (only the
#     suspend button used it) is gone
#   Windows: C:/Users/me/AI/y700/tools/venv/Scripts/python -X utf8 -I -B tests/test-power-card.py     Linux: python3 ...
# Prints one line per check and OK / FAIL; exit 1 on a failure.
import os
import re
import sys

SRC = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
QML = open(os.path.join(SRC, "qml", "Main.qml"), encoding="utf-8").read()
ICONS = os.path.join(SRC, "qml", "icons")
fails = []


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        fails.append(what)


card = QML[QML.index("id: powerCard"):QML.index("id: androidCard")]
model = card[card.index("model: ["):]
model = model[:model.index("]\n")]          # the array's closing bracket ends its line; no entry has one
items = []
for m in re.finditer(r'\{\s*k:\s*"([\w-]+)"(.*?)\}', model, re.S):
    f = m.group(2)
    icon = re.search(r'\bi:\s*"([\w-]+)"', f)
    cmd = re.search(r'\bcmd:\s*"([^"]*)"', f)
    items.append({"k": m.group(1), "wide": re.search(r"\bwide:\s*true", f) is not None,
                  "confirm": re.search(r"\bconfirm:\s*true", f) is not None,
                  "i": icon.group(1) if icon else None, "cmd": cmd.group(1) if cmd else ""})
check(len(items) >= 3, "the card's model read: %s" % [d["k"] for d in items])

sleepers = re.findall(r"systemctl\s+(?:suspend|hibernate|hybrid-sleep|suspend-then-hibernate)\b", QML)
check(not sleepers, "Main.qml runs no masked sleep target: %s" % sleepers)

rows, row = [], []
for d in items:
    span = 2 if d["wide"] else 1
    if sum(s for _, s in row) + span > 2:
        rows.append(row); row = []
    row.append((d["k"], span))
if row:
    rows.append(row)
half = [r for r in rows if sum(s for _, s in r) != 2]
check(not half, "every row of the 2-column grid full: %s" % [[k for k, _ in r] for r in rows])
check(len(rows) == 3, "the card keeps its 3 rows (its height): %d" % len(rows))

for k in ("reboot", "poweroff"):
    d = next((d for d in items if d["k"] == k), None)
    check(d is not None and d["confirm"], "%s is there and asks twice" % k)
missing = [d["i"] for d in items if not d["i"] or not os.path.exists(os.path.join(ICONS, d["i"] + ".svg"))]
check(not missing, "every icon the card names is in qml/icons/: missing %s" % missing)
check(not os.path.exists(os.path.join(ICONS, "sleep.svg")), "qml/icons/sleep.svg is gone (only the suspend button used it)")

print("FAIL %d" % len(fails) if fails else "OK")
sys.exit(1 if fails else 0)
