#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline model test for linux/power/keyhold.c (the event-driven keyhold).

This is NOT a test of the C code: no C compiler on the machine it was written
on. It transliterates main() of both keyhold versions (helper-v0.4.2's 200 ms
sampling loop and the ppoll() one) statement by statement into Python and runs
them against a model of the kernel side, written from the v7.3-rc4 sources:

  drivers/input/input.c   input_get_disposition() (a key event only passes when
                          the bit changes, dev->key is updated before any
                          handler sees it), input_handle_event() (a lone
                          SYN_REPORT is not passed), dev->grab (only the grabbing
                          client gets events), unregister = release keys, then
                          the evdev is marked dead
  drivers/input/evdev.c   per-client queue of bufsize 64: __pass_event()
                          overflow (SYN_DROPPED + newest event), packet_head
                          moves on SYN_REPORT, evdev_pass_values() drops empty
                          SYN_REPORTs; evdev_handle_get_val() snapshot +
                          __evdev_flush_queue(EV_KEY) (keeps a leading
                          SYN_REPORT); evdev_read() O_NONBLOCK (ENODEV, EAGAIN,
                          complete packets only); evdev_poll() (HUP|ERR when
                          dead, IN when packet_head != tail)
  fs/select.c             negative fds are skipped, POLLOUT is masked out,
                          slack = max(timer_slack 50 us, min(100 ms, 0.1 %))

