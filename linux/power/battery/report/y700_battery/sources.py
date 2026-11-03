"""Raw report inputs, live or replayed from a --from capture (DESIGN.md section 6b.b).

This and config.py are the only modules that read system files or run programs; everything downstream takes the
types.Sources built here, so the unit tests and a --from replay run the same code as the tablet.

Live mode reads exactly the 6b.b table and nothing else - in particular never charge_counter / power_now (a firmware
round trip each), nothing under /sys/kernel/debug. busctl and journalctl get SUBPROC_TIMEOUT_S each; a timeout or a
failure means "this data is missing", never an error. --from DIR reads only the files the 6b.b layout names; the human-
only files of a capture (upower-files.txt with Bluetooth names, upower-props.json ...) are never opened.
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from typing import Optional

from . import apps, journal, ledger, upower
from .types import BatStatus, LiveBattery, Sources

SUBPROC_TIMEOUT_S = 5.0
KEEP_DAYS = 40
UPOWER_SPAN_S = KEEP_DAYS * 86400          # 3456000, as 6b.b writes it
UPOWER_DIR = "/var/lib/upower"
SUPPLY_DIR = "/sys/class/power_supply"
BAT_SUPPLY = "qcom-battmgr-bat"            # the recorder's battery (recorder/src/main.rs BAT)
FLIGHTREC_DIR = "/run/y700-flightrec"
BOOT_ID = "/proc/sys/kernel/random/boot_id"
RECORDER_COMM = "y700-batteryd"
BAT_KEYS = ("status", "capacity", "charge_full", "charge_full_design", "cycle_count", "model_name")
_STATUSES = ("charging", "discharging", "full", "not_charging", "unknown")


# ---------------------------------------------------------------------------------------------
# Small parsers (also used by the tests)
# ---------------------------------------------------------------------------------------------

def _read(path: str, limit: int = -1) -> Optional[str]:
    try:
        with open(path, encoding="utf-8", errors="replace", newline="") as f:
            return f.read(limit)
    except OSError:
        return None


def _int(s: Optional[str]) -> Optional[int]:
    try:
        return int(s.strip()) if s is not None else None
    except ValueError:
        return None


def parse_battery_txt(text: str) -> tuple[dict[str, str], list[int]]:
    """bp-capture's sys/battery.txt: key=value lines of the battery's sysfs files, plus
    /sys/class/power_supply/<supply>/online=N lines -> (values by key, online values). Optional <supply>/type and
    <supply>/scope lines of the same shape drop that supply's online when it is of type Battery or scope Device, as in
    live mode (_live_battery); a capture without them counts every online line."""
    kv: dict[str, str] = {}
    sup: dict[str, dict[str, str]] = {}
    for line in text.splitlines():
        k, eq, v = line.partition("=")
        if not eq:
            continue
        k, v = k.strip(), v.strip()
        d, _, leaf = k.rpartition("/")
        if k.startswith("/") and leaf in ("online", "type", "scope"):
            sup.setdefault(d, {})[leaf] = v
        elif k:
            kv[k] = v
    online: list[int] = []
    for p in sup.values():
        n = _int(p.get("online"))
        if n is not None and p.get("type") != "Battery" and p.get("scope") != "Device":
            online.append(n)
    return kv, online


def status_of(raw: Optional[str]) -> BatStatus:
    """sysfs status ("Not charging", "Full" ...) -> types.BatStatus"""
    s = (raw or "").strip().lower().replace(" ", "_")
    return s if s in _STATUSES else "unknown"  # type: ignore[return-value]


def live_battery(kv: dict[str, str], online: list[int]) -> LiveBattery:
    """types.LiveBattery from the battery's sysfs values and the other supplies' online flags"""
    st = status_of(kv.get("status"))
    model = (kv.get("model_name") or "").strip() or None
    return LiveBattery(pct=_int(kv.get("capacity")), status=st,
                       plugged=st in ("charging", "full", "not_charging") or any(n == 1 for n in online),
                       charge_full_uah=_int(kv.get("charge_full")),
                       charge_full_design_uah=_int(kv.get("charge_full_design")),
                       cycles=_int(kv.get("cycle_count")), model_name=model)


def energy_fields(text: Optional[str]) -> dict[str, str]:
    """The first line of flightrec's energy file as key -> value ("v1 boot=... t=... ...")"""
    if not text:
        return {}
    first = text.splitlines()[0].split() if text.splitlines() else []
    if not first or first[0] != "v1":
        return {}
    return dict(tok.split("=", 1) for tok in first[1:] if "=" in tok)


