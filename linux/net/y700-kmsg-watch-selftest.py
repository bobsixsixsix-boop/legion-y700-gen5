#!/usr/bin/env python3
"""y700-kmsg-watch-selftest: offline test of linux/net/y700-kmsg-watch on the PC (Windows or Linux; no tablet, no
/dev/kmsg, nothing installed). The watcher is loaded as a module. Its I/O-free core (parse, Watcher, drain, loop)
is driven by a simulator that plays /dev/kmsg records on a fake clock and answers for systemctl; its real
daemon() / systemctl_start() / client_selftest() run against fake os / select / time objects that record every
call -- above all the poll() timeouts, which is where "zero wakeups while the kernel log is quiet" lives.
Real kernel text: linux/kernel-y8/inventory/dmesg (a healthy 70-minute boot of this tablet: 3070 records, 10
isolated vblank timeouts; kept local, T2/T3 print SKIP without it) and linux/power/cx-collapse/crash-0341-lastkmsg.log (36 vblank timeouts before the
03:41 hang). The scripts' look-back windows and thresholds are read from linux/net/y700-*-watchdog themselves.
    python -X utf8 -I linux/net/y700-kmsg-watch-selftest.py        (from the y700 repo; exit 0 = all passed)
2026-10-16."""
import collections, contextlib, importlib.machinery, importlib.util, io, itertools, os as realos, re, shutil, sys, tempfile

HERE = realos.path.dirname(realos.path.abspath(__file__))
REPO = realos.path.normpath(realos.path.join(HERE, "..", ".."))
WATCHER = realos.path.join(HERE, "y700-kmsg-watch")
SERVICE = WATCHER + ".service"
DMESG = realos.path.join(REPO, "linux", "kernel-y8", "inventory", "dmesg")
CRASH = realos.path.join(REPO, "linux", "power", "cx-collapse", "crash-0341-lastkmsg.log")

sys.dont_write_bytecode = True                      # no __pycache__ next to the watcher
loader = importlib.machinery.SourceFileLoader("y700_kmsg_watch", WATCHER)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("y700_kmsg_watch", loader))
loader.exec_module(mod)
WIFI_UNIT, DPU_UNIT = "y700-wifi-watchdog.service", "y700-display-watchdog.service"
WIFI_LINE = "ath12k_wifi7_pci 0000:01:00.0: failed to flush transmit queue, data pkts pending 7"
TMP = tempfile.mkdtemp(prefix="y700-kmsg-watch-selftest-")
RESULT = realos.path.join(TMP, "run", "selftest")

FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"   <- {detail}"))
    if not cond:
        FAILS.append(name)


# ---- the scripts' own look-back window and threshold, so "would the script act at this start?" tracks them
def script_rule(path, needle):
    text = open(path, encoding="utf-8").read()
    m = re.search(r'journalctl -k --since "-(\d+)min"[^\n]*grep -c "' + re.escape(needle) + '"', text)
    t = re.search(r'\[ "\$n" -ge (\d+) \]', text)
    return (int(m.group(1)) * 60 if m else None), (int(t.group(1)) if t else None)


RULES = {unit: script_rule(realos.path.join(HERE, unit[:-len(".service")]), needle) for needle, unit in mod.WATCHES}


# ---- /dev/kmsg records as the kernel formats them (printk.c info_print_ext_header + msg_print_ext_body)
def esc(text):
    return "".join("\\x%02x" % b if b < 0x20 or b >= 0x7f or b == 0x5c else chr(b) for b in text.encode())


SEQ = itertools.count(100000)


def rec(text, t=0.0, fac=0, level=3, dev=None, flag="-", caller=None, seq=None):
    s = next(SEQ) if seq is None else seq
    head = f"{fac << 3 | level},{s},{int(t * 1e6)},{flag}" + (f",caller={caller}" if caller else "")
    body = esc(text) + "\n" + (f" SUBSYSTEM={dev[0]}\n DEVICE={dev[1]}\n" if dev else "")
    return (head + ";" + body).encode()


def dmesg_lines(path):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\[\s*(\d+\.\d+)\] (.*)", line.rstrip("\n"))
        if m:
            out.append((float(m.group(1)), m.group(2)))
    return out


EPIPE = object()


