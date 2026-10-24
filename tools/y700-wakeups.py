#!/usr/bin/env python3
"""y700-wakeups [SECONDS] [--off] [options]: who wakes the CPUs while the tablet idles - a tracefs sample.
Companion of y700-whoawake (which only counts context switches per thread): this one records WHY each
wakeup happened. For SECONDS (default 15) it enables these trace events only (no function tracer; at
screen-off idle that is ~1-2k events/s, negligible overhead) and then reads the trace buffer once:
  timer:hrtimer_expire_entry   hrtimer callbacks by function (tick_nohz_handler - tick_nohz_highres_handler in 6.9-6.x,
                               tick_sched_timer before - = the tick on a busy CPU; hrtimer_wakeup = a thread's
                               nanosleep/poll/epoll/futex timeout; watchdog_timer_fn, ...)
  timer:timer_expire_entry     timer_list timers (delayed_work_timer_fn = delayed workqueue work, process_timeout
                               = a kernel thread's schedule_timeout, ...)
  irq:irq_handler_entry        hardware interrupts by name (arch_timer, IPI, ce2, apss_cpucp_mbox, ...)
  ipi:ipi_send_cpu/_cpumask    who sends IPIs (callsite), ipi:ipi_raise (reason), csd:csd_queue_cpu (cross-CPU calls)
  sched:sched_waking           who wakes whom: the waker is the task or the IRQ/timer that is running on that CPU,
                               the wakee is comm/pid (resolved to its process afterwards)
  workqueue:workqueue_execute_start  which work functions run (kworker attribution)
  power:cpu_idle               idle exits per CPU (the denominator; --no-idle leaves it out)
Everything written under /sys/kernel/tracing (event enables, tracing_on, buffer_size_kb, saved_cmdlines_size)
is restored on exit, also on SIGINT/SIGTERM. Read-only otherwise. Root. Options:
  --off            turn the display off for the window (kscreen-doctor, like y700-whoawake) and back on afterwards
  --settle S       wait S s after the display went off before recording (default 20: the HUD sampler exits after 15 s)
  --buffer KB      per-CPU ring buffer during the window (default 8192; the previous size is restored)
  --no-idle        do not record power:cpu_idle
  --timer-list     also summarize the hrtimers armed right now (/proc/timer_list), the RTC alarm state and the devfreq
                   monitors' timer type (deferrable monitors do not wake an idle CPU by themselves) - all read-only
  --probe-async    also create a kprobe on async_schedule_node_domain to name the functions behind kworkers
                   running the "async" workqueue (opt-in: a kprobe, not a plain tracepoint; removed on exit)
  --save FILE      keep the raw trace (plus '# proc pid tgid name' and '# ipi irq IPIn description' maps) for --parse
  --parse FILE     only parse a saved trace (no root, no tablet needed)
  --top N          rows per table (default 15)
2026-10-16, for linux/power/WAKEUPS.md (the screen-off wakeup budget for the CX-collapse work). The parser was
checked against a synthetic trace in the kernel's output format (record-tgid column, hyphenated comms, IPI/csd
fields); the tool has not run on the tablet yet.
"""
import argparse, glob, os, re, signal, subprocess, sys, time
from collections import Counter, defaultdict

TRACEFS = next((p for p in ("/sys/kernel/tracing", "/sys/kernel/debug/tracing") if os.path.isdir(p + "/events")), None)
EVENTS = [("timer", "hrtimer_expire_entry"), ("timer", "timer_expire_entry"), ("irq", "irq_handler_entry"),
          ("ipi", "ipi_send_cpu"), ("ipi", "ipi_send_cpumask"), ("ipi", "ipi_raise"), ("csd", "csd_queue_cpu"),
          ("sched", "sched_waking"), ("workqueue", "workqueue_execute_start"), ("power", "cpu_idle")]
