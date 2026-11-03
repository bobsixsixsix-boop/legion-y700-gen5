#!/usr/bin/env python3
# test-stalls.py [SRC]: a peer that never answers must not freeze the control centre (10-31 audit C1, C2; README
# 「控制中心」第十七轮). Offline, no Qt, no tablet: reads SRC/src/backend.cpp and SRC/qml/Main.qml (SRC = the
# y700-control-center source dir, default this script's parent; give an old checkout's copy to see the old code fail).
#   static  refresh() and runCapture() start their shell under `timeout N`, and a timed-out pipeline is not parsed;
#           STATUS_CMD gives bluetoothctl and `tailscale status` their own timeout; the Bluetooth tile and btToggle
#           prefix bluetoothctl with one. (C2) readBrightness() reads PowerDevil with an async GetAll whose answer does
#           not overwrite a drag or a write made since, and flushBrightness() neither introspects nor keeps a drag
#           made before the first answer (the bed half: linux/dock/tests/cc-stall.sh b1-b3).
#   run    (sh and GNU timeout: Linux, or Git Bash on Windows) STATUS_CMD and scanBt's command, started with the argv
#           refresh() / runCapture() give QProcess, with stand-ins first on PATH: bluetoothctl and `tailscale status`
#           never answer (a bluetoothd / tailscaled gone or hung), the rest print canned lines. The pipeline must end
#           by itself with every section after the stalls filled, the scan within its bound, and no stand-in may
#           outlive its run.
#   Windows: C:/Users/me/AI/y700/tools/venv/Scripts/python -X utf8 -I -B tests/test-stalls.py     Linux: python3 ...
# Prints one line per check and OK / FAIL; exit 1 on a failure. About 20 s (the scan waits out its 10 s bound).
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SRC = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CPP = open(os.path.join(SRC, "src", "backend.cpp"), encoding="utf-8").read()
QML = open(os.path.join(SRC, "qml", "Main.qml"), encoding="utf-8").read()
fails = []


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        fails.append(what)


def literals(text):
    """Adjacent C string literals from the start of text (whitespace between them), unescaped and joined."""
    out, i = [], 0
    while True:
        m = re.compile(r'\s*"((?:[^"\\]|\\.)*)"').match(text, i)
        if not m:
            return "".join(out)
        out.append(re.sub(r"\\(.)", lambda e: {"n": "\n", "t": "\t"}.get(e.group(1), e.group(1)), m.group(1)))
        i = m.end()


def body(name):
    i = CPP.index("void Backend::%s(" % name)
    return CPP[i:CPP.index("\n}\n", i)]


def argv(fn, obj):
    """The program and the literal arguments fn gives obj->start(): ["timeout", "8", "/bin/sh", "-c"]."""
    m = re.search(re.escape(obj) + r'->start\(\s*"([^"]*)"\s*,\s*\{([^}]*)\}', body(fn))
    return [m.group(1)] + re.findall(r'"([^"]*)"', m.group(2)) if m else []


def bounded(a):
    return len(a) >= 2 and a[0] == "timeout" and a[1].isdigit()


STATUS = literals(CPP[CPP.index("STATUS_CMD =") + len("STATUS_CMD ="):])
SCANBT = literals(body("scanBt")[body("scanBt").index("runCapture(") + len("runCapture("):])
A_REF, A_CAP = argv("refresh", "m_status"), argv("runCapture", "p")

# ---------------------------------------------------------------- static
check(bounded(A_REF), "refresh() starts the status pipeline under timeout: %s" % A_REF)
check(bounded(A_CAP), "runCapture() starts its command under timeout: %s" % A_CAP)
check("124" in body("refresh"), "refresh() leaves a timed-out pipeline (exit 124) unparsed")
for m in re.finditer(r"\bbluetoothctl\b|\btailscale status\b", STATUS):
    check(re.search(r"timeout \d+ $", STATUS[:m.start()]) is not None, "STATUS_CMD: `%s` has its own timeout" % m.group(0))
m = re.search(r'act\("bt",\s*"([^"]*)"', QML)
check(bool(m) and re.match(r"timeout \d+ bluetoothctl ", m.group(1)) is not None,
      "Main.qml Bluetooth tile: %r" % (m.group(1) if m else None))
m = re.search(r'act\("bt-dev",\s*QString\("([^"]*)"', CPP)
check(bool(m) and re.match(r"timeout \d+ bluetoothctl ", m.group(1)) is not None,
      "btToggle: %r" % (m.group(1) if m else None))
rb, fb = (re.sub(r"//[^\n]*", "", body(f)) for f in ("readBrightness", "flushBrightness"))    # code, not comments
check("QDBusInterface" not in rb and ".property(" not in rb and "asyncCall(" in rb,
      "readBrightness(): an async GetAll, no blocking QDBusInterface / property() on the GUI thread (C2)")