class Done(Exception):
    pass


class Sim:
    """/dev/kmsg + the monotonic clock + systemctl. events: [(t, record | EPIPE)] in ring-buffer (seq) order; a
    time earlier than the one before is clamped (printk timestamps from different CPUs are not strictly ordered,
    the seq is). wait() jumps the clock to the next arrival or to the timeout, whichever comes first; with no
    timeout and nothing left to arrive the real process would sleep forever -> Done (and that last wait having
    timeout None is itself checked)."""

    def __init__(self, events, t0=0.0, rc=None, read_cost=0.0):
        self.t = t0
        self.events, prev = collections.deque(), t0
        for t, r in events:
            prev = max(prev, t)
            self.events.append((prev, r))
        self.ready = collections.deque()
        self.waits, self.starts, self.logs = [], [], []
        self.rc, self.read_cost = rc or {}, read_cost

    def clock(self):
        return self.t

    def start(self, unit):
        self.starts.append((self.t, unit))
        return self.rc.get(unit, 0)

    def log(self, msg):
        self.logs.append((self.t, msg))

    def _arrive(self):
        while self.events and self.events[0][0] <= self.t:
            self.ready.append(self.events.popleft()[1])

    def wait(self, timeout):
        if len(self.waits) > 200000:
            raise RuntimeError("runaway loop")
        self.waits.append((self.t, timeout))
        self._arrive()
        if self.ready:
            return True
        nxt = self.events[0][0] if self.events else None
        if nxt is None and timeout is None:
            raise Done
        if nxt is not None and (timeout is None or nxt <= self.t + timeout):
            self.t = nxt
            self._arrive()
            return True
        self.t += timeout
        return False

    def read(self):
        if self.read_cost:
            self.t += self.read_cost
            self._arrive()
        if not self.ready:
            raise BlockingIOError
        r = self.ready.popleft()
        if r is EPIPE:
            raise BrokenPipeError
        return r


def play(events, t0=0.0, begin=True, **kw):
    sim = Sim(events, t0, **kw)
    w = mod.Watcher(sim.start, sim.log, result=RESULT)
    if begin:
        w.begin(sim.clock())
    try:
        mod.loop(w, sim.wait, sim.read, sim.clock)
    except Done:
        pass
    return sim, w


def starts_of(sim, unit, after=None):
    return [t for t, u in sim.starts if u == unit and (after is None or t > after)]


def would_act(unit, start_t, match_times):
    """The script started at start_t counts the matching lines of the last `window` s and acts at >= threshold."""
    window, threshold = RULES[unit]
    return sum(1 for t in match_times if start_t - window <= t <= start_t) >= threshold


def gaps(ts):
    return [b - a for a, b in zip(ts, ts[1:])]


def idle_timeouts(sim, w_due_windows):
    """waits with a timeout outside the windows where a start was armed (should be none)."""
    return [(t, to) for t, to in sim.waits if to is not None and not any(a <= t <= b for a, b in w_due_windows)]


print(f"script rules (window s, threshold) read from the scripts: {RULES}")
check("rules parsed from both scripts", all(None not in r for r in RULES.values()), RULES)

# ---- T1 parse: the record format
r = rec(WIFI_LINE, 12.5, level=4, dev=("pci", "+pci:0000:01:00.0"))
check("T1 kernel record with device dictionary", mod.parse(r)[0] == 0 and mod.parse(r)[2] == WIFI_LINE, mod.parse(r))
check("T1 caller field and continuation flag", mod.parse(rec("hello", caller="T123", flag="c"))[2] == "hello")
check("T1 userspace record is facility 1", mod.parse(rec("x", fac=1, level=4))[0] == 1)
p = mod.parse(rec("a\\b\nc é vblank timeout: 1"))
check("T1 escaped text stays on one line and still matches", p[2] == "a\\x5cb\\x0ac \\xc3\\xa9 vblank timeout: 1", p)
check("T1 malformed records -> None", mod.parse(b"garbage") is None and mod.parse(b"x,y;z") is None
      and mod.parse(b"6;no seq") is None)

# T2/T3 need the author's boot log, which may carry MAC/BT addresses and serial numbers and so stays local
# (linux/kernel-y8/inventory/.gitignore): without it they print SKIP, which is not a failure
if not realos.path.exists(DMESG):
    print("SKIP T2/T3: no linux/kernel-y8/inventory/dmesg (the author's boot log, kept local)")
