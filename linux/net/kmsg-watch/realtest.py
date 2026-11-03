#!/usr/bin/python3 -I
"""realtest: the Rust y700-kmsg-watch on this tablet's real kernel and systemd, starting no unit at all (root).

cargo test fakes /dev/kmsg (a replayed log, a socketpair) and the starter. This builds a copy of the daemon with three
constants replaced at compile time (option_env!, top of src/main.rs) and runs that copy for real:
  SYSTEMCTL  a stub: logs its arguments and its ignored signals, makes one read-only call to PID 1
             (`systemctl show -p Version`) and exits with that call's status -- the copy cannot start any unit;
  RESULT     /run/y700-kmsg-watch-rt/selftest (the RuntimeDirectory of the transient unit below);
  TAG        "y700kw-rt: selftest " -- the installed watcher ignores it (its own tag makes it start the real watchdogs,
             which is why the old y700-kmsg-watch-realtest.py must not run next to an installed watcher).
The copy runs as the transient unit y700kw-rt.service with every [Unit]/[Service] setting of ../y700-kmsg-watch.service
(RuntimeDirectory renamed; --plain: none of them) and is checked for:
  a  start-up: both kicks reach the stub with the exact argv; SIGPIPE / SIGXFSZ at their default in the child; the
     stub's bus call to PID 1 works from inside the sandbox
  b  CapEff = CAP_SYSLOG only, NoNewPrivs, a seccomp filter, SCHED_IDLE (not with --plain)
  c  asleep in ppoll with no timeout (/proc/<pid>/syscall), and its memory next to the installed watcher's
  d  a quiet window: voluntary context switches <= kernel records + 1
  e  a burst of N user.debug records: read in full, CPU (cgroup) and wakeups next to the installed watcher's
  f  --selftest of the copy through the real /dev/kmsg -> exit 0, two more stub calls, no record lost
  g  a clean stop (SIGTERM)
  python3 -I realtest.py [--plain] [--burst N]      (root, from linux/net/kmsg-watch on the tablet; exit 0 = all passed)
Side effects: N + 1 user.debug lines "y700kw-rt ..." in the kernel log (never the watchdogs' strings), the transient
unit (stopped and reset at the end), /run/y700kw-rt (removed), target/realtest/ (the copy's build). The installed
watcher only counts the extra records. 2026-11-03.
"""
import os, platform, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE = os.path.join(HERE, "..", "y700-kmsg-watch.service")
DIR = "/run/y700kw-rt"
RUNTIME = "y700-kmsg-watch-rt"
UNIT = "y700kw-rt.service"
TAG = "y700kw-rt: selftest "
CALLS = f"/run/{RUNTIME}/calls"
RT = {"Y700KW_RT_SYSTEMCTL": f"{DIR}/systemctl", "Y700KW_RT_RESULT": f"/run/{RUNTIME}/selftest", "Y700KW_RT_TAG": TAG}
STUB = f"""#!/bin/sh
/usr/bin/systemctl show -p Version --value >/dev/null; rc=$?
echo "$* | $(grep SigIgn /proc/$$/status) | rc $rc" >> {CALLS}
exit $rc
"""
WATCHDOGS = ("y700-wifi-watchdog.service", "y700-display-watchdog.service")
# the blocking call and its timeout argument in /proc/<pid>/syscall (field 3); arm64 has only ppoll
IDLE = {"aarch64": {"73": "0x0"}, "x86_64": {"7": "0xffffffffffffffff", "271": "0x0"}}
FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"   <- {detail}"), flush=True)
    if not cond:
        FAILS.append(name)


def sh(*argv, env=None):
    r = subprocess.run(argv, capture_output=True, text=True, env=env)
    return r.returncode, (r.stdout + r.stderr).strip()


def show(unit, prop):
    return sh("systemctl", "show", "-p", prop, "--value", unit)[1]


def status(pid):
    return {l.split(":")[0]: l.split(":", 1)[1].strip() for l in open(f"/proc/{pid}/status") if ":" in l}