def energy_age(text: Optional[str], mono_now: Optional[float], boot8: Optional[str]) -> Optional[float]:
    """s since flightrec last wrote the energy file (its t= is CLOCK_MONOTONIC ms). None when unknown, or when the file
    is another boot's (tmpfs survives nothing, but a capture may mix)."""
    f = energy_fields(text)
    t = _int(f.get("t"))
    if t is None or mono_now is None:
        return None
    if boot8 and f.get("boot") and f["boot"] != boot8:
        return None
    return mono_now - t / 1000.0


def local_tz_offset_min(now: float) -> int:
    return int(time.localtime(now).tm_gmtoff // 60)


def state_dir_live(env: Optional[dict] = None, home: Optional[str] = None) -> str:
    """${XDG_STATE_HOME:-~/.local/state}/y700-battery; a relative XDG_STATE_HOME is invalid per the XDG spec and
    ignored, as the recorder and refresh-auto do"""
    env = os.environ if env is None else env
    home = os.path.expanduser("~") if home is None else home
    x = env.get("XDG_STATE_HOME", "")
    base = x if x and os.path.isabs(x) else os.path.join(home, ".local", "state")
    return os.path.join(base, "y700-battery")


def boot8_of(boot_id: Optional[str]) -> Optional[str]:
    if not boot_id:
        return None
    b = boot_id.replace("-", "").strip().lower()[:8]
    return b or None


# ---------------------------------------------------------------------------------------------
# Live
# ---------------------------------------------------------------------------------------------

def _run(argv: list[str]) -> Optional[str]:
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=SUBPROC_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace")


def _read_stable(path: str) -> Optional[str]:
    """flightrec pwrite()s the energy line in place: take it only when two reads agree (section 2), three tries"""
    prev = _read(path, 4096)
    for _ in range(3):
        cur = _read(path, 4096)
        if cur is None or cur == prev:
            return cur
        prev = cur
    return None


def _live_battery() -> tuple[LiveBattery, Optional[str]]:
    """(battery, its supply name). A supply whose scope reads Device is a peripheral's own (hid-<mac>-battery,
    ps-controller-battery-*, hidpp_battery_N ... all sort before qcom-) and is skipped entirely; no scope file means
    System. The battery is BAT_SUPPLY when it exists, as the recorder hardcodes it, else the first remaining supply of
    type Battery by name; online only from the remaining supplies that are not of type Battery. The page's readLive()
    follows the same rule."""
    try:
        names = sorted(os.listdir(SUPPLY_DIR))
    except OSError:
        names = []
    bat = BAT_SUPPLY if os.path.isdir(os.path.join(SUPPLY_DIR, BAT_SUPPLY)) else None
    online: list[int] = []
    for n in names:
        d = os.path.join(SUPPLY_DIR, n)
        if (_read(os.path.join(d, "scope")) or "").strip() == "Device":
            continue
        if (_read(os.path.join(d, "type")) or "").strip() == "Battery":
            if bat is None:
                bat = n
            continue
        v = _int(_read(os.path.join(d, "online")))
        if v is not None:
            online.append(v)
    kv: dict[str, str] = {}
    if bat is not None:
        for k in BAT_KEYS:
            v = _read(os.path.join(SUPPLY_DIR, bat, k))
            if v is not None:
                kv[k] = v.strip()
    return live_battery(kv, online), bat


def _gethistory(supply: str, kind: str) -> Optional[str]:
    obj = "/org/freedesktop/UPower/devices/battery_" + re.sub(r"[^A-Za-z0-9_]", "_", supply)
    return _run(["busctl", "--system", "--json=short", "call", "org.freedesktop.UPower", obj,
                 "org.freedesktop.UPower.Device", "GetHistory", "suu", kind, str(UPOWER_SPAN_S), "0"])


def _recorder_running() -> Optional[bool]:
    rt = os.environ.get("XDG_RUNTIME_DIR")
    if not rt:
        return None
    pid = _int(_read(os.path.join(rt, "y700-battery", "pid")))
    if pid is None or pid <= 0:
        return False
    return (_read("/proc/%d/comm" % pid) or "").strip() == RECORDER_COMM


def _live(now: Optional[float], tz_offset_min: Optional[int]) -> Sources:
    now = time.time() if now is None else now
    clk = getattr(time, "CLOCK_MONOTONIC", None)
    mono_now = time.clock_gettime(clk) if clk is not None else None
    boot_id = (_read(BOOT_ID) or "").strip() or None
    battery, supply = _live_battery()
    state = state_dir_live()
    dat: dict[str, str] = {}
    try:
        names = os.listdir(UPOWER_DIR)
    except OSError:
        names = []
    for n in upower.battery_dat_names(names, battery.model_name):
        text = _read(os.path.join(UPOWER_DIR, n))
        if text is not None:
            dat[n] = text
    jtext = _run(["journalctl", "--user", "-o", "json", "--no-pager", "MESSAGE_ID=" + journal.CONSUMED_ID,
                  "--since=@%d" % int(now - KEEP_DAYS * 86400)])
    energy = _read_stable(os.path.join(FLIGHTREC_DIR, "energy"))
    return Sources(now=now, tz_offset_min=local_tz_offset_min(now) if tz_offset_min is None else tz_offset_min,
                   from_dir=None, state_dir=state, boot_id=boot_id, mono_now=mono_now, battery=battery,
                   upower_charge_json=_gethistory(supply, "charge") if supply else None,
                   upower_rate_json=_gethistory(supply, "rate") if supply else None,
                   upower_dat=dat, journal_lines=jtext.splitlines() if jtext else [],
                   desktop=apps.scan(apps.app_dirs(os.path.expanduser("~"))),
                   energy=energy, energy_age_s=energy_age(energy, mono_now, boot8_of(boot_id)),
                   edge=_read(os.path.join(FLIGHTREC_DIR, "edge")), rec_running=_recorder_running(),
                   fg_dir_exists=os.path.isdir(state))


# ---------------------------------------------------------------------------------------------
# --from DIR
# ---------------------------------------------------------------------------------------------

def _newest_in_capture(state: str, charge: Optional[str], rate: Optional[str], dat: dict[str, str],
                       jlines: list[str]) -> Optional[float]:
    """--from without now.txt: the newest wall time anywhere in the capture (ledger, UPower, journal)"""
    cands = []
    w = ledger.newest_wall(ledger.read_dir(state))
    if w is not None:
        cands.append(w)
    for text in (charge, rate):
        if text:
            cands += [p.t for p in upower.parse_gethistory(text) if p.t >= upower.SANE_WALL]
    for text in dat.values():
        cands += [p.t for p in upower.parse_dat(text) if p.t >= upower.SANE_WALL]
    cands += [c.w for c in journal.parse(jlines) if c.w >= upower.SANE_WALL]
    return max(cands) if cands else None


def _from(d: str, now: Optional[float], tz_offset_min: Optional[int]) -> Sources:
    state = os.path.join(d, "state")
    if not os.path.isdir(state):
        raise FileNotFoundError("采集目录里没有 state/：" + state)
    bt = _read(os.path.join(d, "sys", "battery.txt"))
    if bt is None:
        raise FileNotFoundError("采集目录里没有 sys/battery.txt：" + os.path.join(d, "sys", "battery.txt"))
    battery = live_battery(*parse_battery_txt(bt))

    def opt(*p: str) -> Optional[str]:
        return _read(os.path.join(d, *p))

    boot_id = (opt("boot_id.txt") or "").strip() or None
    if boot_id is None:
        boots = [b.strip() for b in (opt("state", "boots.txt") or "").splitlines() if b.strip()]
        boot_id = boots[-1] if boots else None      # boot8 only: consumers take boot8_of() anyway
    mono = (opt("mono.txt") or "").strip()
    mono_now = float(mono) if mono else None
    charge, rate = opt("upower-charge.json"), opt("upower-rate.json")
    dat: dict[str, str] = {}
    ddir = os.path.join(d, "upower-dat")
    if os.path.isdir(ddir):
        for n in sorted(os.listdir(ddir)):
            if upower.dat_kind(n) is not None:
                text = _read(os.path.join(ddir, n))
                if text is not None:
                    dat[n] = text
    jtext = opt("journal-consumed.jsonl")
    jlines = jtext.splitlines() if jtext else []
    dtext = opt("desktop-files.txt")
    if now is None:
        nt = (opt("now.txt") or "").strip()
        now = float(nt) if nt else _newest_in_capture(state, charge, rate, dat, jlines)
        if now is None:
            now = time.time()       # an empty capture: nothing to replay against, so at least a valid clock
    if tz_offset_min is None:
        tz = (opt("tz-offset.txt") or "").strip()
        tz_offset_min = int(tz) if tz else local_tz_offset_min(now)
    rr = (opt("rec-running.txt") or "").strip()
    energy = opt("sys", "energy")
    return Sources(now=now, tz_offset_min=tz_offset_min, from_dir=d, state_dir=state, boot_id=boot_id,
                   mono_now=mono_now, battery=battery, upower_charge_json=charge, upower_rate_json=rate,
                   upower_dat=dat, journal_lines=jlines, desktop=apps.parse_capture(dtext) if dtext else [],
                   energy=energy, energy_age_s=energy_age(energy, mono_now, boot8_of(boot_id)),
                   edge=opt("sys", "edge"), rec_running=None if rr not in ("0", "1") else rr == "1",
                   fg_dir_exists=True)


def open_sources(from_dir: Optional[str], now: Optional[float], tz_offset_min: Optional[int]) -> Sources:
    """types.Sources, live (from_dir None) or from a capture directory (6b.b layout). now / tz_offset_min override."""
    if from_dir is not None:
        return _from(from_dir, now, tz_offset_min)
    return _live(now, tz_offset_min)