else:
    # ---- T2 a healthy boot's real kernel log, matching lines removed: no start besides start-up, never a timer
    boot = dmesg_lines(DMESG)
    quiet = [(t, rec(x, t, level=6)) for t, x in boot if not any(n in x for n, _ in mod.WATCHES)]
    sim, w = play(quiet)
    span = boot[-1][0] - boot[0][0]
    wakeups = len(sim.waits) - 1                     # the last wait is the endless sleep
    print(f"T2 {len(quiet)} records over {span:.0f} s -> {wakeups} poll wakeups, starts {sim.starts}")
    check("T2 only the two start-up starts", [u for _, u in sim.starts] == list(mod.UNITS), sim.starts)
    check("T2 every poll had no timeout (poll(-1))", all(to is None for _, to in sim.waits), [x for x in sim.waits if x[1] is not None][:3])
    check("T2 one wakeup per arrival instant at most", wakeups <= len({t for t, _ in quiet}), wakeups)
    check("T2 all records counted", w.records == len(quiet) and w.lost == 0, (w.records, w.lost))

    # ---- T3 the same boot with its 10 real vblank timeouts (pairs ~60 ms apart): one start per cluster, none acts
    full = [(t, rec(x, t, level=3)) for t, x in boot]
    sim, w = play(full)
    dpu_t = [t for t, x in boot if "vblank timeout" in x]
    d = starts_of(sim, DPU_UNIT, after=0)
    print(f"T3 vblank lines at {dpu_t}\n   display starts at {d}")
    check("T3 10 matches seen", w.matches[DPU_UNIT] == 10, w.matches)
    check("T3 one start per cluster (4), SETTLE s after its first line",
          len(d) == 4 and abs(d[0] - (dpu_t[0] + mod.SETTLE)) < 1e-6, d)
    check("T3 no start would act (threshold not reached)", not any(would_act(DPU_UNIT, s, dpu_t) for s in d))
    check("T3 wifi only started at start-up", starts_of(sim, WIFI_UNIT, after=0) == [], sim.starts)
    armed = [(a, a + mod.SETTLE + 0.01) for a in dpu_t]
    check("T3 timeouts only within SETTLE s after a vblank line", idle_timeouts(sim, armed) == [], idle_timeouts(sim, armed)[:3])
    check("T3 last poll back to no timeout", sim.waits[-1][1] is None)
    timer_runs = 2 * span / 65
    print(f"T3 over {span:.0f} s: event trigger {len(sim.starts)} starts (2 at start-up) vs the two timers ~{timer_runs:.0f}")

# ---- T4 the 03:41 hang's last kernel lines as one 10-second burst: the second start sees all 36
crash = [x.rstrip("\n") for x in open(CRASH, encoding="utf-8", errors="replace")]
burst = [(1000 + 10.0 * i / len(crash), rec(x, 1000 + 10.0 * i / len(crash))) for i, x in enumerate(crash)]
sim, w = play(burst)
d = starts_of(sim, DPU_UNIT, after=0)
mt = [t for (t, _), x in zip(burst, crash) if "vblank timeout" in x]
print(f"T4 {len(mt)} vblank lines in 10 s -> display starts at {d}")
check("T4 first start SETTLE s after the first vblank line, at most 2 starts",
      d and abs(d[0] - mt[0] - mod.SETTLE) < 1e-6 and len(d) <= 2, d)
check("T4 the start after the last vblank line would recover (>= threshold in its window)",
      would_act(DPU_UNIT, min(x for x in d if x >= mt[-1]), mt))

# ---- T5 the 2026-10-13 Wi-Fi failure: a flush failure at the end of every ~20 s association
fl = [2000 + 21 * i for i in range(6)]
sim, w = play([(t, rec(WIFI_LINE, t, level=4, dev=("pci", "+pci:0000:01:00.0"))) for t in fl])
s = starts_of(sim, WIFI_UNIT, after=0)
first_act = next((x for x in s if would_act(WIFI_UNIT, x, fl)), None)
print(f"T5 flush failures at {fl}\n   wifi starts at {s}; first that reloads: {first_act}")
check("T5 a start for every failure, >= DEBOUNCE apart", len(s) == len(fl) and min(gaps(s)) >= mod.DEBOUNCE - 1e-6, s)
check("T5 reload decided <= 30 s after the first failure", first_act is not None and first_act - fl[0] <= 30, first_act)
check("T5 display untouched", starts_of(sim, DPU_UNIT, after=0) == [])

