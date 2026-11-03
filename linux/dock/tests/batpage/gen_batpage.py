#!/usr/bin/env python3
"""gen_batpage.py: writes the battery page's canned reports next to it (linux/dock/tests/batpage/*.json, the
JSON v1 of linux/power/battery/DESIGN.md 6b) from a minute-level simulation of one week.

Every number in a file comes out of the same simulated timeline (apps, screen, charger, gaps, degraded time), so
curves, bands, seconds, items, buckets, splits and titles agree with each other the way the report's own output
does, and each file passes y700_battery.contract.validate. The report is not run: the files are the page's test
bed (fmt-test.mjs, batpage.sh), the contract test reads them, and the timeline is the same fixed week on any host.

    python3 -I gen_batpage.py [desktop-files.txt]     write the seven files, print one line per file
    python3 -I gen_batpage.py --check                 write nothing; exit 1 when a file differs from what it makes

desktop-files.txt (a bp-capture dump of the tablet's .desktop files) also checks every app icon is one the tablet
has. Change the timeline here and regenerate rather than editing a file by hand; the report's own rules (remain,
charges, apps_rest bg_s, data_from) are mirrored on the simulated rows.
"""
import calendar
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "power" / "battery" / "report"))
from y700_battery import contract  # noqa: E402

OUT = HERE
TZ = 480
OFF = TZ * 60
DAY = 86400


def L(mo, d, h, mi):
    return calendar.timegm((2026, mo, d, h, mi, 0)) - OFF


NOW = L(10, 30, 8, 11)
WIFI = "Wi\u2011Fi"

# ---- apps (energies in battery % per minute) -------------------------------------------------
APPS = {
    "chrome": dict(id="google-chrome", name="Google Chrome", icon="google-chrome", fg=0.046,
                   bg_on=0.0016, bg_off=0.00055, wifi=0.004, cpu=0.42, cpu_bg=0.02, gpu=0.17,
                   wk=14.0, always=True),
    "claude": dict(id="com.anthropic.Claude", name="Claude", icon="claude-desktop", fg=0.036,
                   bg_on=0.0021, bg_off=0.0004, wifi=0.002, cpu=0.31, cpu_bg=0.03, gpu=0.08,
                   wk=6.0, always=True),
    "telegram": dict(id="org.telegram.desktop", name="Telegram", icon="org.telegram.desktop",
                     fg=0.012, bg_on=0.0003, bg_off=0.0001, wifi=0.001, cpu=0.10, cpu_bg=0.004,
                     gpu=0.03, wk=2.5, always=True),
    "steam": dict(id="steam-arm64", name="Steam", icon="steam-arm64", fg=0.086, bg_on=0.004,
                  bg_off=0.0012, wifi=0.002, cpu=1.55, cpu_bg=0.12, gpu=0.62, wk=38.0,
                  linger=15),
    "wiliwili": dict(id="cn.xfangfang.wiliwili", name="wiliwili", icon="cn.xfangfang.wiliwili",
                     fg=0.041, bg_on=0.0, bg_off=0.0, wifi=0.012, cpu=0.36, cpu_bg=0.0, gpu=0.24,
                     wk=0.0, linger=1),
    "moonlight": dict(id="com.moonlight_stream.Moonlight", name="Moonlight",
                      icon="com.moonlight_stream.Moonlight", fg=0.051, bg_on=0.0, bg_off=0.0,
                      wifi=0.018, cpu=0.47, cpu_bg=0.0, gpu=0.31, wk=0.0, linger=1),
    "dolphin": dict(id="org.kde.dolphin", name="Dolphin 文件管理器", icon="org.kde.dolphin",
                    fg=0.026, bg_on=0.0, bg_off=0.0, wifi=0.0, cpu=0.24, cpu_bg=0.0, gpu=0.05,
                    wk=0.0, linger=1),
    "konsole": dict(id="org.kde.konsole", name="Konsole 终端", icon="utilities-terminal",
                    fg=0.008, bg_on=0.0, bg_off=0.0, wifi=0.0, cpu=0.06, cpu_bg=0.0, gpu=0.02,
                    wk=0.0, linger=1),
    "okular": dict(id="org.kde.okular", name="Okular 文档查看器", icon="okular", fg=0.010,
                   bg_on=0.0, bg_off=0.0, wifi=0.0, cpu=0.05, cpu_bg=0.0, gpu=0.03, wk=0.0,
                   linger=1),
}
SCREEN_ON, FLOOR_ON, UI_ON, SYS_ON, WIFI_ON, OTHER_ON = 0.055, 0.0159, 0.011, 0.004, 0.003, 0.006
FLOOR_OFF, SYS_OFF, UI_OFF, WIFI_OFF, OTHER_OFF = 0.0065, 0.0010, 0.0004, 0.0004, 0.0009
CLOSED_OFF = 0.0003

DAY_A = [("07:35", "08:05", "chrome"), ("08:40", "08:52", "telegram"), ("09:00", "09:10", "konsole"),
         ("09:12", "09:27", "claude"), ("11:30", "11:50", "chrome"), ("12:40", "13:30", "wiliwili"),
         ("14:10", "14:20", "okular"), ("15:00", "15:20", "claude"), ("15:20", "15:55", "dolphin"),
         ("17:30", "17:45", "telegram"), ("19:30", "21:10", "steam"), ("21:40", "22:30", "moonlight"),
         ("22:30", "23:20", "chrome"), ("23:50", "23:59", "claude")]
DAY_B = [("08:00", "08:30", "chrome"), ("09:02", "09:08", "konsole"), ("10:15", "10:32", "claude"),
         ("12:20", "13:15", "wiliwili"), ("16:00", "16:30", "chrome"), ("18:50", "19:02", "telegram"),
         ("20:00", "21:25", "moonlight"), ("21:45", "23:05", "chrome"), ("23:20", "23:45", "claude")]
STEAM_CLIENT_MIN = 6


def hm(s):
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def sessions(first_day, last_day, pattern):
    """[(a, b, app)] epoch, for local days first_day..last_day (October)."""
    out = []
    for d in range(first_day, last_day + 1):
        tpl = pattern(d)
        for a, b, app in tpl:
            t0 = L(10, d, 0, 0)
            out.append((t0 + hm(a) * 60, t0 + hm(b) * 60, app))
    return out