cb = rb[rb.find("finished"):]
check("finished" in rb and "m_pendingBrightness >= 0" in cb and "m_lastBrightnessWrite" in cb,
      "readBrightness(): the answer does not overwrite a drag in progress or a write made since the call (C2)")
check("QDBusInterface" not in fb, "flushBrightness(): no QDBusInterface (its introspection blocks) (C2)")
check("return" not in fb, "flushBrightness(): no early return, a drag before the first answer is cleared, not kept (C2)")

# ---------------------------------------------------------------- run
SH = "/bin/sh"
if os.name == "nt":       # Git's own bash (never C:/Windows/System32/bash.exe: that is WSL)
    SH = next((p for p in ("C:/Program Files/Git/usr/bin/bash.exe", "C:/Program Files/Git/bin/bash.exe") if os.path.exists(p)), None)
if not SH or not os.path.exists(SH):
    print("skip  run: no sh (Git Bash on Windows)")
else:
    d = tempfile.mkdtemp(prefix="cc-stalls-")
    stand = {
        # a daemon that is gone: wait for ever (exec: the pid logged is the waiting process)
        "bluetoothctl": 'echo $$ >> "$(dirname "$0")/pids"; echo "Waiting to connect to bluetoothd..."; exec sleep 60',
        "tailscale": '[ "$1" = status ] || exit 1; echo $$ >> "$(dirname "$0")/pids"; exec sleep 60',
        "tb323fu-ctl": 'echo \'{"Battery": {"Capacity": 57}}\'',
        "nmcli": 'case "$*" in *radio*) echo enabled ;; *active*) echo "home:802-11-wireless" ;; esac',
        "wpctl": 'echo "Volume: 0.40"',
        "pw-cli": 'exit 0',
        "systemctl": 'echo active',
    }
    for n, s in stand.items():
        with open(os.path.join(d, n), "w", encoding="utf-8", newline="\n") as f:
            f.write("#!/bin/sh\n" + s + "\n")
        os.chmod(os.path.join(d, n), 0o755)
    # the stand-ins first; /usr/bin next, so Git Bash finds GNU timeout before Windows' own timeout.exe
    wrap = ('d=$1; shift; command -v cygpath >/dev/null 2>&1 && d=$(cygpath -u "$d");'
            ' export HOME=$d PATH="$d:/usr/bin:$PATH"; exec "$@"')

    def run(a, cmd, label):
        guard = (int(a[1]) if bounded(a) else 10) + 5
        t0 = time.monotonic()
        # output to a file, not a pipe: a stand-in left waiting holds a pipe open, and reading it to the end would
        # wait for that stand-in too
        with tempfile.TemporaryFile() as f:
            p = subprocess.Popen([SH, "-c", wrap, "_", d] + a + [cmd], stdout=f, stderr=subprocess.DEVNULL)
            try:
                rc = p.wait(timeout=guard)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait(); rc = None
            f.seek(0); out = f.read().decode("utf-8", "replace")
        dt = time.monotonic() - t0
        check(rc is not None, "%s ends by itself (%.1f s, rc %s; guard %d s)" % (label, dt, rc, guard))
        return rc, out

    def alive():
        pids = open(os.path.join(d, "pids")).read().split() if os.path.exists(os.path.join(d, "pids")) else []
        p = subprocess.run([SH, "-c", 'for p; do kill -0 "$p" 2>/dev/null && echo "$p"; done', "_"] + pids,
                           capture_output=True, text=True)
        return pids, p.stdout.split()

    rc, out = run(A_REF, STATUS, "status pipeline, bluetoothd and tailscaled hung")
    check(rc is not None and rc != 124, "status pipeline: not cut by the outer bound (rc %s): the inner ones did it" % rc)
    for tag, want in (("VOL", "Volume: 0.40"), ("TS", ""), ("REC", "0"), ("AB", "active"), ("TSBIN", "tailscale")):
        i = out.find("===" + tag + "\n")
        sec = out[i + len(tag) + 4:].split("===")[0].strip() if i >= 0 else None
        check(sec is not None and want in sec, "status pipeline: section %s after the stalls: %r" % (tag, sec))
    pids, left = alive()
    check(len(pids) == 2 and not left, "status pipeline: stand-ins started %s, still waiting %s" % (pids, left))
    rc, out = run(A_CAP, SCANBT, "scanBt, bluetoothd gone")
    pids, left = alive()
    check(len(pids) >= 3 and not left, "scanBt: stand-ins started %s, still waiting %s" % (pids, left))
    shutil.rmtree(d, ignore_errors=True)

print("FAIL %d" % len(fails) if fails else "OK")
sys.exit(1 if fails else 0)
