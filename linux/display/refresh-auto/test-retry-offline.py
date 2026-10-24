#!/usr/bin/env python3
"""test-retry-offline.py [DAEMON]: offline test of y700-refresh-auto's switching retries (10-19 audit).

Runs anywhere with Python 3 (the PC: py -3 -I test-retry-offline.py; the tablet: python3 ...): fake gi.repository
(GLib main loop on a virtual clock, Gio.Subprocess that "runs" kscreen-doctor), the daemon object built without D-Bus,
KWin's mode and the screen state in memory. Nothing real is touched.
  fail-on   video lowered to 30 Hz, a touch sends it back to the base, every kscreen-doctor fails: the old daemon
            started one every ~0.35 s (on_mode_done's 300 ms re-look, no backoff for going back to the base)
  fail-off  the same with the screen off (the 1 Hz screen-off guard also calls drop_to_base)
  recover   screen off at 30 Hz, kscreen-doctor fails for 5 s, then works: back at the base within the backoff
  normal    a 30 fps video lowers after enter_delay_s, a touch goes back at once (the fix must not slow this down)
"""
import heapq, importlib.machinery, importlib.util, itertools, json, os, re, sys, tempfile, types

T = [1000.0]
Q = []; LIVE = {}; SEQ = itertools.count(); IDS = itertools.count(1); STARTED = []
KD = {"ok": True, "s": 0.2}                       # what the next kscreen-doctor does: success, run time
W = types.SimpleNamespace(hz=120, screen=True, daemon=None)


def _add(delay, fn, args, repeat=None):
    sid = next(IDS); LIVE[sid] = repeat
    heapq.heappush(Q, (T[0] + delay, next(SEQ), sid, fn, args)); return sid


class GLib:
    PRIORITY_DEFAULT = 0
    class IOCondition: IN = 1
    timeout_add = staticmethod(lambda ms, fn, *a: _add(ms / 1000, fn, a, ms / 1000))
    timeout_add_seconds = staticmethod(lambda s, fn, *a: _add(s, fn, a, float(s)))
    idle_add = staticmethod(lambda fn, *a: _add(0, fn, a))
    source_remove = staticmethod(lambda sid: LIVE.pop(sid, None))
    unix_fd_add_full = staticmethod(lambda *a: 0)
    unix_signal_add = staticmethod(lambda *a: 0)


class Proc:
    def __init__(self, argv): self.argv = argv; self.ok = None
    def wait_async(self, _c, cb, data):
        r = dict(KD)
        def done():
            self.ok = r["ok"]
            if r["ok"]:
                W.hz = int(re.search(r"@(\d+)", self.argv[-1]).group(1)); W.daemon.on_kwinconf(None, None, None, None)
            cb(self, None, data); return False
        _add(r["s"], done, ())
    wait_finish = lambda self, res: True
    get_successful = lambda self: bool(self.ok)
    force_exit = lambda self: None


class Gio:
    class SubprocessFlags: STDOUT_SILENCE = 1; STDERR_SILENCE = 2
    class Subprocess:
        @staticmethod
        def new(argv, flags):
            STARTED.append((T[0], argv[-1])); return Proc(argv)
    class FileMonitorEvent: RENAMED, MOVED_IN, CREATED, CHANGES_DONE_HINT, DELETED, MOVED_OUT = range(6)


gi = types.ModuleType("gi"); gi.require_version = lambda *a: None
rep = types.ModuleType("gi.repository"); rep.GLib = GLib; rep.Gio = Gio; gi.repository = rep
sys.modules.update({"gi": gi, "gi.repository": rep})
os.environ.setdefault("XDG_RUNTIME_DIR", tempfile.gettempdir())
os.getuid = getattr(os, "getuid", lambda: 1000)       # Windows
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "y700-refresh-auto")
loader = importlib.machinery.SourceFileLoader("ra", src)
ra = importlib.util.module_from_spec(importlib.util.spec_from_loader("ra", loader)); loader.exec_module(ra)
ra.time = types.SimpleNamespace(monotonic=lambda: T[0])
ra.kwin_hz = ra.current_hz = lambda: W.hz
ra.screen_on = lambda: W.screen
ra.DPMS = ["/fake/dpms"]
ra.save_cfg = lambda cfg: None
ra.log = lambda m: None