USER = ["sudo", "-u", "user", "env", "XDG_RUNTIME_DIR=/run/user/1000", "WAYLAND_DISPLAY=wayland-0",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"]
IDLE_EXIT = 4294967295
# "TASK-PID [CPU] FLAGS TIMESTAMP: EVENT: fields"; an optional "( TGID)" column when record-tgid is on
LINE = re.compile(r"^\s*(?P<comm>.*?)-(?P<pid>\d+)\s+(?:\(\s*-?\d+\)\s+)?\[(?P<cpu>\d+)\]\s+(?P<flags>\S+)\s+"
                  r"(?P<ts>\d+\.\d+):\s+(?P<ev>\w+):\s?(?P<rest>.*)$")
R_FUNC = re.compile(r"function[= ](\S+)")
R_IRQ = re.compile(r"irq=(\d+) name=(.*)$")
R_IPI = re.compile(r"callsite=(\S+) callback=(\S+)")
R_RAISE = re.compile(r"\((.*)\)\s*$")
R_CSD = re.compile(r"callsite=(\S+) func=(\S+)")
R_WAKING = re.compile(r"comm=(.*?) pid=(\d+) prio=-?\d+ target_cpu=(\d+)")
R_IDLE = re.compile(r"state=(\d+) cpu_id=(\d+)")
R_KP = re.compile(r"func=(\S+)")

# what the names usually mean on this tablet (printed under "likely owners" when seen)
NOTES = [
    (r"^hrtimer:(tick_nohz_handler|tick_nohz_highres_handler|tick_sched_timer)$", "the scheduler tick (HZ=250) on a CPU that is not idle: proportional to CPU busy time, falls with every userspace fix"),
    (r"^hrtimer:hrtimer_wakeup$", "a thread's own timeout (nanosleep / poll / epoll_wait / futex with timeout): see 'timeouts by process'"),
    (r"^hrtimer:timerfd_tmrproc$", "timerfd users (pipewire, systemd, Qt/GLib event loops with timerfd)"),
    (r"^hrtimer:(posix_timer_fn|it_real_fn)$", "timer_create / setitimer users"),
    (r"^hrtimer:watchdog_timer_fn$", "softlockup watchdog: one hrtimer per CPU every watchdog_thresh*2/5 s (10 s -> 4 s, 8 CPUs = 2/s); sysctl kernel.watchdog_thresh=60 makes it 24 s"),
    (r"^hrtimer:sched_rt_period_timer$", "RT bandwidth accounting, runs while RT tasks (pipewire, RT kthreads) consume runtime"),
    (r"^hrtimer:(hrtimer_run_softirq|__hrtimer_run_queues)$", "soft hrtimers"),
    (r"^timer:delayed_work_timer_fn$", "delayed workqueue work: the function is in the 'workqueue functions' table"),
    (r"^timer:process_timeout$", "schedule_timeout(): a kernel thread sleeping with msleep / wait_event_timeout (RCU GP kthread, rcuog/rcuop, drivers)"),
    (r"^timer:(tcp_|inet_|neigh_|ipv6_|mld_|addrconf)", "network stack timers (TCP keepalive/retransmit, neighbour, IPv6 MLD)"),
    (r"^wq:psi_avgs_work$", "PSI averages: one delayed work per cgroup with recent activity, every 2 s; nothing on the tablet reads /proc/pressure -> cmdline psi=0 (y10) removes it"),
    (r"^wq:devfreq_monitor$", "devfreq polling: memlat ddr/llcc/ddr-qos read-back at polling_interval (90-y700-memlat-poll.rules, 1 s -> 11 SCMI round trips = apss_cpucp_mbox); its timer is deferrable (see --timer-list), so the work rides on another wakeup and the cost is the mailbox replies"),
    (r"^wq:thermal_zone_device_check$", "a polled thermal zone: quiet-thermal 1 s (DT 0108); the SoC tsens zones are interrupt driven"),
    (r"^wq:(vmstat_update|vmstat_shepherd)$", "vmstat (deferrable: does not wake an idle CPU by itself)"),
    (r"^wq:(wb_workfn|wakeup_dirtytime_writeback|dirty_writeback)", "writeback (dirty_writeback_centisecs 5 s) - only when something wrote"),
    (r"^wq:power_supply_changed_work$", "battery/charger property change (qcom_battmgr via pmic_glink)"),
    (r"^wq:(ath12k_|ieee80211_|cfg80211_)", "Wi-Fi driver / mac80211 work"),
    (r"^wq:async_run_entry_fn$", "async_schedule(): the real function is hidden - run with --probe-async to name it"),
    (r"^wq:(dbs_work_handler|sugov_work)$", "cpufreq governor work"),
    (r"^wq:(rtc_timer_do_work|hrtimer)", "RTC"),
    (r"^irq:arch_timer$", "the per-CPU timer interrupt = the hrtimer expiries above landing on an idle CPU"),
    (r"^irq:IPI", "inter-processor interrupts: see the IPI tables (on arm64 a task wakeup onto an idle CPU is IPI1 'Function call', ttwu_queue_wakelist)"),
    (r"^irq:apss_cpucp_mbox$", "CPUCP mailbox = SCMI replies (memlat read-back, cpufreq); 11/s at 1 s memlat polling"),
    (r"^irq:ce\d+$", "WCN7860 copy engine (ath12k): ce2 = WMI events from the Wi-Fi firmware, ce5/ce12 = data"),
    (r"^irq:.*rtc", "RTC alarm: something programs the PMIC RTC (check /proc/driver/rtc, CLOCK_*_ALARM timerfds)"),
    (r"^irq:(glink|smp2p|qcom_glink|pmic_glink)", "remoteproc messaging (ADSP battery/sensor traffic)"),
    (r"^irq:(spmi|pmic_arb)", "PMIC bus completions (ADC reads, RTC, charger)"),
    (r"^irq:(ufshcd|ufs)", "UFS storage"),
    (r"^irq:(dwc3|xhci|usb)", "USB"),
    (r"^ipi:.*ttwu_queue_wakelist", "a task woken on a remote idle CPU (the wakeup itself; fewer wakeups = fewer of these)"),
    (r"^ipi:.*(irq_work_queue|__irq_work_queue_local)", "irq_work (perf, printk, scheduler util updates)"),
    (r"^ipi:.*(smp_call_function|generic_exec_single|smp_call_function_single)", "cross-CPU function call: see the csd table for the function"),
    (r"^ipi:.*(resched_curr|smp_send_reschedule|kick_process)", "reschedule IPI (preemption / a running task's reschedule)"),
    (r"^csd:.*(flush_tlb|tlb_flush)", "TLB shootdown (process memory changes: JITs, munmap)"),
    (r"^csd:.*(membarrier|ipi_mb|ipi_sync_core|ipi_rseq)", "membarrier() from a JIT (Chromium/V8, Electron, Go)"),
    (r"^csd:.*(cpufreq|sugov|arch_freq)", "cpufreq"),
    (r"^csd:.*(perf_|__perf)", "perf events"),
]


def rd(p, d=""):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return d


class Tracer:
    """Writes under tracefs, undone in reverse order by restore() (also on signals)."""

    def __init__(self, root):
        self.root = root
        self.undo = []
        self.kprobe = None

    def p(self, rel):
        return os.path.join(self.root, rel)

    def write(self, rel, val, remember=True):
        path = self.p(rel)
        if remember:
            old = rd(path, None)
            if old is not None:
                self.undo.append((path, old.strip()))
        with open(path, "w") as f:
            f.write(str(val))

    def restore(self):
        if self.kprobe:
            try:
                with open(self.p("events/y700/async_sched/enable"), "w") as f:
                    f.write("0")
                with open(self.p("kprobe_events"), "a") as f:
                    f.write("-:y700/async_sched\n")
            except OSError as e:
                print(f"warning: kprobe not removed: {e}", file=sys.stderr)
            self.kprobe = None
        while self.undo:
            path, old = self.undo.pop()
            try:
                if path.endswith("buffer_size_kb") and "expanded" in old:
                    # never-expanded before: give the pages back instead of allocating 'old' on every CPU
                    with open(self.p("free_buffer"), "w") as f:
                        f.write("0")
                    continue
                with open(path, "w") as f:
                    f.write(old.split()[0] if path.endswith("buffer_size_kb") else old)
            except OSError as e:
                print(f"warning: could not restore {path}: {e}", file=sys.stderr)


def dsi_dpms():
    """DPMS of the connected DSI panel(s): 'On'/'Off', or '' when none is connected."""
    st = []
    for d in glob.glob("/sys/class/drm/card*-DSI-*"):
        if rd(d + "/status").strip() == "connected":
            st.append(rd(d + "/dpms").strip())
    return " ".join(st)


def display(on):
    subprocess.run(USER + ["kscreen-doctor", "--dpms", "on" if on else "off"], capture_output=True)


def netdev():
    """interface -> (rx packets, tx packets) from /proc/net/dev (read-only)."""
    d = {}
    for ln in rd("/proc/net/dev").splitlines()[2:]:
        if ":" in ln:
            name, rest = ln.split(":", 1)
            f = rest.split()
            if len(f) >= 10:
                d[name.strip()] = (int(f[1]), int(f[9]))
    return d


def ipi_name_map(raw):
    """'IPI (irq N)' -> 'IPIk description': arm64 requests its IPIs as one ascending irq range, every one named "IPI"
    (arch/arm64/kernel/smp.c set_smp_ipi_range*), and /proc/interrupts prints them as IPI0, IPI1, ... in that order.
    The irq numbers come from /sys/kernel/irq/<N>/actions == "IPI" (read-only sysfs; all of them, fired or not).
    Only without that directory fall back to the IPI irqs seen in the trace - that mislabels every row when a lower
    IPI (e.g. IPI0 Rescheduling) did not fire inside the window."""
    irqs = sorted(int(os.path.basename(d)) for d in glob.glob("/sys/kernel/irq/*")
                  if os.path.basename(d).isdigit() and rd(d + "/actions").strip() == "IPI")
    if not irqs:
        irqs = sorted({int(m.group(1)) for m in re.finditer(r"irq=(\d+) name=IPI\s*$", raw, re.M)})
    rows = []
    for ln in rd("/proc/interrupts").splitlines():
        f = ln.split()
        if f and f[0].startswith("IPI") and f[0].endswith(":"):
            rows.append((f[0][:-1], " ".join(x for x in f[1:] if not x.isdigit())))
    return {f"IPI (irq {n})": f"{rows[i][0]} {rows[i][1]}".strip() for i, n in enumerate(irqs) if i < len(rows)}


def proc_map(pids):
    """pid -> (tgid, process comm) for the threads seen (threads that exited stay unresolved)."""
    m = {}
    for pid in pids:
        try:
            tgid = None
            with open(f"/proc/{pid}/status") as f:
                for ln in f:
                    if ln.startswith("Tgid:"):
                        tgid = int(ln.split()[1])
                        break
            if tgid is None:
                continue
            with open(f"/proc/{tgid}/comm") as f:
                m[pid] = (tgid, f.read().strip())
        except (OSError, ValueError):
            pass
    return m


def record(args):
    if os.geteuid() != 0:
        sys.exit("run as root (tracefs)")
    if not TRACEFS:
        sys.exit("tracefs not mounted (/sys/kernel/tracing)")
    t = Tracer(TRACEFS)
    present = [(s, n) for s, n in EVENTS if os.path.isdir(t.p(f"events/{s}/{n}"))]
    if ("sched", "sched_waking") not in present and os.path.isdir(t.p("events/sched/sched_wakeup")):
        present.append(("sched", "sched_wakeup"))
    if args.no_idle:
        present = [e for e in present if e != ("power", "cpu_idle")]
    missing = [f"{s}:{n}" for s, n in EVENTS if (s, n) not in present and not (args.no_idle and n == "cpu_idle")]
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(130))
    raw, pmap, off_state, net = "", {}, "", ""
    try:
        if args.off:
            display(False)
            time.sleep(args.settle)
            off_state = dsi_dpms()
            if "Off" not in off_state:
                print(f"warning: display did not go off (dpms '{off_state}'); recording anyway", file=sys.stderr)
        t.write("tracing_on", "0")
        t.write("buffer_size_kb", args.buffer)
        if os.path.exists(t.p("saved_cmdlines_size")):
            t.write("saved_cmdlines_size", 8192)
        with open(t.p("trace"), "w") as f:      # clear
            f.write("")
        for s, n in present:
            t.write(f"events/{s}/{n}/enable", "1")
        if args.probe_async and os.path.exists(t.p("kprobe_events")):
            try:
                with open(t.p("kprobe_events"), "a") as f:
                    f.write("p:y700/async_sched async_schedule_node_domain func=$arg1:symbol\n")
                t.kprobe = True
                t.write("events/y700/async_sched/enable", "1", remember=False)
            except OSError as e:
                print(f"warning: kprobe on async_schedule_node_domain not created: {e}", file=sys.stderr)
        n0, w0 = netdev(), time.monotonic()
        t.write("tracing_on", "1", remember=False)
        time.sleep(args.seconds)
        t.write("tracing_on", "0", remember=False)
        n1, w1 = netdev(), time.monotonic()
        raw = rd(t.p("trace"))
        net = " ".join(f"{i}:rx {(n1[i][0] - n0[i][0]) / (w1 - w0):.1f}/s tx {(n1[i][1] - n0[i][1]) / (w1 - w0):.1f}/s"
                       for i in sorted(n1) if i in n0 and i != "lo" and (n1[i][0] - n0[i][0] or n1[i][1] - n0[i][1]))
        over = sum(int(m.group(1)) for c in glob.glob(t.p("per_cpu/cpu*/stats"))
                   for m in [re.search(r"overrun: (\d+)", rd(c))] if m)
        if over:
            print(f"warning: ring buffer overran {over} events - use a bigger --buffer", file=sys.stderr)
        pids = {int(m.group(2)) for m in R_WAKING.finditer(raw)} | {int(m.group("pid")) for m in LINE.finditer(raw)}
        pmap = proc_map(pids)
        ipi_names = ipi_name_map(raw)
    finally:
        t.restore()
        if args.off:
            display(True)
    if args.save:
        with open(args.save, "w") as f:
            f.write(raw)
            f.write(f"# y700-wakeups meta screen={'off' if args.off else 'on'} dpms={off_state} net: {net}\n")
            for pid, (tgid, name) in sorted(pmap.items()):
                f.write(f"# proc {pid} {tgid} {name}\n")
            for label, name in sorted(ipi_names.items()):
                f.write(f"# ipi {label[9:-1]} {name}\n")
    return raw, pmap, ipi_names, missing, ("screen OFF" if args.off else "screen on") + \
        (f" (dpms {off_state})" if off_state else "") + (f"; packets {net}" if net else "; no network packets in the window")