def kwrite(lines):
    for line in lines:
        # one open per record: printk.devkmsg=ratelimit silently drops the 11th write within 5 s on one open file
        fd = os.open("/dev/kmsg", os.O_WRONLY | os.O_CLOEXEC)
        try:
            os.write(fd, f"<15>{line}\n".encode())       # one write = one record, user.debug (facility 1)
        finally:
            os.close(fd)


def num(s):
    return int(s) if s.isdigit() else 0


def kernel_records(seconds):
    """records the kernel stores while we sleep `seconds`"""
    fd = os.open("/dev/kmsg", os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    os.lseek(fd, 0, os.SEEK_END)
    time.sleep(seconds)
    n = 0
    while True:
        try:
            os.read(fd, 8192)
            n += 1
        except BlockingIOError:
            break
        except BrokenPipeError:
            n += 1
    os.close(fd)
    return n


def idle(pid):
    f = open(f"/proc/{pid}/syscall").read().split()
    want = IDLE.get(platform.machine(), {})
    return len(f) > 3 and want.get(f[0]) == f[3], " ".join(f[:4])


def wait_for(cond, timeout=10.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


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
            props.append((k, RUNTIME if k == "RuntimeDirectory" else v))
    return props


def calls():
    try:
        return open(CALLS).read().splitlines()
    except OSError:
        return []


def main(argv):
    if os.geteuid() != 0:
        print("run as root (writes to /dev/kmsg, creates a transient unit)", file=sys.stderr)
        return 2
    plain = "--plain" in argv
    burst = int(argv[argv.index("--burst") + 1]) if "--burst" in argv else 300
    # an overrun reads as EPIPE, which the installed watcher counts as a match: it would start both real watchdogs
    # (the ring here keeps 4 MB of text, tens of thousands of these records; 2000 stays far below it)
    if not 0 < burst <= 2000:
        print("--burst: 1 to 2000", file=sys.stderr)
        return 2
    rc, out = sh("cargo", "build", "--release", "--offline", "--target-dir", "target/realtest",
                 env=dict(os.environ, **RT))
    if rc:
        print(out, file=sys.stderr)
        return 1
    built = os.path.join(HERE, "target", "realtest", "release", "y700-kmsg-watch")
    os.makedirs(DIR, exist_ok=True)                  # /run: visible in the sandbox (ProtectHome hides /root)
    shutil.copy(built, f"{DIR}/y700-kmsg-watch")
    with open(f"{DIR}/systemctl", "w") as f:
        f.write(STUB)
    os.chmod(f"{DIR}/systemctl", 0o755)
    props = [("RuntimeDirectory", RUNTIME)] if plain else unit_settings(SERVICE)
    watcher = num(show("y700-kmsg-watch.service", "MainPID"))  # the installed one, only looked at
    try:
        argv_run = (["systemd-run", f"--unit={UNIT}", "--quiet", "--description=y700-kmsg-watch Rust realtest"]
                    + [f"-p{k}={v}" for k, v in props] + [f"{DIR}/y700-kmsg-watch"])
        rc, out = sh(*argv_run)
        print(f"== {'plain' if plain else f'all {len(props)} settings of y700-kmsg-watch.service'}; "
              f"{platform.release()} {platform.machine()}")
        check("systemd-run accepts the settings", rc == 0, out)
        if rc:
            return 1
        inv = show(UNIT, "InvocationID")
        journal = lambda: sh("journalctl", f"_SYSTEMD_INVOCATION_ID={inv}", "-o", "cat", "--no-pager")[1]
        wait_for(lambda: len(calls()) >= 2 and journal().count("watcher start-up") >= 2)
        j, c = journal(), calls()
        check("a1 reads /dev/kmsg, start-up kicks logged without failure",
              "reading /dev/kmsg from its end;" in j and j.count("watcher start-up") == 2 and "FAILED" not in j, j[-600:])
        check("a2 stub argv exact", [x.split(" | ")[0] for x in c[:2]]
              == [f"start --no-block --no-ask-password --quiet {u}" for u in WATCHDOGS], c)
        ign = [int(x.split("SigIgn:")[1].split()[0], 16) for x in c[:2] if "SigIgn:" in x]
        check("a3 SIGPIPE / SIGXFSZ not ignored in the child",
              len(ign) == 2 and all(not m & (1 << 12) and not m & (1 << 24) for m in ign), [hex(m) for m in ign])
        check("a4 the child's bus call to PID 1 works", all(x.endswith("| rc 0") for x in c[:2]), c)
        pid = num(show(UNIT, "MainPID"))
        st = status(pid)
        if not plain:
            check("b  CapEff = CAP_SYSLOG only, NoNewPrivs, seccomp, SCHED_IDLE",
                  int(st.get("CapEff", "0"), 16) == 1 << 34 and st.get("NoNewPrivs") == "1" and st.get("Seccomp") == "2"
                  and os.sched_getscheduler(pid) == os.SCHED_IDLE,
                  {k: st.get(k) for k in ("CapEff", "NoNewPrivs", "Seccomp")} | {"sched": os.sched_getscheduler(pid)})
        time.sleep(0.3)
        ok, raw = idle(pid)
        check("c  asleep in ppoll with no timeout", ok, raw)
        ws = status(watcher) if watcher else {}
        print(f"   memory: Rust cgroup {num(show(UNIT, 'MemoryCurrent')) / 1024:.0f} KiB, VmRSS {st.get('VmRSS')}, "
              f"RssAnon {st.get('RssAnon')} | installed watcher cgroup "
              f"{num(show('y700-kmsg-watch.service', 'MemoryCurrent')) / 1024:.0f} KiB, VmRSS {ws.get('VmRSS')}, "
              f"RssAnon {ws.get('RssAnon')}")
        ctxt = lambda p: int(status(p)["voluntary_ctxt_switches"])
        before = ctxt(pid)
        n = kernel_records(5)
        after = ctxt(pid)
        print(f"   5 s quiet window: {n} kernel records, voluntary context switches +{after - before}")
        check("d  no wakeups beyond one per kernel record", after - before <= n + 1, (after - before, n))
        cpu = lambda u: num(show(u, "CPUUsageNSec"))
        b = (cpu(UNIT), ctxt(pid), cpu("y700-kmsg-watch.service"), ctxt(watcher) if watcher else 0)
        t = time.monotonic()
        kwrite(f"y700kw-rt burst {i}" for i in range(burst))
        wrote = time.monotonic() - t
        time.sleep(2)                                    # both run at SCHED_IDLE: let them drain
        a = (cpu(UNIT), ctxt(pid), cpu("y700-kmsg-watch.service"), ctxt(watcher) if watcher else 0)
        print(f"   burst of {burst} records written in {wrote * 1000:.0f} ms: Rust {(a[0] - b[0]) / 1000:.0f} us CPU, "
              f"{a[1] - b[1]} wakeups ({(a[0] - b[0]) / burst / 1000:.1f} us/record) | installed watcher "
              f"{(a[2] - b[2]) / 1000:.0f} us CPU, {a[3] - b[3]} wakeups ({(a[2] - b[2]) / burst / 1000:.1f} us/record)")
        n0 = len(calls())
        r = subprocess.run([built, "--selftest"], capture_output=True, text=True, timeout=20)
        out = r.stdout.strip()
        print(f"   --selftest: {out}")
        records = int(out.split("records ")[1].split(",")[0]) if "records " in out else -1
        check("f1 --selftest through the real /dev/kmsg -> 0", r.returncode == 0 and " ok wifi=0 display=0; up " in out,
              (r.returncode, out, r.stderr))
        check("f2 two more stub calls for it", len(calls()) == n0 + 2, calls()[n0:])
        check("f3 every burst record read, none lost", records >= burst + 1 and ", lost 0, overruns 0," in out, out)
        since = f"@{int(time.time()) - 1}"
        sh("systemctl", "stop", UNIT)
        tail = lambda: sh("journalctl", "-u", UNIT, "--since", since, "-o", "cat", "--no-pager")[1]
        wait_for(lambda: "Deactivated successfully" in tail() or "Failed with result" in tail(), 5)
        check("g  stop is clean (SIGTERM)", "Deactivated successfully" in tail() and "Failed with result" not in tail(), tail())
    finally:
        sh("systemctl", "stop", UNIT)
        sh("systemctl", "reset-failed", UNIT)
        shutil.rmtree(DIR, ignore_errors=True)
    print(f"\n{len(FAILS)} failures", FAILS)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