Every syscall costs a random 1-60 us of simulated time and physical key events
land in between, so the races (an event between drain() and EVIOCGKEY, a
release right after the deadline ...) are exercised. Run: python3
keyhold-model-test.py [--seeds N] [--mutants]. Exit 0 = all checks passed
(--mutants: three deliberately broken variants must each fail some check).
"""
import heapq
import random
import sys

EV_SYN, EV_KEY = 0, 1
SYN_REPORT, SYN_DROPPED = 0, 3
POLLIN, POLLERR, POLLHUP, POLLNVAL = 0x1, 0x8, 0x10, 0x20
EINTR, EAGAIN, ENODEV, ENOMEM = 4, 11, 19, 12
MS = 1_000_000          # ns
US = 1_000


class Client:
    def __init__(self):
        self.q = []          # queued input events (type, code, value); q[0] = tail
        self.ph = 0          # packet_head, as an index into q


class Dev:
    def __init__(self, name, code, down):
        self.name, self.code = name, code
        self.down = down      # dev->key bit
        self.exist = True
        self.grabbed = False  # by some other client
        self.clients = []


class Kernel:
    def __init__(self, rng, devs, script, t0_ns, eintr=0.0, enomem_once=False):
        self.rng = rng
        self.devs = devs
        self.t = t0_ns
        self.ev = []          # heap of (time, seq, action, dev index)
        for n, (dt, action, i) in enumerate(script):
            heapq.heappush(self.ev, (t0_ns + dt, n, action, i))
        self.eintr = eintr
        self.enomem_once = enomem_once
        self.fds = {}
        self.errno = 0
        self.ppoll_calls = 0
        self.ppoll_nowait = 0     # ppoll calls that returned without any new physical event
        self.phys_seen = 0        # physical events applied so far
        self.out = []             # (time_ns, line)
        self.blocked_forever = False
        self.truth = []           # (time_ns, all keys down?) after each physical event
        self.left_syn = 0         # EVIOCGKEY flushes that left a SYN_REPORT queued (the drain() race)

    # ---- physical world -------------------------------------------------
    def all_down_truth(self):
        return all(d.exist and d.down for d in self.devs)

    def _deliver(self, d, events):
        if d.grabbed:
            return
        for c in d.clients:
            for e in events:
                if e == (EV_SYN, SYN_REPORT, 0) and c.ph == len(c.q):
                    continue                      # evdev_pass_values: drop empty SYN_REPORT
                c.q.append(e)
                if len(c.q) == 64:               # head == tail: overflow
                    c.q = [(EV_SYN, SYN_DROPPED, 0), e]
                    c.ph = 0
                if e == (EV_SYN, SYN_REPORT, 0):
                    c.ph = len(c.q)              # packet_head = head (wakes the reader)

    def _apply(self, action, i):
        d = self.devs[i]
        self.phys_seen += 1
        if action in ('down', 'up'):
            v = action == 'down'
            if d.exist and d.down != v:          # input_get_disposition: only on a change
                d.down = v
                self._deliver(d, [(EV_KEY, d.code, int(v)), (EV_SYN, SYN_REPORT, 0)])
        elif action == 'gone':
            if d.exist:
                if d.down:                       # input_dev_release_keys + SYN
                    d.down = False
                    self._deliver(d, [(EV_KEY, d.code, 0), (EV_SYN, SYN_REPORT, 0)])
                d.exist = False                  # evdev_mark_dead + hangup
        elif action == 'grab':
            d.grabbed = True
        elif action == 'ungrab':
            d.grabbed = False
        elif action == 'burst':                  # model stress only: 100 packets that change nothing we
                                                 # watch (the real devices have one key each, EV=3)
            for _ in range(100):
                self._deliver(d, [(EV_KEY, d.code + 1, 1), (EV_SYN, SYN_REPORT, 0)])
        self.truth.append((self.t, self.all_down_truth()))

    def advance(self, to):
        while self.ev and self.ev[0][0] <= to:
            t, _, action, i = heapq.heappop(self.ev)
            self.t = max(self.t, t)
            self._apply(action, i)
        self.t = max(self.t, to)

    def cost(self):
        self.advance(self.t + self.rng.randint(1, 60) * US)

    # ---- syscalls ---------------------------------------------------------
    def now_ms(self):
        self.advance(self.t + 100)               # vDSO: ~0.1 us
        return self.t // MS

    def open_by_name(self, name):
        self.cost()
        for d in self.devs:
            if d.exist and d.name == name:
                c = Client()
                d.clients.append(c)
                fd = 3 + len(self.fds)
                self.fds[fd] = (d, c)
                return fd
        return -1

    def eviocgkey(self, fd, code):
        self.cost()
        d, c = self.fds[fd]
        if not d.exist:
            self.errno = ENODEV
            return -1, False
        bit = d.down and d.code == code
        # __evdev_flush_queue(client, EV_KEY)
        nq, ph, num = [], 0, 1
        for e in c.q:
            is_report = e[0] == EV_SYN and e[1] == SYN_REPORT
            if e[0] == EV_KEY:
                continue
            if is_report and not num:
                continue
            nq.append(e)
            num += 1
            if is_report:
                num = 0
                ph = len(nq)
        c.q, c.ph = nq, ph
        if c.q:
            self.left_syn += 1
        return 0, bit

    def read16(self, fd):
        self.cost()
        d, c = self.fds[fd]
        if not d.exist:
            self.errno = ENODEV
            return -1
        if c.ph == 0:
            self.errno = EAGAIN
            return -1
        k = min(16, c.ph)
        del c.q[:k]
        c.ph -= k
        return k

    def _revents(self, pfd):
        r = []
        for fd, _ in pfd:
            if fd < 0:
                r.append(0)
                continue
            d, c = self.fds[fd]
            m = 0 if d.exist else (POLLHUP | POLLERR)
            if c.ph:
                m |= POLLIN
            r.append(m)
        return r

    def ppoll(self, pfd, tp):
        """pfd: list of [fd, revents]; tp: None or (sec, nsec)."""
        self.cost()
        self.ppoll_calls += 1
        seen = self.phys_seen
        if self.rng.random() < self.eintr:
            self.errno = EINTR
            return -1
        if self.enomem_once:
            self.enomem_once = False
            self.errno = ENOMEM
            return -1
        deadline = None
        if tp is not None:
            dur = tp[0] * 1_000_000_000 + tp[1]
            deadline = self.t + dur
            slack = max(50 * US, min(100 * MS, dur // 1000))
            wake = deadline + self.rng.randint(0, slack)
        while True:
            rv = self._revents(pfd)
            if any(rv):
                break
            nxt = self.ev[0][0] if self.ev else None
            if deadline is not None and (nxt is None or nxt > wake):
                self.advance(wake)
                rv = self._revents(pfd)
                break
            if nxt is None:
                self.blocked_forever = True
                raise Blocked()
            self.advance(nxt)
        if self.phys_seen == seen:
            self.ppoll_nowait += 1
        for i, m in enumerate(rv):
            pfd[i][1] = m
        return sum(1 for m in rv if m)

    def usleep(self, us):
        self.cost()
        self.advance(self.t + us * US + self.rng.randint(0, 50 * US))

    def puts(self, s):
        self.cost()
        self.out.append((self.t, s))


class Blocked(Exception):
    pass


class Exit(Exception):
    def __init__(self, rc):
        self.rc = rc


def drain(k, fd):
    # do { r = read(...) } while (r > 0 || (r < 0 && errno == EINTR));
    while True:
        r = k.read16(fd)
        if not (r > 0 or (r < 0 and k.errno == EINTR)):
            break
    return -1 if (r < 0 and k.errno != EAGAIN) else 0


MUTANT = None   # set by --mutants: a deliberately broken variant the checks must catch


def keyhold_new(k, seconds, specs, max_iter=5000):
    need = seconds * 1000
    fd, code, pfd = [], [], []
    for name, c in specs:
        f = k.open_by_name(name)
        if f < 0:
            return 1, 'no input device'
        fd.append(f)
        code.append(c)
        pfd.append([f, 0])
    n = len(fd)
    since = -1
    it = 0
    try:
        while True:
            it += 1
            if it > max_iter:
                return 'SPIN', it
            all_ = True
            for i in range(n):
                if pfd[i][0] < 0:
                    all_ = False
                    continue
                r, bit = k.eviocgkey(fd[i], code[i])
                if r < 0 or not bit:
                    all_ = False
            if all_ and since < 0:
                since = k.now_ms()
                k.puts('hold')
            elif all_ and k.now_ms() - since >= need:
                k.puts('done')
                return 0, it
            elif not all_ and since >= 0:
                since = -1
                k.puts('release')
            tp = None
            if all_:
                left = need - (k.now_ms() - since) if MUTANT != 'full-timeout' else need
                if left < 0:
                    left = 0
                tp = (left // 1000, left % 1000 * 1000000)
            if k.ppoll(pfd, tp) < 0:
                if k.errno != EINTR:
                    k.usleep(200000)
                continue
            for i in range(n):
                if MUTANT == 'no-drain':
                    continue
                if MUTANT == 'no-hup' and pfd[i][1] & POLLHUP:
                    continue
                if pfd[i][0] >= 0 and pfd[i][1] and \
                   ((pfd[i][1] & (POLLERR | POLLHUP | POLLNVAL)) or drain(k, fd[i]) < 0):
                    pfd[i][0] = -1
    except Blocked:
        return 'BLOCKED', it


def keyhold_old(k, seconds, specs, horizon_ns):
    need = seconds * 1000
    fd, code = [], []
    for name, c in specs:
        f = k.open_by_name(name)
        if f < 0:
            return 1, 'no input device'
        fd.append(f)
        code.append(c)
    since = -1
    it = 0
    while True:
        it += 1
        all_ = True
        for i in range(len(fd)):
            r, bit = k.eviocgkey(fd[i], code[i])
            if r < 0 or not bit:
                all_ = False
        if all_ and since < 0:
            since = k.now_ms()
            k.puts('hold')
        elif all_ and k.now_ms() - since >= need:
            k.puts('done')
            return 0, it
        elif not all_ and since >= 0:
            since = -1
            k.puts('release')
        if k.t > horizon_ns and not k.ev:
            return 'RUNNING', it
        k.usleep(200000)


def make_devs(down=(False, False)):
    return [Dev('pmic_resin', 114, down[0]), Dev('gpio-keys', 115, down[1])]


SPECS = [('pmic_resin', 114), ('gpio-keys', 115)]


def ideal(script, start_down, need_ms):
    """Expected lines for the event-driven version when every state lasts long
    enough to be seen: transitions of 'all keys down', 'done' after need."""
    down = list(start_down)
    alive = [True, True]
    out, held_since = [], None

    def all_down():
        return all(a and d for a, d in zip(alive, down))
    if all_down():
        out.append((0, 'hold'))
        held_since = 0
    for t, action, i in sorted(script, key=lambda x: x[0]):
        if held_since is not None and t - held_since >= need_ms * MS:
            out.append((held_since + need_ms * MS, 'done'))
            return out
        if action in ('down', 'up'):
            if alive[i]:
                down[i] = action == 'down'
        elif action == 'gone':
            alive[i] = False
        now = all_down()
        if now and held_since is None:
            out.append((t, 'hold'))
            held_since = t
        elif not now and held_since is not None:
            out.append((t, 'release'))
            held_since = None
    if held_since is not None:
        out.append((held_since + need_ms * MS, 'done'))
    return out


FAILS = []


def check(name, cond, detail=''):
    if not cond:
        FAILS.append(f'{name}: {detail}')


def run_new(seed, script, start_down=(False, False), need_s=10, **kw):
    rng = random.Random(seed)
    t0 = rng.randint(1, 10 ** 6) * 1_000_003     # arbitrary monotonic offset, not ms-aligned
    k = Kernel(rng, make_devs(start_down), script, t0, **kw)
    rc, it = keyhold_new(k, need_s, SPECS)
    return k, rc, it, t0


def run_old(seed, script, start_down=(False, False), need_s=10):
    rng = random.Random(seed)
    t0 = rng.randint(1, 10 ** 6) * 1_000_003
    k = Kernel(rng, make_devs(start_down), script, t0)
    horizon = t0 + (max([s[0] for s in script], default=0) + 12 * 1000 * MS)
    rc, it = keyhold_old(k, need_s, SPECS, horizon)
    return k, rc, it, t0


def lines(k):
    return [s for _, s in k.out]


def directed():
    S = 1000 * MS
    cases = {
        # name: (script [(dt_ns, action, dev)], start_down, expected lines, expected rc)
        'idle forever': ([], (False, False), [], 'BLOCKED'),
        'A at 1 s, B at 2 s, held': ([(1 * S, 'down', 0), (2 * S, 'down', 1)], (False, False), ['hold', 'done'], 0),
        'B up at 5 s, down at 6 s': ([(0, 'down', 0), (0, 'down', 1), (5 * S, 'up', 1), (6 * S, 'down', 1)],
                                     (False, False), ['hold', 'release', 'hold', 'done'], 0),
        'held before start': ([], (True, True), ['hold', 'done'], 0),
        'released at 9.999 s': ([(9999 * MS, 'up', 0)], (True, True), ['hold', 'release'], 'BLOCKED'),
        # ppoll slack for a 10 s timeout is up to 10 ms: a release inside it may still count
        'released 5 ms after the deadline': ([(10005 * MS, 'up', 0)], (True, True),
                                             (['hold', 'release'], ['hold', 'done']), ('BLOCKED', 0)),
        'released 20 ms after the deadline': ([(10020 * MS, 'up', 0)], (True, True), ['hold', 'done'], 0),
        'B gone while held': ([(5 * S, 'gone', 1), (6 * S, 'up', 0), (7 * S, 'down', 0)], (True, True),
                              ['hold', 'release'], 'BLOCKED'),
        'both gone': ([(1 * S, 'gone', 0), (2 * S, 'gone', 1)], (False, False), [], 'BLOCKED'),
        '50 ms release (the old loop can miss it)': ([(3 * S, 'up', 1), (3 * S + 50 * MS, 'down', 1)], (True, True),
                                                     ['hold', 'release', 'hold', 'done'], 0),
        'queue overflow (burst of 100 packets)': ([(1 * S, 'burst', 0), (2 * S, 'down', 0), (3 * S, 'down', 1)],
                                                  (False, False), ['hold', 'done'], 0),
        # a wakeup that changes nothing must not restart the 10 s (timeout = time left, not SECONDS)
        'queue overflow during the hold': ([(5 * S, 'burst', 0)], (True, True), ['hold', 'done'], 0),
    }
    for name, (script, sd, want, want_rc) in cases.items():
        for seed in range(20):
            k, rc, it, t0 = run_new(seed, script, sd)
            got = lines(k)
            if isinstance(want, tuple):
                ok = any(got == w and rc == r for w, r in zip(want, want_rc))
            else:
                ok = got == want and rc == want_rc
            check(name, ok, f'seed {seed}: got {got} rc={rc}, want {want} rc={want_rc}')
            check(name + ' (no spin)', it <= 3 + 3 * len(script) + 2 * got.count('hold') + 100 * name.startswith('queue'),
                  f'seed {seed}: {it} loop iterations for {len(script)} events')
            # every ppoll() that returned without a new physical event must be a timeout while held
            check(name + ' (no idle wakeups)', k.ppoll_nowait <= got.count('hold') + 1,
                  f'seed {seed}: {k.ppoll_nowait} wakeups without an event')
            if 'done' in got:
                th = [t for t, s in k.out if s == 'hold'][-1]
                td = [t for t, s in k.out if s == 'done'][0]
                check(name + ' (done timing)', 10 * S - MS < td - th <= 10 * S + 11 * MS,
                      f'seed {seed}: done {(td - th) / MS:.3f} ms after hold')
    # the 50 ms release: show what the old loop does (not a requirement)
    missed = 0
    for seed in range(20):
        ph = seed * 10 * MS                  # spread the release over the 200 ms sampling phase
        k, rc, it, t0 = run_old(seed, [(3 * S + ph, 'up', 1), (3 * S + ph + 50 * MS, 'down', 1)], (True, True))
        missed += lines(k) == ['hold', 'done']
    print(f'  50 ms release: the 200 ms loop missed it in {missed}/20 runs (event-driven: 0/20)')
    # ENOMEM once / EINTR storms: same lines
    for seed in range(20):
        k, rc, it, t0 = run_new(seed, [(1 * S, 'down', 0), (2 * S, 'down', 1)], enomem_once=True)
        check('ENOMEM once', lines(k) == ['hold', 'done'] and rc == 0, f'seed {seed}: {lines(k)} rc={rc}')
        k, rc, it, t0 = run_new(seed, [(1 * S, 'down', 0), (2 * S, 'down', 1), (5 * S, 'up', 0), (6 * S, 'down', 0)],
                                eintr=0.3)
        check('EINTR 30 %', lines(k) == ['hold', 'release', 'hold', 'done'] and rc == 0, f'seed {seed}: {lines(k)} rc={rc}')
        if lines(k)[-1:] == ['done']:
            dt = k.out[-1][0] - k.out[-2][0]
            check('EINTR 30 % (done timing)', 10 * S - MS < dt <= 10 * S + 11 * MS, f'seed {seed}: {dt / MS:.3f} ms')
    # a device missing at start: exit 1 (the old loop: same)
    rng = random.Random(1)
    k = Kernel(rng, [Dev('pmic_resin', 114, False)], [], 0)
    rc, _ = keyhold_new(k, 10, SPECS)
    check('device missing at start', rc == 1, f'rc={rc}')


def grab_tradeoff():
    """EVIOCGRAB by someone else on gpio-keys (dev 1): what each version sees."""
    S = 1000 * MS
    res = {}
    for name, script in {
        'grabbed key pressed last': [(0, 'grab', 1), (1 * S, 'down', 0), (2 * S, 'down', 1)],
        'grabbed key pressed first': [(0, 'grab', 1), (1 * S, 'down', 1), (2 * S, 'down', 0)],
        'grabbed key bounces during the hold': [(0, 'grab', 1), (1 * S, 'down', 1), (2 * S, 'down', 0),
                                                (5 * S, 'up', 1), (6 * S, 'down', 1)],
    }.items():
        kn, rcn, _, _ = run_new(0, script)
        ko, rco, _, _ = run_old(0, script)
        res[name] = (lines(kn), lines(ko))
    return res


def randomized(nseeds):
    """Random press/release/gone timelines. Stable states last >= 450 ms, so
    the 200 ms loop sees them too: both versions must print the same lines,
    the event-driven one exactly the ideal ones, on time, without spinning."""
    S = 1000 * MS
    worst_lat = 0
    old_wakeups = new_wakeups = left_syn = 0
    for seed in range(nseeds):
        rng = random.Random(10_000 + seed)
        t, script = 0, []
        down = [rng.random() < 0.3, rng.random() < 0.3]
        start = tuple(down)
        alive = [True, True]
        for _ in range(rng.randint(0, 12)):
            t += rng.randint(450, 6000) * MS + rng.randint(0, 999_999)
            i = rng.randint(0, 1)
            r = rng.random()
            if r < 0.04 and alive[i]:
                script.append((t, 'gone', i))
                alive[i] = False
            elif r < 0.08:
                script.append((t, 'burst', i))
            else:
                down[i] = not down[i]
                script.append((t, 'down' if down[i] else 'up', i))
        want = ideal(script, start, 10 * 1000)
        kn, rcn, itn, t0n = run_new(seed, script, start)
        ko, rco, ito, t0o = run_old(seed, script, start)
        gn, go = lines(kn), lines(ko)
        check('random: ideal', gn == [s for _, s in want], f'seed {seed}: {gn} vs ideal {want} script {script}')
        check('random: old == new', gn == go, f'seed {seed}: new {gn} old {go} script {script}')
        for (tw, sw), (tg, sg) in zip(want, kn.out):
            lat = (tg - t0n) - tw
            worst_lat = max(worst_lat, lat)
            check('random: latency', -MS <= lat <= 11 * MS, f'seed {seed}: {sg} {lat / MS:.3f} ms late')
        check('random: no spin', itn <= 3 + 3 * len(script) + 2 * gn.count('hold') + 100 * sum(1 for s in script if s[1] == 'burst'),
              f'seed {seed}: {itn} iterations for {len(script)} events')
        check('random: no idle wakeups', kn.ppoll_nowait <= gn.count('hold') + 1,
              f'seed {seed}: {kn.ppoll_nowait} wakeups without an event')
        new_wakeups += kn.ppoll_calls
        old_wakeups += ito
        left_syn += kn.left_syn
    return worst_lat, new_wakeups, old_wakeups, left_syn


def bounces(nseeds):
    """Contact bounces 20 us - 2 ms apart (faster than a syscall round), then a
    stable end state: the event-driven version may skip a bounce pair (it reads
    a consistent bitmap), but must end in the true state and never spin."""
    left_syn = 0
    for seed in range(nseeds):
        rng = random.Random(20_000 + seed)
        t, script, down = 0, [], [False, False]
        for _ in range(rng.randint(1, 40)):
            t += rng.randint(20, 2000) * US
            i = rng.randint(0, 1)
            down[i] = not down[i]
            script.append((t, 'down' if down[i] else 'up', i))
        final = all(down)
        kn, rcn, itn, _ = run_new(seed, script)
        got = lines(kn)
        if final:
            check('bounce: ends held -> done', got[-2:] == ['hold', 'done'] and rcn == 0, f'seed {seed}: {got} rc={rcn}')
        else:
            check('bounce: ends up -> no hold pending', (not got or got[-1] == 'release') and rcn == 'BLOCKED',
                  f'seed {seed}: {got} rc={rcn}')
        check('bounce: alternating lines', all(a != b for a, b in zip(got, got[1:])), f'seed {seed}: {got}')
        check('bounce: no spin', itn <= 3 + 3 * len(script) + 2 * got.count('hold'), f'seed {seed}: {itn} for {len(script)}')
        left_syn += kn.left_syn
    return left_syn


def run_all(nseeds, quiet=False):
    global FAILS
    FAILS = []
    say = (lambda *a: None) if quiet else print
    say('directed scenarios (20 seeds each):')
    directed()
    if not quiet:
        print('grab trade-off (someone else holds EVIOCGRAB on gpio-keys):')
        for name, (gn, go) in grab_tradeoff().items():
            print(f'  {name:38s} event-driven {gn}  200 ms loop {go}')
    worst, nw, ow, ls1 = randomized(nseeds)
    say(f'randomized timelines: {nseeds} seeds, worst latency {worst / MS:.3f} ms; '
        f'ppoll wakeups {nw} vs 200 ms loop iterations {ow}')
    ls2 = bounces(nseeds // 4)
    say(f'contact bounces: {nseeds // 4} seeds; EVIOCGKEY left a lone SYN_REPORT queued {ls1 + ls2} times '
        '(an event between drain() and EVIOCGKEY)')
    return FAILS


def main():
    global MUTANT
    nseeds = 2000
    if '--seeds' in sys.argv:
        nseeds = int(sys.argv[sys.argv.index('--seeds') + 1])
    if '--mutants' in sys.argv:
        missed = 0
        for MUTANT in ('no-drain', 'no-hup', 'full-timeout'):
            fails = run_all(200, quiet=True)
            print(f'mutant {MUTANT:12s}: {len(fails)} failed checks' + ('' if fails else '  <-- NOT CAUGHT'))
            missed += not fails
        MUTANT = None
        return 1 if missed else 0
    run_all(nseeds)
    if FAILS:
        print(f'{len(FAILS)} FAILED checks, first ones per check:')
        seen = {}
        for f in FAILS:
            key = f.split(':')[0]
            seen[key] = seen.get(key, 0) + 1
            if seen[key] <= 3:
                print('  ' + f)
        for key, n in seen.items():
            print(f'  {key}: {n} failures')
        return 1
    print('all checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
