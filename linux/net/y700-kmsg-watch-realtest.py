#!/usr/bin/python3 -I
"""y700-kmsg-watch-realtest: what the PC selftest can only fake, on a real Linux kernel and systemd (root).

The PC selftest (y700-kmsg-watch-selftest.py) drives the watcher with fake os / select / time objects. This one
runs it for real. No y700 unit is started, nothing is installed:
  part 1  /dev/kmsg itself: SEEK_END, lseek with an offset, the facility of userspace writes, a too-small read
          buffer, poll(-1) asleep with no timeout (/proc/<pid>/syscall) and woken by a new record;
  part 2  the real daemon() with SYSTEMCTL pointed at a stub script: the start-up kicks and their argv, SIGPIPE /
          SIGXFSZ back to default in the child, no wakeups while the kernel log is quiet (voluntary context
          switches vs. kernel records over the same window), --selftest through the real /dev/kmsg, SIGTERM;
  part 3  (--sandbox) the daemon as a transient systemd service with EVERY [Unit]/[Service] setting of the shipped
          y700-kmsg-watch.service (RuntimeDirectory renamed so a real install is not disturbed), watching two
          transient dummy oneshot units instead of the watchdogs: it must read /dev/kmsg through DevicePolicy=closed
          + DeviceAllow, answer --selftest, and its sandboxed `systemctl start` must be authorized by PID 1.

  python3 -I linux/net/y700-kmsg-watch-realtest.py [--sandbox]      (root; exit 0 = all passed)

Side effects: a handful of user.debug lines "<15>y700kw-realtest ..." / "<7>..." in the kernel log (never the
watchdogs' error strings), and with --sandbox three transient units y700kw-*-rt that are stopped again. If the
real y700-kmsg-watch is running, it also answers the --selftest ping (it starts the two watchdog units once,
exactly as the daily checklist does). On the tablet it is part of the deploy steps (KMSG-WATCH.md section 4).

2026-10-16 on WSL Ubuntu 26.04 (python3 3.14.4, systemd 259.5-0ubuntu3.4, glibc 2.43 -- the tablet's versions --
but x86_64 and kernel 6.18.33.2-microsoft-standard-WSL2): 1a-1f, 2a-2d, 2f, 2g, 3a-3e, 3g passed. 2e and 3f failed
because the daemon wrote its answer to the import-time default RESULT instead of the path this test had set (part
2's answer "selftest <token> ok wifi=0 display=0" was found in /run/y700-kmsg-watch/selftest, part 3's journal
showed the same line, i.e. the daemon and its sandboxed systemctl did their part); daemon() now passes RESULT explicitly (selftest T12b). Also changed afterwards: part 3 reads the
journal of its own invocation only and waits for the stop message. This fixed version has NOT been re-run
(KMSG-WATCH.md section 12.4 says why).
"""
import errno, importlib.machinery, importlib.util, os, platform, select, shutil, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
WATCHER = os.path.join(HERE, "y700-kmsg-watch")
SERVICE = WATCHER + ".service"
TOKEN = f"{os.getpid()}-{time.time_ns() // 1000000}"
FAILS = []
# poll(2) number and the index of its timeout argument in /proc/<pid>/syscall; aarch64 has only ppoll
SYSCALLS = {"x86_64": {7: ("poll", "0xffffffffffffffff"), 271: ("ppoll", "0x0")}, "aarch64": {73: ("ppoll", "0x0")}}


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"   <- {detail}"), flush=True)
    if not cond:
        FAILS.append(name)


def load(path):
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("y700_kmsg_watch", path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("y700_kmsg_watch", loader))
    loader.exec_module(mod)
    return mod


def kwrite(text, prefix="<15>"):
    fd = os.open("/dev/kmsg", os.O_WRONLY | os.O_CLOEXEC)
    try:
        os.write(fd, f"{prefix}{text}\n".encode())
    finally:
        os.close(fd)