# ---- T6 the 2026-10-13 DPU storm: 2 timeouts/s (+ the companion line) for 120 s
st = [3000 + 0.5 * i for i in range(240)]
ev = []
for t in st:
    ev.append((t, rec("[drm:dpu_encoder_phys_vid_wait_for_commit_done:583] [dpu error]vblank timeout: 80000000", t)))
    ev.append((t + 0.0001, rec("[drm:dpu_kms_wait_for_commit_done:528] [dpu error]wait for commit done returned -110", t)))
sim, w = play(ev)
d = starts_of(sim, DPU_UNIT, after=0)
first_act = next((x for x in d if would_act(DPU_UNIT, x, st)), None)
print(f"T6 storm 3000..3120 s -> display starts at {d}; first that recovers: {first_act}")
check("T6 at most one start per DEBOUNCE s", min(gaps(d)) >= mod.DEBOUNCE - 1e-6, gaps(d))
check("T6 7 starts in 125 s (not 240)", len(d) == 7, len(d))
check("T6 recovery decided <= 30 s into the storm", first_act is not None and first_act - st[0] <= 30, first_act)
check("T6 back to poll(-1) after the storm", sim.waits[-1][1] is None and not w.due)

# ---- T7 userspace lines (facility forced >= 1 by devkmsg_write) never trigger, even with the exact text
ev = [(10, rec("tb323fu: vblank timeout", 10, fac=1, level=1)),
      (11, rec(WIFI_LINE, 11, fac=1, level=4)), (12, rec(WIFI_LINE, 12, fac=3, level=4))]
sim, w = play(ev)
check("T7 no start from userspace records", starts_of(sim, WIFI_UNIT, after=0) + starts_of(sim, DPU_UNIT, after=0) == [], sim.starts)
check("T7 nothing armed", all(to is None for _, to in sim.waits))

# ---- T8 overrun: -EPIPE, then the next record 1000 seq numbers later
ev = [(50, rec("before", 50, seq=5000)), (60, EPIPE), (60, rec("after", 60, seq=6001))]
sim, w = play(ev)
check("T8 overrun counted, gap counted as lost", w.overruns == 1 and w.lost == 1000, (w.overruns, w.lost))
check("T8 both watchdogs started SETTLE s later",
      starts_of(sim, WIFI_UNIT, after=0) == [60 + mod.SETTLE] and starts_of(sim, DPU_UNIT, after=0) == [60 + mod.SETTLE], sim.starts)

# ---- T9 selftest through /dev/kmsg: both started at once, result file written; FAIL when systemctl fails
ev = [(70, rec(mod.TAG + "123-456", 70, fac=1, level=4)), (80, rec(mod.TAG + "bad token!", 80, fac=1, level=4))]
sim, w = play(ev)
res = open(RESULT, encoding="utf-8").read()
print(f"T9 result: {res.strip()}")
check("T9 both started at the selftest instant", [u for t, u in sim.starts if t == 70] == list(mod.UNITS), sim.starts)
check("T9 result line", res.startswith("selftest 123-456 ok wifi=0 display=0; up 70 s, records 1"), res)
check("T9 malformed token ignored", not any(t == 80 for t, _ in sim.starts) and any("malformed" in m for _, m in sim.logs))
sim, w = play([(70, rec(mod.TAG + "9-9", 70, fac=1, level=4))], rc={DPU_UNIT: 1})
check("T9 FAIL reported", open(RESULT, encoding="utf-8").read().startswith("selftest 9-9 FAIL wifi=0 display=1"))
check("T9 a kernel line with the tag is not a selftest", play([(70, rec(mod.TAG + "1-1", 70))])[0].starts == [(0.0, u) for u in mod.UNITS])