def in_any(t, ivs):
    return any(a <= t < b for a, b in ivs)


def simulate(sc):
    """Minute rows from sc['t0'] to NOW."""
    t0 = sc["t0"]
    pct = sc["pct0"]
    sess = sorted(sessions(sc["day0"], 30, sc["pattern"]))
    sess = [s for s in sess if not any(a < s[1] and s[0] < b for a, b in sc.get("gaps", []))]
    on_at = {}
    for a, b, app in sess:
        for t in range(a, b, 60):
            on_at[t] = app
    extra_on = sc.get("extra_on", [])
    for a, b, app in extra_on:
        for t in range(a, b, 60):
            on_at[t] = app
    # lifetimes of apps that are not always alive
    alive_iv = {k: [] for k in APPS}
    for a, b, app in sess + extra_on:
        alive_iv[app].append((a, b + 60 * APPS[app].get("linger", 0)))
    plugs = sc["plugs"]
    rows = []
    plugged_until = None
    charging_target = 100
    t = t0
    steam_start = {}
    for a, b, app in sess:
        if app == "steam":
            steam_start[(a, b)] = a
    while t < NOW:
        r = {"t": t, "pct0": pct}
        gap = in_any(t, sc.get("gaps", []))
        plug = None
        for a, b, *rest in plugs:
            if a <= t < b:
                plug = rest[0] if rest else 100
        if plug is None and sc.get("auto"):
            local_min = (t + OFF) // 60 % 1440
            if plugged_until and t < plugged_until:
                plug = 100
            elif not gap and local_min == 23 * 60 + 30 and pct <= 25:
                # simulated: charge overnight from 23:30 when it is low
                plugged_until = t + (8 * 60 + 10) * 60
                plug = 100
            elif not gap and pct <= 16 and L(10, 21, 0, 0) <= t:
                full_min = (100 - pct) / 1.0 + 30
                plugged_until = t + int(full_min) * 60
                plug = 100
        app = on_at.get(t) if not gap else None
        on = app is not None or (sc.get("page_on", True) and not gap and t >= NOW - 60)   # the page is open now
        if t >= NOW - 60 and app is None:
            app = None
        r["gap"] = gap
        r["on"] = on and not gap
        r["fg"] = app
        r["plug"] = plug is not None and not gap
        r["drain"] = {}
        if gap:
            pass
        elif r["plug"]:
            target = plug
            if pct < target - 0.01:
                rate = 1.1 if pct < 90 else 0.45
                pct = min(target, pct + rate)
            elif sc.get("bypass_wiggle") and (t // 60) % 997 == 0:
                pct = max(target - 1, pct - 1)
            elif pct > target:
                pct = target
        else:
            d = {}
            if r["on"]:
                d["screen"] = SCREEN_ON
                d["floor"] = FLOOR_ON
                d["ui"] = UI_ON
                d["sys"] = SYS_ON
                d["wifi"] = WIFI_ON
                d["other"] = OTHER_ON
            else:
                d["floor"] = FLOOR_OFF
                d["sys"] = SYS_OFF
                d["ui"] = UI_OFF
                d["wifi"] = WIFI_OFF
                d["other"] = OTHER_OFF
            for k, a in APPS.items():
                alive = a.get("always") or in_any(t, alive_iv[k])
                if not alive:
                    continue
                if app == k:
                    d["app:" + k] = d.get("app:" + k, 0) + a["fg"]
                    d["wifi"] += a["wifi"]
                elif r["on"]:
                    if a["bg_on"]:
                        d["app:" + k] = d.get("app:" + k, 0) + a["bg_on"]
                else:
                    if a["bg_off"]:
                        d["app:" + k] = d.get("app:" + k, 0) + a["bg_off"]
            if sc.get("closed_until") and t < sc["closed_until"]:
                d["app:#closed"] = CLOSED_OFF if not r["on"] else CLOSED_OFF * 2
            r["drain"] = d
            pct -= sum(d.values())
        r["pct1"] = pct
        r["alive"] = [k for k, a in APPS.items()
                      if not gap and (a.get("always") or in_any(t, alive_iv[k]))]
        r["window"] = None
        if app == "steam":
            for (a, b), s0 in steam_start.items():
                if a <= t < b:
                    r["window"] = "Steam" if t < s0 + STEAM_CLIENT_MIN * 60 else "示例游戏(Sample)"
        rows.append(r)
        t += 60
    return rows


# ---- formatting ---------------------------------------------------------------------------------

def lt(t):
    import time
    return time.gmtime(t + OFF)


def clock(t):
    g = lt(t)
    return f"{g.tm_hour:02d}:{g.tm_min:02d}"


def day_clock(t):
    return f"{lt(t).tm_mday}日 {clock(t)}"


def rel(t):
    dn = (NOW + OFF) // DAY - (t + OFF) // DAY
    if dn == 0:
        return "今天 " + clock(t)
    if dn == 1:
        return "昨天 " + clock(t)
    return day_clock(t)


def mmdd(t):
    g = lt(t)
    return f"{g.tm_mon:02d}-{g.tm_mday:02d}"


def dur(s):
    s = int(s)
    if s < 60:
        return "不到 1 分"
    h, m = divmod(s // 60, 60)
    if h == 0:
        return f"{m} 分"
    return f"{h} 小时" + (f" {m} 分" if m else "")


def lr(raws, total):
    s = sum(raws)
    if s <= 0:
        return [0] * len(raws)
    q = [r * total / s for r in raws]
    base = [math.floor(x) for x in q]
    rem = total - sum(base)
    order = sorted(range(len(q)), key=lambda i: (-(q[i] - base[i]), i))
    for i in order[:rem]:
        base[i] += 1
    return base


def r2(x):
    return round(x + 0.0, 2)


def half_up(x):
    return math.floor(x + 0.5 + 1e-9)


# ---- range building -----------------------------------------------------------------------------

NAMES = {"screen": "屏幕", "floor": "基本耗电（开着机就有）", "ui": "系统界面", "sys": "系统后台",
         "wifi": WIFI + "（粗估）", "other": "没算清的部分", "unrecorded": "没记到是谁用的"}
ICONS = contract.ICON_OF_KIND
EXPLAIN = {
    "screen": "背光和显示面板的耗电，按亮屏时长和当时的平均亮度估出来，是这几项里最准的。",
    "floor": "开着机就要花的电：内存、基带和各种芯片的待机电流，亮屏、熄屏各按一个固定功率算。",
    "ui": "桌面、状态栏、程序坞、控制中心和窗口合成（KWin）画界面用的电。",
    "sys": "系统服务和内核在后台用的电：网络、音频、传感器，还有我们自己的后台服务。",
    "wifi": "按收发的网络包数粗估的 " + WIFI + " 耗电，分不到具体应用。",
    "other": "实测的总耗电比各项估算加起来多出的部分。模型没覆盖到的东西（扬声器、刷新率等）都落在这里。",
    "unrecorded": "这段时间只知道电量掉了多少，不知道是谁用的：那会儿还没开始记录，或者飞行记录器没在记电流。",
    "apps_rest": "每个都不到 0.5% 的应用合在一起。",
}
COMP_NAMES = {"screen": "屏幕", "apps": "应用", "ui": "系统界面", "sys": "系统后台", "wifi": WIFI,
              "floor": "基本耗电", "other": "没算清", "unrecorded": "没记到"}
UI_PARTS = [("窗口合成（KWin）", 0.52), ("桌面（plasmashell）", 0.17), ("状态栏和程序坞", 0.14),
            ("X11 兼容层（Xwayland）", 0.10), ("控制中心", 0.07)]
SYS_PARTS = [("内核与中断", 0.41), ("网络（NetworkManager、wpa_supplicant）", 0.19),
             ("音频（PipeWire）", 0.14), ("我们自己的后台服务", 0.12), ("其他系统服务", 0.14)]
HINT = "亮度每调低 10%，亮屏每小时约少用 1.0% 电量"
STEAM_NOTE = "游戏和 Steam 本身合在一起算，下面按窗口列前台时长。"


def bucket_grid(key, start, end):
    if key == "24h":
        last = (end + OFF) // 3600 * 3600 - OFF
        return 3600, [last - 3600 * (23 - i) for i in range(24)]
    if key == "7d":
        last = (end + OFF) // DAY * DAY - OFF
        return DAY, [last - DAY * (6 - i) for i in range(7)]
    for bs in contract.SINCE_BUCKET_SIZES:
        first = (start + OFF) // bs * bs - OFF
        n = (end - 1 + OFF) // bs - (start + OFF) // bs + 1
        if n <= 48:
            return bs, [first + bs * i for i in range(n)]
    raise ValueError("range too long")


def intervals(rows, pred, start, end):
    out = []
    for r in rows:
        if not (start <= r["t"] < end) or not pred(r):
            continue
        a, b = r["t"], r["t"] + 60
        if out and out[-1][1] == a:
            out[-1][1] = b
        else:
            out.append([a, b])
    return out


def rdp(pts, n_max):
    if len(pts) <= n_max:
        return pts
    t0, t1 = pts[0][0], pts[-1][0]
    span = max(1, t1 - t0)
    xy = [((t - t0) / span, p / 100.0) for t, p in pts]

    def simplify(eps):
        keep = [False] * len(xy)
        keep[0] = keep[-1] = True
        stack = [(0, len(xy) - 1)]
        while stack:
            i, j = stack.pop()
            if j <= i + 1:
                continue
            (x1, y1), (x2, y2) = xy[i], xy[j]
            dx, dy = x2 - x1, y2 - y1
            norm = math.hypot(dx, dy) or 1e-12
            best, bi = -1.0, -1
            for k in range(i + 1, j):
                x0, y0 = xy[k]
                d = abs(dy * x0 - dx * y0 + x2 * y1 - y2 * x1) / norm
                if d > best:
                    best, bi = d, k
            if best > eps:
                keep[bi] = True
                stack.append((i, bi))
                stack.append((bi, j))
        return [p for p, k in zip(pts, keep) if k]

    eps = 0.0005
    out = simplify(eps)
    while len(out) > n_max:
        eps *= 1.4
        out = simplify(eps)
    return out


def curve(rows, start, end):
    pts = []
    last_int = None
    by_t = {r["t"]: r for r in rows}
    for r in rows:
        if r["gap"] or not (start <= r["t"] <= end):
            continue
        v = r["pct1"]
        iv = math.floor(v + 1e-9)
        if last_int is None or iv != last_int:
            pts.append((r["t"] + 60 if r["t"] + 60 <= end else r["t"], round(v, 1)))
            last_int = iv
    first = by_t.get(start)
    p0 = round(first["pct0"], 1) if first else pts[0][1]
    pts = [(start, p0)] + [p for p in pts if start < p[0] < end]
    last = by_t.get(end - 60)
    pts.append((end, round(last["pct1"], 1)))
    pts = rdp(pts, 400)
    return [[int(t), max(0.0, min(100.0, p))] for t, p in pts]


def build_range(key, rows, start, end, sc, state_override=None):
    span_rows = [r for r in rows if start <= r["t"] < end]
    ledger_from = sc["ledger_from"]
    covered_from = sc.get("covered_from", ledger_from)
    degraded = sc.get("degraded", [])

    def known(r):
        # the screen state: from the ledger's first snapshot on
        return r["t"] >= ledger_from

    def is_deg(r):
        return in_any(r["t"], degraded)

    def dis(r):
        return not r["gap"] and not r["plug"]

    def covered(r):
        # itemised: after the first covered step (covered_from; the first run has only its start snapshot)
        return dis(r) and r["t"] >= covered_from and not is_deg(r)

    on_s = sum(60 for r in span_rows if dis(r) and known(r) and r["on"])
    off_s = sum(60 for r in span_rows if dis(r) and known(r) and not r["on"])
    charger_s = sum(60 for r in span_rows if r["plug"])
    gap_s = sum(60 for r in span_rows if r["gap"])
    uncovered_s = sum(60 for r in span_rows if dis(r) and not covered(r))
    bands = {
        "on": intervals(rows, lambda r: r["on"] and known(r), start, end),
        "charger": intervals(rows, lambda r: r["plug"], start, end),
        "gap": intervals(rows, lambda r: r["gap"], start, end),
        "uncovered": intervals(rows, lambda r: dis(r) and not covered(r), start, end),
    }
    bs, bt = bucket_grid(key, start, end)

    def bidx(t):
        i = (t - bt[0]) // bs
        return max(0, min(len(bt) - 1, i))

    used_raw = sum(sum(r["drain"].values()) for r in span_rows if dis(r))
    energies = {}
    buckets = {}
    fg_min, alive_t, cpu, gpu, wakes, windows = {}, {}, {}, {}, {}, {}
    fgE, offE = {}, {}
    unrec = 0.0
    unrec_b = [0.0] * len(bt)
    on_cov = off_cov = 0
    for r in span_rows:
        if not dis(r):
            continue
        tot = sum(r["drain"].values())
        b = bidx(r["t"])
        if not covered(r):
            unrec += tot
            unrec_b[b] += tot
            continue
        if r["on"]:
            on_cov += 1
        else:
            off_cov += 1
        for k, v in r["drain"].items():
            energies[k] = energies.get(k, 0) + v
            buckets.setdefault(k, [0.0] * len(bt))[b] += v
            if k.startswith("app:"):
                name = k[4:]
                if name != "#closed" and r["fg"] == name:
                    fgE[k] = fgE.get(k, 0) + APPS[name]["fg"]
                if not r["on"]:
                    offE[k] = offE.get(k, 0) + v
        for name in r["alive"]:
            k = "app:" + name
            a = APPS[name]
            alive_t.setdefault(k, set()).add(r["t"])
            if r["fg"] == name:
                fg_min[k] = fg_min.get(k, 0) + 1
                cpu[k] = cpu.get(k, 0) + a["cpu"] * 60
                gpu[k] = gpu.get(k, 0) + a["gpu"] * 60
                if r["window"]:
                    windows.setdefault(k, {}).setdefault(r["window"], 0)
                    windows[k][r["window"]] += 60
            else:
                cpu[k] = cpu.get(k, 0) + a["cpu_bg"] * (60 if r["on"] else 20)
            if not r["on"]:
                wakes[k] = wakes.get(k, 0) + a["wk"] * 60
        if "app:#closed" in r["drain"]:
            alive_t.setdefault("app:#closed", set()).add(r["t"])
            cpu["app:#closed"] = cpu.get("app:#closed", 0) + 0.6
            if not r["on"]:
                wakes["app:#closed"] = wakes.get("app:#closed", 0) + 60 * 4
    used_raw_r = r2(used_raw)
    used_pct = half_up(used_raw_r)
    itemised = used_raw - unrec
    coverage = round(itemised / used_raw, 3) if used_raw > 0 else 0.0

    # --- state
    if state_override:
        state = state_override
    elif on_cov * 60 + off_cov * 60 < contract.MIN_SPLIT_S:
        state = "empty"
    elif uncovered_s >= contract.MIN_SPLIT_S:
        state = "partial"
    else:
        state = "ok"

    items = []
    if state in ("ok", "partial"):
        for k in ("screen", "floor", "ui", "sys", "wifi", "other"):
            if energies.get(k, 0) <= 0:
                continue
            e = energies[k]
            it = base_item(k, k, NAMES[k], ICONS[k], e, buckets[k])
            it["explain"] = EXPLAIN[k]
            if k == "screen":
                it["hint"] = HINT
            if k == "ui":
                it["parts"] = [[n, r2(e * f)] for n, f in UI_PARTS]
                it["cpu_s"] = int(on_cov * 60 * 0.11 + off_cov * 60 * 0.004)
                it["gpu_s"] = int(on_cov * 60 * 0.05)
                it["wake_off_n"] = int(off_cov * 60 * 4)
            if k == "sys":
                it["parts"] = [[n, r2(e * f)] for n, f in SYS_PARTS]
                it["cpu_s"] = int((on_cov + off_cov) * 60 * 0.03)
                it["gpu_s"] = None
                it["wake_off_n"] = int(off_cov * 60 * 95)
            items.append(it)
        apps = []
        for k, e in energies.items():
            if not k.startswith("app:"):
                continue
            name = k[4:]
            if name == "#closed":
                it = base_item("app", "app:#closed", "已关闭的程序（认不出）",
                               "application-x-executable", e, buckets[k])
            else:
                a = APPS[name]
                it = base_item("app", "app:" + a["id"], a["name"], a["icon"], e, buckets[k])
            fe = fgE.get(k, 0.0)
            it["_fg"], it["_bg"], it["_off"] = fe, e - fe, offE.get(k, 0.0)
            it["_alive"] = alive_t.get(k, set())
            it["fg_s"] = fg_min.get(k, 0) * 60
            it["bg_s"] = (len(it["_alive"]) - fg_min.get(k, 0)) * 60
            it["cpu_s"] = int(cpu.get(k, 0))
            it["gpu_s"] = int(gpu.get(k, 0)) if name != "#closed" else None
            it["wake_off_n"] = int(wakes.get(k, 0)) if wakes.get(k) else None
            if k in windows:
                it["windows"] = sorted(([n, int(s)] for n, s in windows[k].items()),
                                       key=lambda p: -p[1])
                it["note"] = STEAM_NOTE
            apps.append(it)
        small = [a for a in apps if a["pct_raw"] < contract.APPS_MIN_PCT]
        if len(small) >= 2:
            apps = [a for a in apps if a not in small]
            e = sum(a["pct_raw"] for a in small)
            rest = base_item("apps_rest", "apps_rest", f"其他应用（{len(small)} 个）",
                             ICONS["apps_rest"], e,
                             [sum(x) for x in zip(*[a["buckets"] for a in small])])
            rest["pct_raw"] = r2(sum(a["pct_raw"] for a in small))
            rest["parts"] = [[a["name"], a["pct_raw"]] for a in
                             sorted(small, key=lambda a: -a["pct_raw"])]
            rest["explain"] = EXPLAIN["apps_rest"]
            for f in ("fg_s", "cpu_s"):
                rest[f] = sum(a[f] or 0 for a in small)
            # as the report does: open but not in front for the rest of the union of the members' open time
            rest["bg_s"] = len(set().union(*(a["_alive"] for a in small))) * 60 - rest["fg_s"]
            g = [a["gpu_s"] for a in small if a["gpu_s"] is not None]
            rest["gpu_s"] = sum(g) if g else None
            w = [a["wake_off_n"] for a in small if a["wake_off_n"] is not None]
            rest["wake_off_n"] = sum(w) if w else None
            rest["_fg"] = sum(a["_fg"] for a in small)
            rest["_bg"] = sum(a["_bg"] for a in small)
            rest["_off"] = sum(a["_off"] for a in small)
            apps.append(rest)
        items += apps
        if state == "partial":
            it = base_item("unrecorded", "unrecorded", NAMES["unrecorded"], ICONS["unrecorded"],
                           unrec, unrec_b)
            it["explain"] = EXPLAIN["unrecorded"]
            items.append(it)
        # make sum(pct_raw) == used_pct_raw exactly after rounding: nudge the largest item
        diff = r2(used_raw_r - sum(i["pct_raw"] for i in items))
        items.sort(key=lambda i: (-i["pct_raw"], i["id"]))
        items[0]["pct_raw"] = r2(items[0]["pct_raw"] + diff)
        pcts = lr([i["pct_raw"] for i in items], used_pct)
        for it, p in zip(items, pcts):
            it["pct"] = p
            if it["kind"] in ("app", "apps_rest"):
                fr, br, of = it.pop("_fg"), it.pop("_bg"), it.pop("_off")
                it.pop("_alive", None)
                scale = it["pct_raw"] / (fr + br) if fr + br > 0 else 0
                fr, br, of = r2(fr * scale), r2(br * scale), r2(of * scale)
                br = r2(it["pct_raw"] - fr)
                of = min(of, br)
                it["split_raw"] = {"fg": fr, "bg": br, "off": of}
                f_int, b_int = lr([fr, br], p) if p else (0, 0)
                o_int = min(b_int, half_up(of * p / it["pct_raw"])) if it["pct_raw"] else 0
                it["split"] = {"fg": f_int, "bg": b_int, "off": o_int}
            # rescale buckets so they sum to the (possibly nudged) pct_raw
            s = sum(it["buckets"])
            if s > 0:
                it["buckets"] = [round(x * it["pct_raw"] / s, 3) for x in it["buckets"]]
    comp = []
    if items:
        acc = {}
        for it in items:
            ck = contract.COMP_OF_ITEM[it["kind"]]
            acc[ck] = acc.get(ck, 0) + it["pct_raw"]
        kinds = [k for k in contract.COMP_KINDS if acc.get(k, 0) > 0]
        raws = [r2(acc[k]) for k in kinds]
        for k, raw, p in zip(kinds, raws, lr(raws, used_pct)):
            comp.append({"kind": k, "name": COMP_NAMES[k], "pct": p, "pct_raw": raw,
                         "role": contract.ROLE_OF_COMP[k]})

    # as ranges.py does: the first itemised minute when there is unitemised time before it; with nothing
    # itemised, the minute the screen state becomes known (the ledger's first snapshot), or the end
    first = next((r["t"] for r in span_rows if covered(r)), None)
    if first is None:
        first = next((r["t"] for r in span_rows if not r["gap"] and known(r)), end)
    late = first > start and any(dis(r) and not covered(r) and r["t"] + 60 <= first for r in span_rows)
    data_from = min(end, first) if late else None
    doc = {
        "key": key, "state": state, "start": start, "end": end,
        "title": "", "sub": "",
        "used_pct": used_pct, "used_pct_raw": used_raw_r,
        "on_s": on_s, "off_s": off_s, "charger_s": charger_s, "gap_s": gap_s,
        "uncovered_s": uncovered_s, "coverage": coverage if state != "all_charger" else 0.0,
        "data_from": data_from,
        "data_from_text": f"从 {day_clock(data_from)} 起才有按应用的记录" if data_from else None,
        "brightness_hint_pct_h": 1.0 if on_s else None,
        "model_high_segments": 0, "unknown_time_boots": 0,
        "curve": curve(rows, start, end), "bands": bands,
        "bucket_s": bs, "bucket_t": bt,
        "items": items, "composition": comp, "banners": [], "empty": None,
        "footnote": "估算 · 未校准",
    }
    return doc


def base_item(kind, iid, name, icon, e, bk):
    return {"id": iid, "kind": kind, "name": name, "icon": icon,
            "role": contract.ROLE_OF_KIND[kind], "pct": 0, "pct_raw": r2(e),
            "fg_s": None, "bg_s": None, "cpu_s": None, "gpu_s": None, "wake_off_n": None,
            "split": None, "split_raw": None, "buckets": [round(x, 3) for x in bk],
            "windows": [], "parts": [], "explain": None, "hint": None, "note": None}


def remain(rows, pct_now):
    """model.remain: the % drop over the discharge minutes of the last 24 h (charger and gap left out)."""
    dis = [r for r in rows if NOW - DAY <= r["t"] < NOW and not r["gap"] and not r["plug"]]
    used = sum(sum(r["drain"].values()) for r in dis)
    if len(dis) * 60 < 3600 or used <= 0:
        return None
    return {"h": round(pct_now / (used / (len(dis) / 60.0)), 1), "basis_h": 24}


def doc_top(rows, sc, ranges, bat):
    return {
        "v": 1, "now": NOW, "tz_offset_min": TZ, "took_ms": sc.get("took_ms", 640),
        "rec": sc["rec"], "battery": bat,
        "coeffs": {"version": 1, "calibrated": False, "date": "2026-10-30", "source": "package"},
        "remain": None if bat["plugged"] else remain(rows, bat["pct"]),
        "ranges": ranges, "diag": sc["diag"],
    }


def banner(kind, text):
    return {"kind": kind, "level": contract.BANNER_LEVEL[kind], "text": text}


# ---- scenarios ---------------------------------------------------------------------------------

def pattern_week(d):
    return DAY_A if d % 2 == 1 else DAY_B


BASE_PLUGS = [(L(10, 28, 23, 30), L(10, 29, 7, 40))]


def base_sc(**kw):
    sc = dict(t0=L(10, 21, 7, 40), day0=21, pct0=100.0, pattern=pattern_week, auto=True,
              plugs=list(BASE_PLUGS), ledger_from=L(10, 20, 9, 0), closed_until=L(10, 25, 12, 0),
              rec={"running": True, "degraded": False, "since": L(10, 20, 9, 0),
                   "last_write_age_s": 41, "fg_log": True, "clock_unsynced": False},
              diag={"unexplained_median_7d": 0.064, "floor_off_learned_mw": 141.0,
                    "floor_off_model_mw": 147.0, "coeff_age_days": 0, "ledger_bytes": 1532416,
                    "ledger_newest_age_s": 41, "energy_age_s": 4, "segments_flagged_7d": 1})
    sc.update(kw)
    return sc


def charges(rows, start, end):
    """Range.charges: plug-ins with charger time in [start, end); two with nothing but gap between them are one
    (a reboot on the charger splits the band, not the plug-in)."""
    seq = ["p" if r["plug"] else "d" for r in rows if start <= r["t"] < end and not r["gap"]]
    return sum(1 for i, s in enumerate(seq) if s == "p" and (i == 0 or seq[i - 1] != "p"))


def finish_titles(doc, rows, unplug, mid_plugs=0, just=False):
    rs = doc["ranges"]
    sf = rs["since_full"]
    sf["title"] = "自上次充满"
    if just:
        sf["sub"] = f"刚充满：{clock(unplug)} 拔下"
    else:
        sub = f"上次充满：{rel(unplug)}，之后用掉 {sf['used_pct']}%"
        if mid_plugs:
            sub += f"，中间插电 {mid_plugs} 次"
        sf["sub"] = sub
    rs["24h"]["title"] = "过去 24 小时"
    n24 = charges(rows, rs["24h"]["start"], rs["24h"]["end"])
    rs["24h"]["sub"] = f"过去 24 小时用掉 {rs['24h']['used_pct']}%" + \
        (f"，充电 {n24} 次" if n24 else "")
    r7 = rs["7d"]
    r7["title"] = "过去 7 天"
    n7 = charges(rows, r7["start"], r7["end"])
    r7["sub"] = f"过去 7 天一共用掉 {r7['used_pct']}%（约 {r7['used_pct_raw'] / 100:.1f} 次满电），充电 {n7} 次"


def charger_banner(bat):
    if not bat["plugged"]:
        return None
    if bat["status"] == "full":
        return banner("charger_now", "已充满 · 正在用充电器")
    if bat["status"] == "charging":
        return banner("charger_now", "正在充电")
    return banner("charger_now", "插着充电器 · 没在充电（停在上限）")


def gen_ok():
    sc = base_sc()
    rows = simulate(sc)
    unplug = L(10, 29, 7, 40)
    pct_now = int(round(rows[-1]["pct1"]))
    bat = {"pct": pct_now, "status": "discharging", "plugged": False, "health_pct": 93, "cycles": 18}
    ranges = {
        "since_full": build_range("since_full", rows, unplug, NOW, sc),
        "24h": build_range("24h", rows, NOW - DAY, NOW, sc),
        "7d": build_range("7d", rows, NOW - 7 * DAY, NOW, sc),
    }
    ranges["since_full"]["model_high_segments"] = 1
    ranges["since_full"]["footnote"] = "估算 · 未校准 · 有 1 段估算偏高，已按实测压低"
    ranges["7d"]["model_high_segments"] = 1
    ranges["7d"]["footnote"] = "估算 · 未校准 · 有 1 段估算偏高，已按实测压低"
    doc = doc_top(rows, sc, ranges, bat)
    finish_titles(doc, rows, unplug)
    return doc, rows


def gen_just_full():
    plugs = list(BASE_PLUGS) + [(L(10, 29, 23, 30), L(10, 30, 8, 6))]
    sc = base_sc(plugs=plugs, extra_on=[(L(10, 30, 8, 6), L(10, 30, 8, 11), "chrome")])
    # morning chrome session moved after the unplug: drop DAY pattern sessions on the 30th
    sc["pattern"] = lambda d: [] if d == 30 else pattern_week(d)
    rows = simulate(sc)
    unplug = L(10, 30, 8, 6)
    bat = {"pct": int(round(rows[-1]["pct1"])), "status": "discharging", "plugged": False,
           "health_pct": 93, "cycles": 18}
    ranges = {
        "since_full": build_range("since_full", rows, unplug, NOW, sc, state_override="just_full"),
        "24h": build_range("24h", rows, NOW - DAY, NOW, sc),
        "7d": build_range("7d", rows, NOW - 7 * DAY, NOW, sc),
    }
    sf = ranges["since_full"]
    sf["items"], sf["composition"] = [], []
    sf["empty"] = {"title": "刚充满", "text": "拔掉充电器后开始统计这一轮。", "action": "show_24h"}
    doc = doc_top(rows, sc, ranges, bat)
    finish_titles(doc, rows, unplug, just=True)
    return doc, rows


def gen_empty():
    since = L(10, 30, 8, 7)
    sc = base_sc(ledger_from=since, closed_until=None,
                 rec={"running": True, "degraded": False, "since": since, "last_write_age_s": 3,
                      "fg_log": True, "clock_unsynced": False},
                 diag={"unexplained_median_7d": None, "floor_off_learned_mw": None,
                       "floor_off_model_mw": 147.0, "coeff_age_days": 0, "ledger_bytes": 11873,
                       "ledger_newest_age_s": 3, "energy_age_s": 4, "segments_flagged_7d": 0})
    rows = simulate(sc)
    unplug = L(10, 29, 7, 40)
    bat = {"pct": int(round(rows[-1]["pct1"])), "status": "discharging", "plugged": False,
           "health_pct": 93, "cycles": 18}
    ranges = {k: build_range(k, rows, s, NOW, sc) for k, s in
              (("since_full", unplug), ("24h", NOW - DAY), ("7d", NOW - 7 * DAY))}
    for r in ranges.values():
        assert r["state"] == "empty", r["state"]
        r["empty"] = {"title": "刚开始记录",
                      "text": f"从 {day_clock(since)} 起记各应用的用电，用一阵子再来看。",
                      "action": None}
        r["brightness_hint_pct_h"] = None
    doc = doc_top(rows, sc, ranges, bat)
    finish_titles(doc, rows, unplug)
    return doc, rows


def gen_first_run():
    """The recorder's first minutes: one start snapshot (screen off) and no covered step yet. Everything is
    unitemised and nothing is a 亮屏 band; data_from marks the snapshot, before which the screen state is unknown
    (the page must not draw that as 熄屏)."""
    since = NOW - 120
    sc = base_sc(ledger_from=since, covered_from=NOW + 60, closed_until=None, page_on=False,
                 pattern=lambda d: [] if d == 30 else pattern_week(d),
                 rec={"running": True, "degraded": False, "since": since, "last_write_age_s": 120,
                      "fg_log": True, "clock_unsynced": False},
                 diag={"unexplained_median_7d": None, "floor_off_learned_mw": None,
                       "floor_off_model_mw": 147.0, "coeff_age_days": 0, "ledger_bytes": 2240,
                       "ledger_newest_age_s": 120, "energy_age_s": 4, "segments_flagged_7d": 0})
    rows = simulate(sc)
    unplug = L(10, 29, 7, 40)
    bat = {"pct": int(round(rows[-1]["pct1"])), "status": "discharging", "plugged": False,
           "health_pct": 93, "cycles": 18}
    ranges = {k: build_range(k, rows, s, NOW, sc) for k, s in
              (("since_full", unplug), ("24h", NOW - DAY), ("7d", NOW - 7 * DAY))}
    for r in ranges.values():
        assert (r["state"], r["bands"]["on"], r["data_from"]) == ("empty", [], since), r["state"]
        r["empty"] = {"title": "刚开始记录",
                      "text": f"从 {day_clock(since)} 起记各应用的用电，用一阵子再来看。",
                      "action": None}
        r["brightness_hint_pct_h"] = None
    doc = doc_top(rows, sc, ranges, bat)
    finish_titles(doc, rows, unplug)
    return doc, rows


def gen_partial():
    since = L(10, 29, 10, 20)
    gaps = [(L(10, 29, 13, 10), L(10, 29, 17, 10))]
    deg = [(L(10, 29, 21, 0), L(10, 29, 22, 5))]
    sc = base_sc(ledger_from=since, gaps=gaps, degraded=deg, closed_until=None,
                 rec={"running": True, "degraded": False, "since": since, "last_write_age_s": 52,
                      "fg_log": True, "clock_unsynced": False},
                 diag={"unexplained_median_7d": 0.081, "floor_off_learned_mw": None,
                       "floor_off_model_mw": 147.0, "coeff_age_days": 0, "ledger_bytes": 198322,
                       "ledger_newest_age_s": 52, "energy_age_s": 6, "segments_flagged_7d": 0})
    rows = simulate(sc)
    unplug = L(10, 29, 7, 40)
    bat = {"pct": int(round(rows[-1]["pct1"])), "status": "discharging", "plugged": False,
           "health_pct": 93, "cycles": 18}
    ranges = {k: build_range(k, rows, s, NOW, sc) for k, s in
              (("since_full", unplug), ("24h", NOW - DAY), ("7d", NOW - 7 * DAY))}
    for r in ranges.values():
        assert r["state"] == "partial", r["state"]
        deg_s = sum(min(b, r["end"]) - max(a, r["start"]) for a, b in deg
                    if a < r["end"] and r["start"] < b)
        r["banners"] = [
            banner("degraded", f"有 {dur(deg_s)}只按电量百分比粗算（飞行记录器没在记电流），这几段不分应用"),
            banner("gap", f"有 {dur(r['gap_s'])}没记录（关机或重启）"),
        ]
    doc = doc_top(rows, sc, ranges, bat)
    finish_titles(doc, rows, unplug)
    return doc, rows


def gen_degraded():
    deg_from = L(10, 29, 7, 0)
    sc = base_sc(degraded=[(deg_from, NOW + 60)],
                 rec={"running": True, "degraded": True, "since": L(10, 20, 9, 0),
                      "last_write_age_s": 1203, "fg_log": True, "clock_unsynced": False},
                 diag={"unexplained_median_7d": 0.071, "floor_off_learned_mw": 139.0,
                       "floor_off_model_mw": 147.0, "coeff_age_days": 0, "ledger_bytes": 1498001,
                       "ledger_newest_age_s": 1203, "energy_age_s": None,
                       "segments_flagged_7d": 1})
    rows = simulate(sc)
    unplug = L(10, 29, 7, 40)
    bat = {"pct": int(round(rows[-1]["pct1"])), "status": "discharging", "plugged": False,
           "health_pct": 93, "cycles": 18}
    ranges = {k: build_range(k, rows, s, NOW, sc) for k, s in
              (("since_full", unplug), ("24h", NOW - DAY), ("7d", NOW - 7 * DAY))}
    for k in ("since_full", "24h"):
        r = ranges[k]
        assert r["state"] == "empty", (k, r["state"])
        r["empty"] = {"title": "没有分项记录",
                      "text": "这段时间飞行记录器没在记电流，只能按电量百分比粗算总量，分不出应用。",
                      "action": None}
        r["banners"] = [banner("degraded", "飞行记录器没在记电流：总耗电按电量百分比粗算，不分应用")]
    r7 = ranges["7d"]
    assert r7["state"] == "partial", r7["state"]
    r7["banners"] = [banner("degraded", f"有 {dur(NOW - deg_from)}只按电量百分比粗算（飞行记录器没在记电流），这几段不分应用")]
    r7["model_high_segments"] = 1
    r7["footnote"] = "估算 · 未校准 · 有 1 段估算偏高，已按实测压低"
    doc = doc_top(rows, sc, ranges, bat)
    finish_titles(doc, rows, unplug)
    return doc, rows


def desk_pattern(d):
    return [("09:20", "11:45", "chrome"), ("13:30", "15:10", "claude"), ("15:10", "15:40", "dolphin"),
            ("16:00", "17:55", "chrome"), ("20:30", "21:40", "wiliwili")]


def gen_all_charger():
    since = L(10, 21, 9, 0)
    sc = dict(t0=since, day0=21, pct0=80.0, pattern=desk_pattern, auto=False,
              plugs=[(since, NOW + 60, 80)], ledger_from=since, bypass_wiggle=True,
              rec={"running": True, "degraded": False, "since": since, "last_write_age_s": 37,
                   "fg_log": True, "clock_unsynced": False},
              diag={"unexplained_median_7d": None, "floor_off_learned_mw": None,
                    "floor_off_model_mw": 147.0, "coeff_age_days": 0, "ledger_bytes": 1710555,
                    "ledger_newest_age_s": 37, "energy_age_s": 5, "segments_flagged_7d": 0})
    rows = simulate(sc)
    bat = {"pct": 80, "status": "not_charging", "plugged": True, "health_pct": 93, "cycles": 18}
    ranges = {k: build_range(k, rows, s, NOW, sc, state_override="all_charger") for k, s in
              (("since_full", since), ("24h", NOW - DAY), ("7d", NOW - 7 * DAY))}
    for r in ranges.values():
        r["items"], r["composition"] = [], []
        r["empty"] = {"title": "一直插着充电器",
                      "text": "这段时间一直插着充电器，电池没怎么用，所以不分应用。", "action": None}
        r["banners"] = [charger_banner(bat)]
        r["brightness_hint_pct_h"] = None
    doc = doc_top(rows, sc, ranges, bat)
    sf = ranges["since_full"]
    sf["title"] = f"自 {mmdd(since)} 起（之前没有记录）"
    sf["sub"] = f"{mmdd(since)} 起没充满过，一直插着充电器"
    ranges["24h"]["title"] = "过去 24 小时"
    ranges["24h"]["sub"] = "过去 24 小时一直插着充电器"
    ranges["7d"]["title"] = "过去 7 天"
    ranges["7d"]["sub"] = "过去 7 天一直插着充电器"
    return doc, rows


ICONS_IN_CAPTURE = None


def _scalar(x):
    return x is None or isinstance(x, (str, int, float, bool))


def dump(o, ind=0):
    """JSON with one line per object member; arrays of scalars (and arrays of short scalar
    arrays, e.g. curve points) stay compact so a reviewer can read the files."""
    pad = " " * ind
    if _scalar(o):
        return json.dumps(o, ensure_ascii=False)
    if isinstance(o, list):
        if all(_scalar(x) for x in o):
            return json.dumps(o, ensure_ascii=False, separators=(",", ":"))
        if all(isinstance(x, list) and all(_scalar(y) for y in x) for x in o):
            rows = [json.dumps(x, ensure_ascii=False, separators=(",", ":")) for x in o]
            lines, cur = [], ""
            for r in rows:
                if cur and len(cur) + len(r) + 1 > 96:
                    lines.append(cur)
                    cur = ""
                cur = cur + ("," if cur else "") + r
            if cur:
                lines.append(cur)
            if len(lines) == 1:
                return "[" + lines[0] + "]"
            return "[\n" + pad + " " + (",\n" + pad + " ").join(lines) + "\n" + pad + "]"
        inner = (",\n" + pad + " ").join(dump(x, ind + 1) for x in o)
        return "[\n" + pad + " " + inner + "\n" + pad + "]"
    parts = [json.dumps(k, ensure_ascii=False) + ": " + dump(v, ind + 1) for k, v in o.items()]
    if not parts:
        return "{}"
    return "{\n" + pad + " " + (",\n" + pad + " ").join(parts) + "\n" + pad + "}"


FILES = (("ok", gen_ok), ("just_full", gen_just_full), ("empty", gen_empty), ("first_run", gen_first_run),
         ("partial", gen_partial), ("all_charger", gen_all_charger), ("degraded", gen_degraded))


def render():
    """{name: file text} for every canned report."""
    return {name: dump(fn()[0]) + "\n" for name, fn in FILES}


def main():
    global ICONS_IN_CAPTURE
    if sys.argv[1:] == ["--check"]:
        stale = [n for n, text in render().items()
                 if not (OUT / (n + ".json")).is_file()
                 or (OUT / (n + ".json")).read_text(encoding="utf-8") != text]
        print("gen_batpage.py: " + ("stale: " + " ".join(stale) if stale else "all files up to date"))
        return 1 if stale else 0
    cap = sys.argv[1] if len(sys.argv) > 1 else None
    if cap:
        ICONS_IN_CAPTURE = set()
        for line in open(cap, encoding="utf-8"):
            if line.startswith("Icon="):
                ICONS_IN_CAPTURE.add(line[5:].strip())
    bad = 0
    for name, fn in FILES:
        doc, rows = fn()
        low = min(r["pct1"] for r in rows)
        errs = contract.validate(doc)
        icons = {it["icon"] for r in doc["ranges"].values() for it in r["items"]
                 if it["kind"] == "app" and it["icon"]}
        missing = sorted(i for i in icons if ICONS_IN_CAPTURE is not None
                         and i not in ICONS_IN_CAPTURE and i != "application-x-executable")
        print(f"{name}: errors={len(errs)} min_pct={low:.1f} now_pct={doc['battery']['pct']} "
              + " ".join(f"{k}:{r['state']}/{r['used_pct']}%/{len(r['items'])}it/{len(r['curve'])}pt"
                         for k, r in doc["ranges"].items()) + (f" MISSING ICONS {missing}" if missing else ""))
        for e in errs[:15]:
            print("   ", e)
        bad += len(errs) + len(missing)
        with open(OUT / (name + ".json"), "w", encoding="utf-8", newline="\n") as f:
            f.write(dump(doc) + "\n")
        assert json.loads(dump(doc)) == doc
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
