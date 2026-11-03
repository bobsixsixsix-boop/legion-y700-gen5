#!/usr/bin/env python3
"""test-appquit.py [APPQUIT]: offline test of taskswitcher/appquit.py (y700-appquit, 2026-10-31), the script a
swiped-away task-switcher card starts. No systemd, no tablet: plan() runs on a fake /proc in a temp dir (cgroup,
stat, comm, environ per pid, as the kernel writes them) and the commands it returns are compared, never run.
APPQUIT defaults to ../taskswitcher/appquit.py; on the tablet pass /usr/local/libexec/y700-appquit.
Prints PASS/FAIL per check and "ALL PASS" at the end; exit 1 on any FAIL.
Run: python3 -I -B linux/gesture/tests/test-appquit.py   (Windows: tools/venv/Scripts/python -X utf8 -I -B ...)
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "taskswitcher", "appquit.py")
loader = importlib.machinery.SourceFileLoader("appquit", SRC)
aq = importlib.util.module_from_spec(importlib.util.spec_from_loader("appquit", loader))
loader.exec_module(aq)
SLICE = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/"
STEAM = os.path.expanduser("~/.local/bin/steam-arm64")
FAILS = []


def check(name, ok, got=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}"))
    if not ok:
        FAILS.append(name)


def proc(*ps):
    """fresh fake /proc: (pid, ppid, cgroup, comm[, environ]); a cgroup without "::" is a unit under app.slice"""
    d = tempfile.mkdtemp(prefix="appquit-")
    for pid, ppid, cg, comm, *env in ps:
        os.mkdir(f"{d}/{pid}")
        for name, text in (("cgroup", (cg if "::" in cg else SLICE + cg) + "\n"), ("comm", comm + "\n"),
                           ("stat", f"{pid} ({comm}) S {ppid} {pid} {pid} 0 -1 4194560 100 0 0 0\n"),
                           ("environ", "\0".join(env + ["HOME=/home/user", "LANG=zh_CN.UTF-8"]) + "\0")):
            with open(f"{d}/{pid}/{name}", "w", newline="\n") as f:
                f.write(text)
    os.mkdir(f"{d}/self")   # non-numeric entries are skipped
    aq.PROC = d
    return d


def case(name, procs, pid, wins, want_cmds, want_in_line):
    d = proc(*procs)
    try:
        line, cmds = aq.plan(pid, wins)
    finally:
        shutil.rmtree(d)
    check(name + " (commands)", cmds == want_cmds, cmds)
    check(name + " (log line)", want_in_line in line, line)


def stop(u, block=True):
    return ["systemctl", "--user", "stop"] + ([] if block else ["--no-block"]) + [u]


KATE = (200, 1, "app-org.kde.kate-200.scope", "kate")
# Claude 10-31: the main process (the window) moved into a scope of its own; zygotes, GPU, renderers and the
# crashpad handler (re-parented to systemd) stay in the scope Plasma started it in
CLAUDE = [(100, 1, "app-claude-100.scope", "claude"), (101, 100, "app-claude\\x2ddesktop-50.scope", "claude"),
          (102, 100, "app-claude\\x2ddesktop-50.scope", "claude"), (103, 101, "app-claude\\x2ddesktop-50.scope", "claude"),
          (104, 1, "app-claude\\x2ddesktop-50.scope", "chrome_crashpad"), KATE]
case("Claude: its own scope, then the one its children are in", CLAUDE, 100, [200],
     [stop("app-claude-100.scope"), stop("app-claude\\x2ddesktop-50.scope", False)],
     "stop app-claude-100.scope then app-claude\\x2ddesktop-50.scope")
case("pid gone", [KATE], 999, [200], [], "gone")
case("an ssh session scope", [(300, 1, "0::/user.slice/user-1000.slice/session-3.scope", "python3"), KATE], 300, [200],
     [], "not in an app unit")
case("a y700 service in app.slice", [(301, 1, "y700-shellbar.service", "y700-shellbar"), KATE], 301, [200], [],
     "not in an app unit")
case("KWin", [(302, 1, "0::/user.slice/user-1000.slice/user@1000.service/session.slice/plasma-kwin_wayland.service",
               "kwin_wayland"), KATE], 302, [200], [], "not in an app unit")
case("same unit still has a window", [(310, 1, "app-org.kde.dolphin-310.scope", "dolphin"),
                                      (311, 310, "app-org.kde.dolphin-310.scope", "dolphin"), KATE], 310, [311, 200],
     [], "still has a window")
case("Telegram is kept", [(320, 1, "app-org.telegram.desktop-320.scope", "Telegram"), KATE], 320, [200], [],
     "kept running")
case("Konsole tab sub-cgroup is kept", [(330, 1, "app-org.kde.konsole-330.scope/tab(2).scope", "vim"), KATE], 330, [200],
     [], "app-org.kde.konsole-330.scope is kept running")
case("autostart is kept", [(340, 1, "app-org.kde.kdeconnect.daemon@autostart.service", "kdeconnectd"), KATE], 340, [200],
     [], "kept running")
case("LIVI is kept", [(345, 1, "app-livi-345.scope", "livi"), KATE], 345, [200], [], "kept running")
STEAM_UNIT = "app-steam-600.scope"
STEAMP = [(600, 1, STEAM_UNIT, "steam", "SteamAppId=0"), (601, 600, STEAM_UNIT, "steamwebhelper"), KATE]
case("Steam quits itself", STEAMP, 600, [200], [[STEAM, "-shutdown"]], "is Steam")
case("Steam's helper window (steamwebhelper) also quits Steam", STEAMP, 601, [200], [[STEAM, "-shutdown"]], "is Steam")
case("Steam with a windowless game is left alone",
     STEAMP + [(602, 600, STEAM_UNIT, "reaper", "SteamAppId=730"), (603, 602, STEAM_UNIT, "cs2", "LANG=C", "SteamGameId=730")],
     600, [200], [], "a game runs")
case("Steam with a game window is left alone", STEAMP + [(604, 600, STEAM_UNIT, "game", "SteamAppId=440")], 600, [604, 200],
     [], "still has a window")
case("a game in a child unit is still seen", STEAMP + [(605, 600, "app-steam_app_440-605.scope", "game", "SteamGameId=440")],
     600, [200], [], "a game runs")
# today games run in Steam's own unit; these hold should Steam ever give them units of their own (review 10-31)
for swiped in (600, 601):
    case(f"a game with a window in a unit of its own, {swiped} swiped",
         STEAMP + [(605, 600, "app-steam_app_440-605.scope", "game", "SteamGameId=440")], swiped, [605, 200], [], "a game runs")
case("steamwebhelper's window swiped, a windowless game in Steam's unit",
     STEAMP + [(602, 600, STEAM_UNIT, "reaper", "SteamAppId=730")], 601, [200], [], "a game runs")
case("a game in a kept unit is still seen",
     STEAMP + [(606, 600, "app-org.telegram.desktop-606.scope", "Telegram", "SteamAppId=730")], 600, [200], [], "a game runs")
case("a child of a windowless process of the app is stopped too",
     [(760, 1, "app-a-760.scope", "a"), (761, 1, "app-a-760.scope", "a-helper"), (762, 761, "app-b-762.scope", "b"), KATE],
     760, [200], [stop("app-a-760.scope"), stop("app-b-762.scope", False)], "stop app-a-760.scope then app-b-762.scope")
case("XSteamAppId= is not a game", [(610, 1, "app-x-610.scope", "x", "XSteamAppId=5"), KATE], 610, [200],
     [stop("app-x-610.scope")], "stop app-x-610.scope")
case("a child whose unit has a window is not stopped",
     [(700, 1, "app-a-700.scope", "a"), (701, 700, "app-b-701.scope", "b"), (702, 701, "app-c-702.scope", "c"), KATE],
     700, [701, 200], [stop("app-a-700.scope"), stop("app-c-702.scope", False)], "stop app-a-700.scope then app-c-702.scope")
case("a kept child is not stopped",
     [(710, 1, "app-a-710.scope", "a"), (711, 710, "app-org.telegram.desktop-711.scope", "Telegram"), KATE],
     710, [200], [stop("app-a-710.scope")], "stop app-a-710.scope")
case("a child not in an app unit is ignored",
     [(720, 1, "app-a-720.scope", "a"), (721, 720, "y700-osk.service", "y700-osk"), KATE],
     720, [200], [stop("app-a-720.scope")], "stop app-a-720.scope")
case("spaces and parens in comm", [(730, 1, "app-a-730.scope", "Web (Content) x"),
                                   (731, 730, "app-b-731.scope", "Web (Content) x"), KATE],
     730, [200], [stop("app-a-730.scope"), stop("app-b-731.scope", False)], "then app-b-731.scope")
case("a process that is not a descendant stays", [(740, 1, "app-a-740.scope", "a"), (741, 1, "app-b-741.scope", "b"), KATE],
     740, [200], [stop("app-a-740.scope")], "stop app-a-740.scope")
case("a .service app unit", [(750, 1, "app-org.gnome.Weather-750.service", "weather"), KATE], 750, [200],
     [stop("app-org.gnome.Weather-750.service")], "stop app-org.gnome.Weather-750.service")


def run_main(arg):
    out, err = io.StringIO(), io.StringIO()
    old, sys.argv = sys.argv, ["y700-appquit"] + arg
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = aq.main()
    finally:
        sys.argv = old
    return rc, out.getvalue(), err.getvalue()


for bad in ([], ["abc"], ["1_"], ["_1"], ["1-2"], ["1", "2"], ["1;reboot"]):
    rc, out, err = run_main(bad)
    check(f"main rejects {bad!r}", rc == 2 and "usage" in err and not out, (rc, out, err))
d = proc(KATE)
try:
    rc, out, err = run_main(["999_200"])
finally:
    shutil.rmtree(d)
check("main with a gone pid: rc 0, one log line, nothing run", rc == 0 and out == "y700-appquit: 999: gone or not in an app unit, nothing to do\n",
      (rc, out, err))


# main runs what plan() returns: systemctl's 5 ("Unit ... not loaded": it quit on its own in between) is no failure
real_plan, real_sp = aq.plan, aq.subprocess
for cmds, rcs, want in (([stop("app-a.scope"), stop("app-b.scope", False)], [5, 5], 0),
                        ([stop("app-a.scope")], [1], 1), ([[STEAM, "-shutdown"]], [5], 5)):
    ran, it = [], iter(rcs)
    aq.plan = lambda pid, wins, cmds=cmds: ("test", cmds)
    aq.subprocess = types.SimpleNamespace(TimeoutExpired=real_sp.TimeoutExpired,
                                          run=lambda c, timeout: ran.append(c) or types.SimpleNamespace(returncode=next(it)))
    rc, out, err = run_main(["5_6"])
    check(f"main runs {len(cmds)} command(s), exits {rcs} -> rc {want}", rc == want and ran == cmds, (rc, ran))
aq.plan, aq.subprocess = real_plan, real_sp

print("ALL PASS" if not FAILS else f"{len(FAILS)} FAIL")
sys.exit(1 if FAILS else 0)