# ---- T10 systemctl failing on a real match: logged, counted, the loop goes on and retries on the next match
ev = [(100, rec(WIFI_LINE, 100, level=4)), (150, rec(WIFI_LINE, 150, level=4))]
sim, w = play(ev, rc={WIFI_UNIT: 1})
check("T10 failure logged", any("FAILED (exit 1)" in m for _, m in sim.logs), sim.logs[-3:])
check("T10 retried on the next match", starts_of(sim, WIFI_UNIT, after=0) == [105, 155] and w.failed[WIFI_UNIT] == 3, (sim.starts, w.failed))

# ---- T11 an endless storm (the reader never sees EAGAIN): the armed start still fires on time
ev = [(500 + 0.001 * i, rec("[dpu error]vblank timeout: 1", 500)) for i in range(20000)]
sim, w = play(ev, read_cost=0.01)
d = starts_of(sim, DPU_UNIT, after=0)
bound = 500 + mod.SETTLE + mod.DRAIN_MAX * 0.01 + 0.02
print(f"T11 20000 records, 10 ms per read -> display starts at {[round(x, 2) for x in d]}")
check("T11 first start no later than SETTLE + one drain round", d and d[0] <= bound, (d[:1], bound))
check("T11 still >= DEBOUNCE apart", min(gaps(d)) >= mod.DEBOUNCE - 1e-6, gaps(d))


# ---- T12 the real daemon(): open/lseek/poll/read/posix_spawn as it calls them (fake os / select / time)
class Stop(Exception):
    pass


class FakeOS:
    O_RDONLY, O_WRONLY, O_NONBLOCK, O_CLOEXEC, SEEK_END = 0, 1, 0o4000, 0o2000000, 2

    def __init__(self, records):
        self.calls, self.records, self.environ = [], collections.deque(records), {"SYSTEMD_OFFLINE": "0"}

    def open(self, path, flags):
        self.calls.append(("open", path, flags))
        return 3

    def lseek(self, fd, off, whence):
        self.calls.append(("lseek", fd, off, whence))
        return 0

    def read(self, fd, n):
        self.calls.append(("read", fd, n))
        if not self.records:
            raise BlockingIOError
        return self.records.popleft()

    def posix_spawn(self, path, argv, env, setsigdef=()):
        self.calls.append(("spawn", path, tuple(argv), setsigdef))
        return 4242

    def waitpid(self, pid, opt):
        return pid, 0

    def waitstatus_to_exitcode(self, st):
        return 0

    def __getattr__(self, name):
        return getattr(realos, name)


class FakeSelect:
    POLLIN, POLLNVAL, POLLHUP = 1, 32, 16

    def __init__(self, fos, clock, script):
        self.fos, self.clock, self.script, self.ms = fos, clock, collections.deque(script), []

    def poll(self):
        sel = self

        class P:
            def register(self, fd, mask):
                sel.fos.calls.append(("register", fd, mask))

            def poll(self, ms):
                sel.ms.append(ms)
                if not sel.script:
                    raise Stop
                action = sel.script.popleft()
                if action == "record":
                    return [(3, sel.POLLIN)]
                sel.clock[0] += ms / 1000          # "timeout": the deadline passed
                return []
        return P()


class FakeTime:
    def __init__(self, clock):
        self.clock = clock

    def monotonic(self):
        return self.clock[0]

    def time_ns(self):
        return 1


clock = [100.0]
fos = FakeOS([rec("[dpu error]vblank timeout: 1", 100)])
fsel = FakeSelect(fos, clock, ["record", "timeout"])
saved = (mod.os, mod.select, mod.time, mod.log)
logbuf = []
mod.os, mod.select, mod.time, mod.log = fos, fsel, FakeTime(clock), logbuf.append
try:
    mod.daemon()
except Stop:
    pass
finally:
    mod.os, mod.select, mod.time, mod.log = saved
kinds = [c[0] for c in fos.calls]
spawns = [c for c in fos.calls if c[0] == "spawn"]
print(f"T12 calls: {kinds}\n    poll timeouts (ms): {fsel.ms}")
check("T12 opened read-only, non-blocking, close-on-exec",
      fos.calls[0] == ("open", "/dev/kmsg", FakeOS.O_RDONLY | FakeOS.O_NONBLOCK | FakeOS.O_CLOEXEC), fos.calls[0])