def load(path):
    raw = rd(path, None)
    if raw is None:
        sys.exit(f"cannot read {path}")
    pmap, ipi_names, meta = {}, {}, ""
    for ln in raw.splitlines():
        if ln.startswith("# proc "):
            f = ln.split(maxsplit=4)
            if len(f) == 5:
                pmap[int(f[2])] = (int(f[3]), f[4])
        elif ln.startswith("# ipi "):
            f = ln.split(maxsplit=3)
            if len(f) == 4:
                ipi_names[f"IPI (irq {f[2]})"] = f[3]
        elif ln.startswith("# y700-wakeups meta"):
            meta = ln[len("# y700-wakeups meta"):].strip()
    return raw, pmap, ipi_names, [], meta or "saved trace"


def analyze(raw, pmap, ipi_names, top, dt_hint):
    hr, tl, irq, wq, ipi, raise_, csd, kp = Counter(), Counter(), Counter(), Counter(), Counter(), Counter(), Counter(), Counter()
    hr_cpu = defaultdict(Counter)
    irq_cpu = defaultdict(Counter)
    idle_exit = Counter()
    pair = Counter()           # (waker label, wakee key)
    waker_tot = Counter()
    wakee_tot = Counter()      # wakee key -> n
    wakee_ts = defaultdict(list)
    hr_wakee = Counter()       # (hrtimer fn, wakee key)
    comm_of = {}
    ctx = {}                   # cpu -> (ts, kind, label)
    first = last = None
    n = 0
    for ln in raw.splitlines():
        m = LINE.match(ln)
        if not m:
            continue
        n += 1
        comm, pid, cpu, flags, ts, ev, rest = (m.group("comm"), int(m.group("pid")), int(m.group("cpu")),
                                                m.group("flags"), float(m.group("ts")), m.group("ev"), m.group("rest"))
        if first is None:
            first = ts
        last = ts
        if comm != "<...>":
            comm_of[pid] = comm
        if ev == "hrtimer_expire_entry":
            f = R_FUNC.search(rest)
            fn = f.group(1) if f else "?"
            hr[fn] += 1
            hr_cpu[fn][cpu] += 1
            ctx[cpu] = (ts, "hrtimer", "hrtimer:" + fn)
        elif ev == "timer_expire_entry":
            f = R_FUNC.search(rest)
            fn = f.group(1) if f else "?"
            tl[fn] += 1
            ctx[cpu] = (ts, "timer", "timer:" + fn)
        elif ev == "irq_handler_entry":
            f = R_IRQ.search(rest)
            if f:
                name = f.group(2).strip()
                if name == "IPI":
                    name = f"IPI (irq {f.group(1)})"
                irq[name] += 1
                irq_cpu[name][cpu] += 1
                ctx[cpu] = (ts, "irq", "irq:" + name)
        elif ev in ("ipi_send_cpu", "ipi_send_cpumask"):
            f = R_IPI.search(rest)
            if f:
                site = f.group(1).split("+")[0]
                ipi[(site, f.group(2).split("+")[0])] += 1
        elif ev == "ipi_raise":
            f = R_RAISE.search(rest)
            raise_[f.group(1) if f else rest] += 1
        elif ev == "csd_queue_cpu":
            f = R_CSD.search(rest)
            if f:
                csd[(f.group(2).split("+")[0], f.group(1).split("+")[0])] += 1
        elif ev == "workqueue_execute_start":
            f = R_FUNC.search(rest)
            fn = f.group(1) if f else "?"
            wq[fn] += 1
            ctx[cpu] = (ts, "wq", "wq:" + fn)
        elif ev == "cpu_idle":
            f = R_IDLE.search(rest)
            if f and int(f.group(1)) == IDLE_EXIT:
                idle_exit[int(f.group(2))] += 1
        elif ev == "async_sched":
            f = R_KP.search(rest)
            kp[(f.group(1).split("+")[0] if f else rest)] += 1
        elif ev in ("sched_waking", "sched_wakeup"):
            f = R_WAKING.search(rest)
            if not f:
                continue
            wcomm, wpid = f.group(1), int(f.group(2))
            comm_of.setdefault(wpid, wcomm)
            c = ctx.get(cpu)
            inirq = len(flags) >= 3 and flags[2] in "hHs"
            if c and ts - c[0] <= 0.01 and (inirq or comm == "<idle>"):
                waker = c[2]
                if c[1] == "hrtimer":
                    hr_wakee[(c[2][8:], wpid)] += 1
            elif inirq:
                waker = f"irq?:{comm}"
            elif comm.startswith("kworker") and c and c[1] == "wq" and ts - c[0] <= 0.05:
                waker = f"{comm}[{c[2][3:]}]"
            elif comm != "<...>":
                waker = comm
            else:                               # saved_cmdlines missed it: the process name from /proc, if it still lives
                waker = f"{pmap[pid][1]} (pid {pid})" if pid in pmap else f"pid {pid}"
            pair[(waker, wpid)] += 1
            waker_tot[waker] += 1
            wakee_tot[wpid] += 1
            wakee_ts[wpid].append(ts)
    if not n or last is None or last <= first:
        sys.exit("no trace lines parsed (events not available, or the trace format differs)")
    dt = last - first if last - first > 1 else dt_hint

    def who(pid):
        c = comm_of.get(pid, "?")
        if pid in pmap and pmap[pid][1] != c:
            return f"{c} ({pmap[pid][1]} {pmap[pid][0]})"
        return f"{c} [{pid}]"

    def process(pid):
        return pmap[pid][1] if pid in pmap else comm_of.get(pid, "?")

    out = []
    pr = out.append
    pr(f"== {dt:.1f} s of trace, {n} events ({n / dt:.0f}/s). hrtimer {sum(hr.values()) / dt:.0f}/s, timer_list "
       f"{sum(tl.values()) / dt:.0f}/s, IRQ {sum(irq.values()) / dt:.0f}/s, IPI sends {sum(ipi.values()) / dt:.0f}/s, "
       f"wakings {sum(wakee_tot.values()) / dt:.0f}/s, work items {sum(wq.values()) / dt:.0f}/s")
    if idle_exit:
        pr(f"   idle exits/s per CPU: " + " ".join(f"cpu{c}:{idle_exit[c] / dt:.0f}" for c in sorted(idle_exit)) +
           f"  total {sum(idle_exit.values()) / dt:.0f}/s")

    def table(title, counter, fmt, limit=top):
        pr(f"== {title}")
        for k, v in counter.most_common(limit):
            pr(f"{v / dt:8.1f}/s  {fmt(k, v)}")

    table("hrtimer callbacks/s by function (CPUs it fired on)", hr,
          lambda k, v: f"{k:<32} " + " ".join(f"c{c}:{x}" for c, x in sorted(hr_cpu[k].items())))
    by_proc = Counter()
    for (fn, pid), v in hr_wakee.items():
        by_proc[(fn, process(pid))] += v
    table("timeouts/s: hrtimer callback -> process it woke (its own sleep/poll timeouts)", by_proc,
          lambda k, v: f"{k[0]:<20} -> {k[1]}")
    table("timer_list timers/s by function", tl, lambda k, v: k)
    table("workqueue functions/s", wq, lambda k, v: k)
    if kp:
        table("async_schedule() functions/s (kprobe)", kp, lambda k, v: k)
    table("IRQs/s by name (CPUs)", irq, lambda k, v: f"{k:<28} " +
          " ".join(f"c{c}:{x}" for c, x in sorted(irq_cpu[k].items())) +
          (f"   = {ipi_names[k]}" if k in ipi_names else ""))
    if ipi:
        table("IPI sends/s by callsite -> callback", ipi, lambda k, v: f"{k[0]:<36} -> {k[1]}")
    if raise_:
        table("IPIs/s by reason (ipi_raise)", raise_, lambda k, v: k)
    if csd:
        table("cross-CPU function calls/s (csd): function <- callsite", csd, lambda k, v: f"{k[0]:<36} <- {k[1]}")
    table("wakeups/s: waker -> wakee thread (process)", pair, lambda k, v: f"{k[0]:<40} -> {who(k[1])}", top + 10)
    table("wakeups/s by waker", waker_tot, lambda k, v: k)
    # per process, with burstiness: a 5 s poller shows as 'active in 3 of 15 s'
    proc_tot, proc_secs, proc_threads = Counter(), defaultdict(Counter), defaultdict(set)
    for pid, v in wakee_tot.items():
        p = process(pid)
        proc_tot[p] += v
        proc_threads[p].add(pid)
        for ts in wakee_ts[pid]:
            proc_secs[p][int(ts - first)] += 1
    pr("== wakeups/s by woken process (threads; active seconds of the window; busiest second)")
    for p, v in proc_tot.most_common(top):
        s = proc_secs[p]
        pr(f"{v / dt:8.1f}/s  {p:<24} {len(proc_threads[p]):>3} thr  {len(s):>3} of {int(dt) + 1} s  max {max(s.values())}/s")
    # likely owners
    pr("== likely owners (what the names usually mean here)")
    seen_notes = set()
    labels = [("hrtimer:" + k, v) for k, v in hr.items()] + [("timer:" + k, v) for k, v in tl.items()] + \
             [("wq:" + k, v) for k, v in wq.items()] + [("irq:" + k, v) for k, v in irq.items()] + \
             [(f"ipi:{k[0]}", v) for k, v in ipi.items()] + [(f"csd:{k[0]}", v) for k, v in csd.items()]
    for label, v in sorted(labels, key=lambda x: -x[1]):
        for pat, text in NOTES:
            if re.search(pat, label) and (pat, text) not in seen_notes and v / dt >= 0.3:
                seen_notes.add((pat, text))
                pr(f"{v / dt:8.1f}/s  {label:<36} {text}")
                break
    unattributed = sum(v for (w, _), v in pair.items() if w.startswith("irq?:"))
    if unattributed:
        pr(f"   {unattributed / dt:.1f}/s wakeups from interrupt context without a traced source (an IRQ whose entry was not seen)")
    print("\n".join(out))


