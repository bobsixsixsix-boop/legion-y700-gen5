#!/usr/bin/env python3
# y700-appquit PID[_WINPID...] (2026-10-31): quit the app whose card was swiped away in the task switcher, not only
# hide its window (owner 10-21: 「把卡片继续往上划走就关掉那个程序」; 10-31: Steam and Claude only went to the tray).
# Started by the y700-taskswitcher effect (ui/AppQuit.qml) as y700-appquit@PID_WINPID_....service, 3 s after a
# swiped window went away: PID owned that window, the WINPIDs own the windows still there.
# Stops the app's systemd unit (app-*.scope / app-*.service under app.slice, where Plasma, the dock and Chromium put
# apps; SIGTERM to the whole unit, SIGKILL after 90 s, as at logout), then the units the descendants of its
# processes are in (Electron moves only its main process into a scope of its own: the zygotes, the GPU process and
# the renderers stay in the scope it started in, Claude 10-31). Leaves alone:
#   a PID that is gone (the app quit on its own) or not in an app unit (KWin, a y700 service, an ssh session)
#   a unit that still has a window (another window of the app; a game Steam started)
#   Telegram (no push service on the tablet: quit, no messages), a terminal (its unit holds every tab and what was
#   started from it), autostart units, LIVI (its launcher must tear the hotspot down itself)
#   any of these units, or one with a window or a kept one, holding a game (SteamAppId, linux/games/steam-game-kill.sh)
# Steam is asked to quit itself (steam-arm64 -shutdown, as linux/games/tests/steam-tri.sh), never stopped.
# Tests: linux/gesture/tests/test-appquit.py (sets PROC to a fake /proc).
import os
import re
import subprocess
import sys

PROC = "/proc"
KEEP = re.compile(r"telegram|konsole|livi|@autostart\.service$", re.I)
APP = re.compile(r"/app\.slice/(app-[^/\n]+\.(?:scope|service))(?:/|$)", re.M)
GAME = re.compile(r"(?:^|\0)Steam(?:App|Game)Id=[1-9]")


def read(pid, name):
    try:
        with open(f"{PROC}/{pid}/{name}", "rb") as f:
            return f.read().decode(errors="replace")
    except OSError:
        return ""


def unit(pid):
    m = APP.search(read(pid, "cgroup"))
    return m.group(1) if m else None


def plan(pid, wins):
    """(log line, commands to run) for the swiped window's PID and the WINS still there"""
    u = unit(pid)
    if not u:
        return f"{pid}: gone or not in an app unit, nothing to do", []
    if KEEP.search(u):
        return f"{pid}: {u} is kept running", []
    with_window = {unit(w) for w in wins}
    if u in with_window:
        return f"{pid}: {u} still has a window", []
    units, kids = {}, {}
    for p in (int(d) for d in os.listdir(PROC) if d.isdigit()):
        units[p] = unit(p)
        rest = read(p, "stat").rpartition(")")[2].split()   # "pid (comm) state ppid ...": comm may hold spaces
        if len(rest) > 1:
            kids.setdefault(int(rest[1]), []).append(p)
    desc, todo = [], [p for p, x in units.items() if x == u]   # from the whole app: Steam's window is steamwebhelper's
    while todo:
        p = todo.pop()
        desc.append(p)
        todo += kids.get(p, [])
    near = {u} | {x for x in map(units.get, desc) if x}
    # a game anywhere near, its unit with a window or not, kept or not: Steam's "never while a game of it runs"
    if any(GAME.search(read(p, "environ")) for p, x in units.items() if x in near):
        return f"{pid}: a game runs in {' '.join(sorted(near))}, nothing to do", []
    family = [u] + sorted(x for x in near - {u} if x not in with_window and not KEEP.search(x))
    members = [p for p, x in units.items() if x in family]
    if any(read(p, "comm").strip() == "steam" for p in members):
        return f"{pid}: {u} is Steam: steam-arm64 -shutdown", [[os.path.expanduser("~/.local/bin/steam-arm64"), "-shutdown"]]
    cmds = [["systemctl", "--user", "stop", u]] + [["systemctl", "--user", "stop", "--no-block", x] for x in family[1:]]
    return f"{pid}: stop {' then '.join(family)}", cmds


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9]+(?:_[0-9]+)*", sys.argv[1]):
        print("usage: y700-appquit PID[_WINPID...]", file=sys.stderr)
        return 2
    pid, *wins = map(int, sys.argv[1].split("_"))
    line, cmds = plan(pid, wins)
    print("y700-appquit:", line, flush=True)
    rc = 0
    for c in cmds:
        try:
            r = subprocess.run(c, timeout=120).returncode
            rc |= 0 if c[0] == "systemctl" and r == 5 else r   # 5: "not loaded", it quit on its own meanwhile
        except (OSError, subprocess.TimeoutExpired) as e:
            print("y700-appquit:", " ".join(c), "failed:", e, flush=True)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