check("T12 lseek(fd, 0, SEEK_END) before anything is read", fos.calls[1] == ("lseek", 3, 0, FakeOS.SEEK_END))
check("T12 reads with an 8192-byte buffer", all(c[2] == 8192 for c in fos.calls if c[0] == "read"))
# the match comes right after the start-up starts, so the armed start waits for DEBOUNCE, not SETTLE
check("T12 poll timeouts: -1 (idle), 20001 (armed), -1 (idle again)", fsel.ms == [-1, int(mod.DEBOUNCE * 1000) + 1, -1], fsel.ms)
argv = lambda u: ("/usr/bin/systemctl", "start", "--no-block", "--no-ask-password", "--quiet", u)
check("T12 systemctl argv: two start-up starts, then the display watchdog",
      [c[2] for c in spawns] == [argv(WIFI_UNIT), argv(DPU_UNIT), argv(DPU_UNIT)], [c[2] for c in spawns])
check("T12 setsigdef is a tuple of signals", all(isinstance(c[3], tuple) for c in spawns))
check("T12 start-up log line names both watchdogs", any("y700-wifi-watchdog" in m and "y700-display-watchdog" in m for m in logbuf))

# T12b daemon() writes the --selftest answer to the module's RESULT as it is at run time (Watcher's result= default
# is bound at import, so a test or a wrapper that points RESULT elsewhere was silently ignored before)
clock = [100.0]
fos = FakeOS([rec(mod.TAG + "7-7", 100, fac=1, level=7)])
fsel = FakeSelect(fos, clock, ["record"])
other = realos.path.join(TMP, "elsewhere", "selftest")
saved = (mod.os, mod.select, mod.time, mod.log, mod.RESULT)
mod.os, mod.select, mod.time, mod.log, mod.RESULT = fos, fsel, FakeTime(clock), logbuf.append, other
try:
    mod.daemon()
except Stop:
    pass
finally:
    mod.os, mod.select, mod.time, mod.log, mod.RESULT = saved
check("T12b daemon() answers into RESULT as set at run time",
      realos.path.exists(other) and open(other, encoding="utf-8").read().startswith("selftest 7-7 ok"))


# ---- T13 the --selftest client: answered / FAIL / no answer
class ClientOS(FakeOS):
    def __init__(self):
        super().__init__([])

    def open(self, path, flags):
        return realos.open(path, realos.O_WRONLY | realos.O_APPEND | getattr(realos, "O_BINARY", 0))


kfile = realos.path.join(TMP, "kmsg")
cres = realos.path.join(TMP, "run", "client")


def run_client(rc=None, answer=True):
    open(kfile, "wb").close()
    if realos.path.exists(cres):
        realos.remove(cres)
    starts = []
    w = mod.Watcher(lambda u: (starts.append(u), (rc or {}).get(u, 0))[1], lambda m: None, result=cres)
    t = [0.0]

    def sleep(s):
        t[0] += s
        data = open(kfile, "rb").read()
        if answer and data and not realos.path.exists(cres):        # the kernel (devkmsg_write) + the daemon, once
            m = re.match(r"<(\d+)>(.*)", data.decode().rstrip("\n"))
            pri = int(m.group(1))
            w.record(rec(m.group(2), fac=(pri >> 3) or 1, level=pri & 7), t[0])
    saved_os = mod.os
    mod.os = ClientOS()
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            code = mod.client_selftest(kmsg=kfile, result=cres, timeout=3, sleep=sleep, clock=lambda: t[0])
    finally:
        mod.os = saved_os
    return code, out.getvalue().strip(), open(kfile, "rb").read(), starts


code, out, written, starts = run_client()
print(f"T13 client wrote {written!r}\n    printed {out!r}")
check("T13 one record written: user.debug, tagged", written.startswith(b"<15>" + mod.TAG.encode()) and written.count(b"\n") == 1, written)
check("T13 answered -> exit 0", code == 0 and " ok " in out and starts == list(mod.UNITS), (code, out))
code, out, _, _ = run_client(rc={WIFI_UNIT: 5})
check("T13 systemctl failing -> exit 1", code == 1 and "FAIL wifi=5" in out, (code, out))
code, out, _, _ = run_client(answer=False)
check("T13 no answer -> exit 1 after the timeout", code == 1 and "NOANSWER" in out, (code, out))