def timer_list(top):
    tl = rd("/proc/timer_list")
    if not tl:
        print("== /proc/timer_list not readable")
        return
    armed = Counter(re.findall(r"^\s*#\d+: <[0-9a-f]+>, (\S+), S:", tl, re.M))
    print(f"== hrtimers armed right now by function (/proc/timer_list, all CPUs): {sum(armed.values())}")
    for k, v in armed.most_common(top):
        print(f"{v:8d}  {k}")
    m = re.search(r"jiffies: (\d+)", tl)
    if m:
        print(f"   jiffies {m.group(1)}, HZ {os.sysconf('SC_CLK_TCK')}")
    rtc = rd("/proc/driver/rtc")
    if rtc:
        keys = ("alrm_time", "alrm_date", "alarm_IRQ", "alrm_pending", "update IRQ enabled", "periodic IRQ enabled")
        print("== RTC (/proc/driver/rtc): " + ", ".join(ln.strip() for ln in rtc.splitlines() if ln.split(":")[0].strip() in keys) +
              f"; wakealarm={rd('/sys/class/rtc/rtc0/wakealarm').strip() or '-'}")
    devs = sorted(glob.glob("/sys/class/devfreq/*"))
    if devs:
        # the monitor work of a devfreq device is a delayed work whose timer is deferrable unless the driver asked for
        # "delayed": a deferrable timer does not wake an idle CPU, it runs when the CPU is awake for another reason.
        # 'timer' prints the current type only ("deferrable" or "delayed", devfreq.c timer_show) and exists only
        # when the governor exports DEVFREQ_GOV_ATTR_TIMER (the memlat "remote" governor does: inventory/memlat-sysfs)
        rows = []
        for d in devs:
            rows.append(f"{os.path.basename(d)}: polling {rd(d + '/polling_interval').strip() or '?'} ms, timer "
                        f"{rd(d + '/timer').strip() or '? (no TIMER attribute)'}, governor {rd(d + '/governor').strip() or '?'}")
        print("== devfreq monitors (a deferrable timer does not wake an idle CPU by itself; polling 0 = no monitor):\n   " +
              "\n   ".join(rows))


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("seconds", nargs="?", type=float, default=15)
    ap.add_argument("--off", action="store_true")
    ap.add_argument("--settle", type=float, default=20)
    ap.add_argument("--buffer", type=int, default=8192)
    ap.add_argument("--no-idle", action="store_true")
    ap.add_argument("--timer-list", action="store_true")
    ap.add_argument("--probe-async", action="store_true")
    ap.add_argument("--save")
    ap.add_argument("--parse")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()
    if args.help:
        print(__doc__)
        return
    if args.parse:
        raw, pmap, ipi_names, missing, state = load(args.parse)
    else:
        raw, pmap, ipi_names, missing, state = record(args)
    print(f"== y700-wakeups: {state}" + (f"; events not in this kernel: {' '.join(missing)}" if missing else ""))
    analyze(raw, pmap, ipi_names, args.top, args.seconds)
    if args.timer_list and not args.parse:
        timer_list(args.top)


if __name__ == "__main__":
    main()