def run(secs):
    end = T[0] + secs
    while Q and Q[0][0] <= end:
        when, _, sid, fn, args = heapq.heappop(Q)
        if sid not in LIVE:
            continue
        T[0] = when; repeat = LIVE[sid]
        if fn(*args) and repeat is not None and sid in LIVE:
            heapq.heappush(Q, (T[0] + repeat, next(SEQ), sid, fn, args))
        else:
            LIVE.pop(sid, None)
    T[0] = end


def daemon():
    """the daemon's state as __init__ leaves it, minus D-Bus / files / evdev"""
    Q.clear(); LIVE.clear(); STARTED.clear(); T[0] = 1000.0
    KD.update(ok=True, s=0.2); W.hz = 120; W.screen = True
    a = ra.RefreshAuto.__new__(ra.RefreshAuto)
    a.cfg = json.loads(json.dumps(ra.DEFAULTS))
    a.modes = {h: ra.mode_name(h) for h in (30, 60, 90, 120, 164)} if hasattr(ra, "mode_name") else \
        {h: f"1904x3040@{h}" for h in (30, 60, 90, 120, 164)}
    a.output = "DSI-1"; a.warned = set(); a.cur_hz = 120
    a.expected = None; a.requested = {}; a.players = {}; a.pidfds = {}
    a.active = ("", False, 0); a.last_touch = 0.0; a.locked = False; a.manual = False
    a.backoff_until = 0.0; a.fails = 0; a.retry_at = 0.0; a.retry_src = None
    a.enter_src = a.hold_src = a.dpms_src = a.kwin_src = a.kill_src = None
    a.mode_proc = None; a.pending = False; a.touch_fds = {}; a.touch_paths = []
    a.shield_until = 0.0; a.shielded = 0; a.sleep_fd = None
    a.attach_touch = lambda on: None
    W.daemon = a
    return a


def video(a, fps=30.0, pid=4242):
    a.players[f"mpv-{pid}"] = {"pid": pid, "playing": True, "fullscreen": True, "osd": False, "danmaku": False, "fps": fps}
    a.active = ("mpv", True, pid)
    a.evaluate("player state")


fails = []
def check(name, cond, info):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f": {info}"))
    if not cond:
        fails.append(name)


# fail-on / fail-off: 60 s of failing switches; with 1, 2, 4, 8, 16, 30 s waits that is at most ~8 starts
for name, screen in (("fail-on", True), ("fail-off", False)):
    a = daemon(); video(a); run(3)
    lowered = W.hz
    KD.update(ok=False, s=0.05); n0 = len(STARTED)
    W.screen = screen; a.last_touch = T[0]; a.drop_to_base("touch"); run(60)
    n = len(STARTED) - n0
    check(f"{name}: {n} kscreen-doctor in 60 s of failing switches (<= 10)", lowered == 30 and n <= 10,
          f"lowered to {lowered}, {n} started")

# recover: the screen goes off at 30 Hz (must go back to the base), switching fails 5 s, then works: tries at 0, 1, 3, 7 s
a = daemon(); video(a); run(3)
KD.update(ok=False, s=0.05); W.screen = False; run(5)
KD.update(ok=True, s=0.2); run(5)
check("recover: back at the base within 5 s once kscreen-doctor works again", W.hz == 120 and a.fails == 0,
      f"hz={W.hz} fails={a.fails}")

# normal: lowering after 1.5 s, back at once on a touch
a = daemon(); video(a); run(1.0); h1 = W.hz; run(1.0); h2 = W.hz
a.last_touch = T[0]; a.drop_to_base("touch"); run(0.5); h3 = W.hz
check("normal: 120 at 1.0 s, 30 at 2.0 s, 120 0.5 s after a touch", (h1, h2, h3) == (120, 30, 120), (h1, h2, h3))

print("ALL PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