# ---- T14 files: what the deployer gets
watcher_src = open(WATCHER, "rb").read()
service_src = open(SERVICE, "rb").read()
check("T14 LF line endings", b"\r" not in watcher_src and b"\r" not in service_src)
check("T14 shebang", watcher_src.startswith(b"#!/usr/bin/python3 -IS\n"))
for needle, unit in mod.WATCHES:
    script = realos.path.join(HERE, unit[:-len(".service")])
    check(f"T14 {unit[:-8]} script greps exactly {needle!r}", f'grep -c "{needle}"' in open(script, encoding="utf-8").read())
    check(f"T14 {unit} and its timer still in the repo",
          realos.path.exists(script + ".service") and realos.path.exists(script + ".timer"))
settings = {}
for line in service_src.decode().splitlines():
    if line and not line.startswith(("#", "[")):
        k, _, v = line.partition("=")
        settings.setdefault(k, []).append(v)
need = {"ExecStart": "/usr/local/libexec/y700-kmsg-watch", "Restart": "always", "Type": "simple",
        "DeviceAllow": "/dev/kmsg r", "DevicePolicy": "closed", "CapabilityBoundingSet": "CAP_SYSLOG",
        "CPUSchedulingPolicy": "idle", "RuntimeDirectory": realos.path.basename(realos.path.dirname(mod.RESULT)),
        "StartLimitIntervalSec": "0", "WantedBy": "multi-user.target"}
for k, v in need.items():
    check(f"T14 unit {k}={v}", settings.get(k) == [v], settings.get(k))
bad = [k for k in ("ProtectKernelLogs", "PrivateDevices", "WatchdogSec", "User", "DynamicUser", "MemoryDenyWriteExecute") if k in settings]
check("T14 none of the settings that break it", not bad, bad)
check("T14 RESULT lives in the RuntimeDirectory", mod.RESULT == "/run/" + need["RuntimeDirectory"] + "/selftest")
safety = open(realos.path.join(HERE, "y700-watchdog-safety.conf"), "rb").read().decode()
body = [l for l in safety.splitlines() if l and not l.startswith("#")]
check("T14 optional safety drop-in: one reset, then 15 min each", "\r" not in safety and body == [
    "[Timer]", "OnBootSec=", "OnBootSec=15min", "OnUnitActiveSec=15min", "AccuracySec=1min"], body)


def timer_list(*files):
    """systemd's own rule (load-fragment.c config_parse_timer): an empty OnXxxSec=/OnCalendar= value empties the
    WHOLE list of the timer, any other value appends -- main unit file first, then the drop-in."""
    out = []
    for text in files:
        for line in text.splitlines():
            k, sep, v = line.partition("=")
            if sep and (k.startswith("On") and (k.endswith("Sec") or k == "OnCalendar")):
                out = [] if not v else out + [(k, v)]
    return out


main_timer = open(realos.path.join(HERE, "y700-wifi-watchdog.timer"), encoding="utf-8").read()
merged = timer_list(main_timer, safety)
check("T14 timer + drop-in as systemd merges them: OnBootSec=15min AND OnUnitActiveSec=15min",
      merged == [("OnBootSec", "15min"), ("OnUnitActiveSec", "15min")], merged)
# the first version reset twice: OnUnitActiveSec= also dropped OnBootSec=15min, and OnUnitActiveSec alone never
# elapses before the service's first start (timer.c TIMER_UNIT_ACTIVE, base <= 0) -- dead watcher, dead net
old = "[Timer]\nOnBootSec=\nOnBootSec=15min\nOnUnitActiveSec=\nOnUnitActiveSec=15min\n"
check("T14 (the double-reset drop-in would have lost OnBootSec)", timer_list(main_timer, old) == [("OnUnitActiveSec", "15min")])
check("T14 no time-based call in the I/O-free core",
      not re.search(r"\b(sleep|alarm|setitimer|timerfd|threading)\b", "".join(
          open(WATCHER, encoding="utf-8").read().split("def client_selftest")[0].split('"""', 2)[2:])))

shutil.rmtree(TMP, ignore_errors=True)
print(f"\n{len(FAILS)} failures", FAILS)
sys.exit(1 if FAILS else 0)