def reader():
    fd = os.open("/dev/kmsg", os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    os.lseek(fd, 0, os.SEEK_END)
    return fd


def drain(fd):
    out = []
    while True:
        try:
            out.append(os.read(fd, 8192))
        except BlockingIOError:
            return out
        except BrokenPipeError:
            out.append(b"EPIPE")


def idle_syscall(pid):
    """(name, timeout argument) of the syscall pid is blocked in, or (None, raw line)."""
    try:
        line = open(f"/proc/{pid}/syscall").read().split()
    except OSError as e:
        return None, str(e)
    if not line or not line[0].lstrip("-").isdigit():
        return None, " ".join(line)
    known = SYSCALLS.get(platform.machine(), {}).get(int(line[0]))
    if not known:
        return None, " ".join(line)
    name, _ = known
    return name, line[3]       # nr arg0 arg1 arg2: poll's timeout / ppoll's tsp is arg2 = field 3


def no_timeout(pid):
    name, arg = idle_syscall(pid)
    want = {n: t for n, t in SYSCALLS.get(platform.machine(), {}).values()}
    return name is not None and arg == want[name], (name, arg)


def ctxt(pid):
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("voluntary_ctxt_switches:"):
            return int(line.split()[1])
    return None


def wait_for(cond, timeout=10.0, step=0.05):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(step)
    return cond()


# ------------------------------------------------------------------ part 1: /dev/kmsg
def part1(mod):
    print("== part 1: /dev/kmsg on this kernel:", platform.release(), platform.machine())
    old = os.open("/dev/kmsg", os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)     # no seek: the oldest record
    first_old = mod.parse(os.read(old, 8192))
    os.close(old)
    fd = reader()
    stray = drain(fd)
    kwrite(f"y700kw-realtest seek-end {TOKEN}")
    recs = [mod.parse(r) for r in drain(fd) if r != b"EPIPE"]
    mine = [p for p in recs if p and f"seek-end {TOKEN}" in p[2]]
    check("1a SEEK_END: only records after the seek, ours among them",
          mine and first_old and len(recs) <= 20 and all(p[1] > first_old[1] for p in recs if p),
          (len(stray), len(recs), first_old and first_old[1]))
    try:
        os.lseek(fd, 1, os.SEEK_SET)
        check("1b lseek with an offset -> ESPIPE", False, "no error")
    except OSError as e:
        check("1b lseek with an offset -> ESPIPE", e.errno == errno.ESPIPE, e)
    kwrite(f"y700kw-realtest facility {TOKEN}", prefix="<7>")         # asks for facility 0 (kern), level 7
    got = [mod.parse(r) for r in drain(fd) if r != b"EPIPE"]
    p = next((x for x in got if x and f"facility {TOKEN}" in x[2]), None)
    check("1c userspace '<7>' (facility 0 asked) is stored as facility 1", p is not None and p[0] == 1, p)
    # a buffer smaller than the record: EINVAL and the record is gone (devkmsg_read advances seq first)
    for attempt in range(3):
        drain(fd)
        kwrite(f"y700kw-realtest small-buffer-{attempt} {TOKEN}")
        kwrite(f"y700kw-realtest after-small-buffer-{attempt} {TOKEN}")
        try:
            os.read(fd, 16)
            err = None
        except OSError as e:
            err = e.errno
        rest = [mod.parse(r) for r in drain(fd) if r != b"EPIPE"]
        texts = [x[2] for x in rest if x]
        if any(f"small-buffer-{attempt} {TOKEN}" in t and "after" not in t for t in texts):
            continue                                       # a stray kernel record took the EINVAL; retry
        check("1d read() with a 16-byte buffer -> EINVAL, that record is lost, the next one is not",
              err == errno.EINVAL and any(f"after-small-buffer-{attempt} {TOKEN}" in t for t in texts), (err, texts))
        break
    else:
        check("1d small buffer", False, "three stray-record collisions in a row")
    # poll(-1) asleep without a timeout, woken by a record
    r_pipe, w_pipe = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            cfd = reader()
            p = select.poll()
            p.register(cfd, select.POLLIN)
            p.poll(-1)
            os.write(w_pipe, b"woke " + b"|".join(drain(cfd)))
        finally:
            os._exit(0)
    os.close(w_pipe)
    time.sleep(0.5)
    ok, info = no_timeout(pid)
    try:
        wchan = open(f"/proc/{pid}/wchan").read()
    except OSError:
        wchan = "?"
    print(f"   blocked child: /proc/{pid}/syscall -> {info}, wchan {wchan}")
    kwrite(f"y700kw-realtest wake {TOKEN}")
    os.waitpid(pid, 0)
    msg = os.read(r_pipe, 65536)
    os.close(r_pipe)
    check("1e poll(-1) sleeps with no timeout argument", ok, info)
    check("1f ... and a new record wakes it", msg.startswith(b"woke") and f"wake {TOKEN}".encode() in msg, msg[:120])
    os.close(fd)


# ------------------------------------------------------------------ part 2: the real daemon, stub systemctl
def child_stub(watcher, stub, result, log):
    mod = load(watcher)
    mod.SYSTEMCTL, mod.RESULT = stub, result
    out = open(log, "w", buffering=1)
    os.dup2(out.fileno(), 1)
    sys.stdout = out
    mod.daemon()


def part2(mod):
    print("== part 2: the real daemon(), systemctl = a stub")
    tmp = tempfile.mkdtemp(prefix="y700kw-realtest-")
    stub, calls, result, log = (os.path.join(tmp, n) for n in ("systemctl", "calls", "run/selftest", "daemon.log"))
    with open(stub, "w") as f:
        f.write(f'#!/bin/sh\necho "$* | $(grep SigIgn /proc/$$/status)" >> {calls}\nexit 0\n')
    os.chmod(stub, 0o755)
    proc = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--child-stub", WATCHER, stub, result, log])
    try:
        lines = lambda: open(calls).read().splitlines() if os.path.exists(calls) else []
        wait_for(lambda: len(lines()) >= 2, 10)
        c = lines()
        want = [f"start --no-block --no-ask-password --quiet {u}" for u in mod.UNITS]
        check("2a start-up kicks: both watchdogs, exact argv", [x.split(" | ")[0] for x in c[:2]] == want, c)
        ign = [int(x.split("SigIgn:")[1], 16) for x in c[:2] if "SigIgn:" in x]
        check("2b SIGPIPE / SIGXFSZ not ignored in the spawned child",
              ign and all(not (m & (1 << (signal.SIGPIPE - 1))) and not (m & (1 << (signal.SIGXFSZ - 1))) for m in ign),
              [hex(m) for m in ign])
        time.sleep(0.5)
        ok, info = no_timeout(proc.pid)
        check("2c idle daemon blocked in poll with no timeout", ok, info)
        fd = reader()
        before = ctxt(proc.pid)
        time.sleep(5)
        records = len(drain(fd))
        after = ctxt(proc.pid)
        os.close(fd)
        print(f"   5 s quiet window: {records} kernel records, daemon voluntary ctxt switches +{after - before}")
        check("2d no wakeups beyond one per kernel record", after - before <= records + 1, (after - before, records))
        n0 = len(lines())
        rc = mod.client_selftest(result=result)
        check("2e --selftest through the real /dev/kmsg -> 0", rc == 0, rc)
        check("2f ... and both watchdogs started for it", len(lines()) == n0 + 2, lines()[n0:])
        proc.send_signal(signal.SIGTERM)
        proc.wait(5)
        check("2g SIGTERM ends it (default action, as systemd stop does)", proc.returncode == -signal.SIGTERM, proc.returncode)
        print("   daemon log:", " / ".join(open(log).read().splitlines()[:3]))
    finally:
        if proc.poll() is None:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------------------------ part 3: under systemd with the shipped sandbox
RT_DIR = "/run/y700kw-realtest"
RT_UNIT = "y700kw-watch-rt.service"
RT_TARGETS = ("y700kw-wifi-rt.service", "y700kw-display-rt.service")
RT_RUNTIME = "y700-kmsg-watch-rt"


def child_sandbox(watcher):
    mod = load(watcher)
    # needles that never occur, so only start-up and --selftest start the dummies
    mod.WATCHES = tuple((f"y700kw never matches {i} {os.urandom(8).hex()}", u) for i, u in enumerate(RT_TARGETS))
    mod.UNITS = RT_TARGETS
    mod.RESULT = f"/run/{RT_RUNTIME}/selftest"
    mod.daemon()


def unit_settings(path):
    props, section = [], None
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line
            continue
        k, _, v = line.partition("=")
        if section in ("[Unit]", "[Service]") and k not in ("Description", "ExecStart"):
            props.append((k, RT_RUNTIME if k == "RuntimeDirectory" else v))
    return props


def sh(*argv):
    r = subprocess.run(argv, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def part3(mod):
    print("== part 3: under systemd with every setting of y700-kmsg-watch.service")
    if not os.path.isdir("/run/systemd/system"):
        check("3 systemd is PID 1", False, "not booted with systemd")
        return
    os.makedirs(RT_DIR, exist_ok=True)              # /run is visible in the sandbox (PrivateTmp hides /tmp)
    shutil.copy(WATCHER, f"{RT_DIR}/y700-kmsg-watch")
    shutil.copy(os.path.abspath(__file__), f"{RT_DIR}/realtest.py")
    props = unit_settings(SERVICE)
    try:
        for u in RT_TARGETS:
            rc, out = sh("systemd-run", f"--unit={u}", "--quiet", "-pType=oneshot", "-pRemainAfterExit=yes", "/bin/true")
            check(f"3 dummy {u} active", rc == 0, out)
        argv = (["systemd-run", f"--unit={RT_UNIT}", "--quiet", "--description=y700-kmsg-watch realtest"]
                + [f"-p{k}={v}" for k, v in props]
                + ["/usr/bin/python3", "-IS", f"{RT_DIR}/realtest.py", "--child-sandbox", f"{RT_DIR}/y700-kmsg-watch"])
        rc, out = sh(*argv)
        check(f"3a systemd-run accepts all {len(props)} settings of the shipped unit", rc == 0, out)
        if rc:
            return
        # this run only (the unit name repeats across runs): the journal of this invocation
        inv = sh("systemctl", "show", "-p", "InvocationID", "--value", RT_UNIT)[1]
        journal = lambda: sh("journalctl", f"_SYSTEMD_INVOCATION_ID={inv}", "-o", "cat", "--no-pager")[1]
        wait_for(lambda: journal().count("watcher start-up") >= 2, 15)
        j = journal()
        check("3b it reads /dev/kmsg in the sandbox and its start-up starts succeed",
              "reading /dev/kmsg" in j and j.count("watcher start-up") == 2 and "FAILED" not in j and "Traceback" not in j, j[-600:])
        pid = int(sh("systemctl", "show", "-p", "MainPID", "--value", RT_UNIT)[1] or 0)
        if not pid:
            check("3c the unit has a main process", False, sh("systemctl", "status", "--no-pager", RT_UNIT)[1][-400:])
            return
        status = {l.split(":")[0]: l.split(":", 1)[1].strip() for l in open(f"/proc/{pid}/status") if ":" in l}
        check("3c CapEff = CAP_SYSLOG only, NoNewPrivs, seccomp filter",
              int(status.get("CapEff", "0"), 16) == 1 << 34 and status.get("NoNewPrivs") == "1" and status.get("Seccomp") == "2",
              {k: status.get(k) for k in ("CapEff", "CapBnd", "NoNewPrivs", "Seccomp")})
        check("3d SCHED_IDLE", os.sched_getscheduler(pid) == getattr(os, "SCHED_IDLE", 5), os.sched_getscheduler(pid))
        time.sleep(0.3)
        ok, info = no_timeout(pid)
        check("3e idle in poll with no timeout", ok, info)
        rc = mod.client_selftest(result=f"/run/{RT_RUNTIME}/selftest")
        check("3f --selftest answered ok (sandboxed systemctl start authorized by PID 1)", rc == 0, journal()[-400:])
        mem = sh("systemctl", "show", "-p", "MemoryCurrent", "--value", RT_UNIT)[1]
        print(f"   MemoryCurrent of the unit: {mem} bytes; VmRSS {status.get('VmRSS')}")
        since = f"@{int(time.time()) - 1}"
        sh("systemctl", "stop", RT_UNIT)
        tail_of = lambda: sh("journalctl", "-u", RT_UNIT, "--since", since, "-o", "cat", "--no-pager")[1]
        wait_for(lambda: "Deactivated successfully" in tail_of() or "Failed with result" in tail_of(), 5, 0.2)
        tail = tail_of()
        check("3g stop is clean (SIGTERM, not a failure)", "Deactivated successfully" in tail and "Failed with result" not in tail, tail)
    finally:
        for u in (RT_UNIT,) + RT_TARGETS:
            sh("systemctl", "stop", u)
            sh("systemctl", "reset-failed", u)
        shutil.rmtree(RT_DIR, ignore_errors=True)


def main(argv):
    if argv[1:2] == ["--child-stub"]:
        return child_stub(*argv[2:6])
    if argv[1:2] == ["--child-sandbox"]:
        return child_sandbox(argv[2])
    if not hasattr(os, "geteuid") or not os.path.exists("/dev/kmsg"):
        print("Linux only (needs /dev/kmsg); the PC test is y700-kmsg-watch-selftest.py", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("run as root (writes to /dev/kmsg; part 3 creates transient units)", file=sys.stderr)
        return 2
    mod = load(WATCHER)
    part1(mod)
    part2(mod)
    if "--sandbox" in argv[1:]:
        part3(mod)
    print(f"\n{len(FAILS)} failures", FAILS)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
