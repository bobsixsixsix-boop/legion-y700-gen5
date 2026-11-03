"""Shared data types of the report (DESIGN.md section 6b.d).

This module is the seam between the three report agents:

- inputs  (sources.py, config.py, ledger.py, upower.py, journal.py, apps.py) produce these types,
- core    (ranges.py, model.py) consumes them and produces Range / RangeResult,
- output  (out.py, fit.py, cli.py) turns Report into JSON v1 / --text / --fit.

Changing a field here is a contract change: it goes through the main thread, never one agent alone.

Unit conventions, used in every docstring below:
- ``m``      CLOCK_MONOTONIC seconds (same clock as flightrec ``t=`` / 1000 and journal
             ``__MONOTONIC_TIMESTAMP`` / 1e6). Only comparable within one boot.
- ``t``/``w`` wall clock, Unix epoch seconds (float). ``w`` is the raw value the recorder wrote
             (may be unsynced); ``t`` is after ledger.assign_clocks() / upower.clean().
- ``_ms``    milliseconds, ``_us``/``usec`` microseconds, ``_ns`` nanoseconds, ``_s`` seconds.
- ``_mj``    millijoules, ``_j`` joules, ``_mw`` milliwatts.
- ``pct``    battery percent points (0..100 of the battery, not of a total).
- Everything is plain stdlib; no numpy outside fit.py.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal, Optional, Union

# ---------------------------------------------------------------------------------------------
# Ledger (ledger.py)
# ---------------------------------------------------------------------------------------------

UKey = tuple[str, int]
"""A cgroup identity that survives recorder restarts: (key, inode).

``key`` is the recorder's path form: ``"/"``, ``"/system.slice"``, ``"/user.slice"``,
``"/init.scope"``, ``"s/<unit>"``, ``"u/<slice>/<unit>"``, ``"u/init.scope"``,
``"l/session-<N>.scope"``. U-line ids are only valid until the next H line, so every
per-unit map in the parsed ledger is keyed by UKey, never by id.
"""

KERNEL = "-k"
"""Key used in wake maps for kernel threads (the recorder's ``"-k"`` entry)."""

WakeKey = Union[UKey, str]
"""A UKey, or the string KERNEL."""

FR_FIELDS = ("t", "n", "ton", "toff", "don", "doff", "dton", "dtoff", "chg", "tchg",
             "tz", "tzero", "gap", "bl", "lb", "lbt")
"""Field order of the flightrec accumulator as copied into S lines (``"fr"``)."""


@dataclass(slots=True)
class Fr:
    """flightrec accumulator values as written in one S line's ``fr`` (absolute within a boot).

    t, ton, toff, dton, dtoff, tchg, tz, tzero, gap, lbt: ms of CLOCK_MONOTONIC.
    don, doff, chg: mJ (discharge on / discharge off / charge, all >= 0).
    n: number of flightrec data lines integrated.
    bl: backlight level x ms (level 0..4095).
    lb: last valid battery reading, signed mW (positive = discharging).
    """
    t: int = 0
    n: int = 0
    ton: int = 0
    toff: int = 0
    don: int = 0
    doff: int = 0
    dton: int = 0
    dtoff: int = 0
    chg: int = 0
    tchg: int = 0
    tz: int = 0
    tzero: int = 0
    gap: int = 0
    bl: int = 0
    lb: int = 0
    lbt: int = 0


@dataclass(slots=True)
class Head:
    """One H line. ``units`` maps the U ids declared after this H (until the next H) to UKeys."""
    boot: str                      # dashed full boot id as written
    part: int                      # ledger part number of the file this H opens
    m: float                       # mono s
    w: float                       # raw wall s
    sync: bool
    why: Literal["start", "part"]  # "start" = recorder process start, "part" = 4 MiB rollover
    units: dict[int, UKey] = field(default_factory=dict)


@dataclass(slots=True)
class Snap:
    """One S line, with every U id already translated to a UKey via its Head.

    cg:   cpu.stat usage_usec, ABSOLUTE kernel counters. After a Head it holds every unit;
          otherwise only the units that changed since the previous S.
    gpu:  per unit (engine_ns, cycles), accumulated by the recorder PROCESS: it restarts from
          zero at every Head with why="start". In practice gpu[KWin] is Xwayland's (KWin's own
          fdinfo is unreadable and Xwayland lives in KWin's cgroup).
    wk:   voluntary+nonvoluntary switches since the previous thread scan (on/off edges and
          screen-off checkpoints only); None when the line had no wk. The first scan after a
          recorder start is only a baseline and is written without wk.
    cl:   per cluster [busy_ms, MHz*ms, t_ms], policy0 (cpu0-5) first, then policy6 (cpu6-7).
    ctx:  /proc/stat ctxt total. pkt: (rx, tx) packets total. x: (Xwayland pid, utime+stime ticks).
    st/cap: battery status string / capacity %, only on pw-edge snapshots.
    """
    why: str                       # start|on|off|pw|ck|req|term|once
    m: float
    w: float
    sync: bool
    head: int                      # index into Boot.heads of the H this line belongs to
    cov: bool                      # True = flightrec accumulator was alive (not degraded)
    dpms: Optional[int] = None     # 1 on, 0 off, None unknown
    pw: Optional[Literal["dis", "chg"]] = None
    edge: Optional[float] = None   # mono s of the edge this snapshot answers
    fr: Optional[Fr] = None
    cg: dict[UKey, int] = field(default_factory=dict)
    new: list[UKey] = field(default_factory=list)
    gone: list[UKey] = field(default_factory=list)
    cl: list[tuple[int, int, int]] = field(default_factory=list)
    ctx: Optional[int] = None
    pkt: Optional[tuple[int, int]] = None
    x: Optional[tuple[int, int]] = None
    gpu: dict[UKey, tuple[int, int]] = field(default_factory=dict)
    wk: Optional[dict[WakeKey, int]] = None
    st: Optional[str] = None
    cap: Optional[int] = None


@dataclass(slots=True)
class KStep:
    """One K line: the wall clock was stepped by ``step`` s at mono ``m`` (w is after the step)."""
    m: float
    w: float
    sync: bool
    src: str                       # "chrony" | "adjtimex"
    step: float


@dataclass(slots=True)
class FgEvent:
    """One line of fg-<boot8>[.<n>].log.

    kind "fg": a foreground change reported by refresh-auto; kind "start"/"stop": the
    START/STOP markers refresh-auto writes when it starts/stops (fg tracking is unknown after
    a STOP until the next START).
    new_usage / prev_usage: usage_usec of the new / previous foreground unit at that moment,
    None when the log has '-'.
    cgroup: full cgroup path with \\xNN un-escaped, None when '-'. key: the same in ledger key
    form (ledger.cgroup_key), None when unknown.
    cls: window class, may contain spaces, may be "".
    """
    m: float
    kind: Literal["fg", "start", "stop"]
    pid: int = 0
    covers: int = 0
    new_usage: Optional[int] = None
    prev_usage: Optional[int] = None
    cgroup: Optional[str] = None
    key: Optional[str] = None
    cls: str = ""


ClockKind = Literal["sync", "chained", "now", "none"]


@dataclass(slots=True)
class Boot:
    """Everything the ledger holds about one boot.

    clock (set by ledger.assign_clocks):
      "sync"    offset = median(w - m) over sync=1 lines of this boot;
      "chained" a past boot that never synced: placed right after the previous boot,
                marked 时间不明, excluded from 24h / 7d;
      "now"     the current boot is still unsynced: anchored so that mono_now maps to now
                (banner 时间未校准);
      "none"    not assigned yet / no lines.
    offset: epoch s to add to a mono s of this boot (t = m + offset).
    """
    boot8: str
    boot: Optional[str] = None      # dashed full id from the first H, if any
    heads: list[Head] = field(default_factory=list)
    snaps: list[Snap] = field(default_factory=list)
    ksteps: list[KStep] = field(default_factory=list)
    fg: list[FgEvent] = field(default_factory=list)
    bad_lines: int = 0              # unparsable / half lines skipped
    bytes: int = 0                  # size of this boot's b-*.jsonl and fg-*.log files
    clock: ClockKind = "none"
    offset: Optional[float] = None

    def t(self, m: float) -> float:
        """Epoch s of a mono s of this boot. Only valid after assign_clocks()."""
        if self.offset is None:
            raise ValueError("clock not assigned for boot " + self.boot8)
        return m + self.offset


@dataclass(slots=True)
class Ledger:
    """The parsed state dir. boots are oldest first, in boots.txt order (never by mtime)."""
    dir: str
    boots: list[Boot] = field(default_factory=list)
    bytes: int = 0                  # total size of all ledger + fg files


@dataclass(slots=True)
class FrDelta:
    """Accumulator deltas over one Step (same units as Fr); None on the Step when the
    accumulator went backwards (flightrec restarted in another boot / file reset)."""
    ton: int = 0
    toff: int = 0
    don: int = 0
    doff: int = 0
    dton: int = 0
    dtoff: int = 0
    chg: int = 0
    tchg: int = 0
    tz: int = 0
    tzero: int = 0
    gap: int = 0
    bl: int = 0


@dataclass(slots=True)
class Step:
    """The interval between two consecutive S lines of one boot (DESIGN section 4 区间).

    ma/mb: mono s; ta/tb: epoch s. State fields (dpms, pw, cov) describe the interval and are
    taken from the snapshot at its START (an edge snapshot is written right after the change).
    cpu: usage_usec delta per UKey; a unit first seen after the boot's first snapshot counts
         from zero (its whole usage belongs to this step).
    gpu: per UKey (engine_ns delta, cycles delta); None when an H why="start" lies between
         the two snapshots (the recorder restarted, its gpu baseline is unknown).
    wk:  wake switches written at the END snapshot, with wk_since_m = mono s of the previous
         thread scan; the wake count covers [wk_since_m, mb], which may span several steps.
    cl:  per cluster deltas (busy_ms, MHz*ms, t_ms). ctx: switch delta. pkt: rx+tx delta.
    x_ticks: Xwayland CPU ticks delta (USER_HZ=100), None when the pid changed.
    """
    boot8: str
    ma: float
    mb: float
    ta: float
    tb: float
    dpms: Optional[int]
    pw: Optional[str]
    cov: bool
    restart: bool = False           # an H why="start" lies inside
    fr: Optional[FrDelta] = None
    cpu: dict[UKey, int] = field(default_factory=dict)
    gpu: Optional[dict[UKey, tuple[int, int]]] = None
    wk: Optional[dict[WakeKey, int]] = None
    wk_since_m: Optional[float] = None
    cl: list[tuple[int, int, int]] = field(default_factory=list)
    ctx: Optional[int] = None
    pkt: Optional[int] = None
    x_ticks: Optional[int] = None
    new: list[UKey] = field(default_factory=list)
    gone: list[UKey] = field(default_factory=list)


@dataclass(slots=True)
class UnitLife:
    """Lifetime of one UKey inside one boot as far as the ledger saw it (mono s / usage_usec)."""
    ukey: UKey
    boot8: str
    first_m: float                  # first snapshot that listed it (or its "new")
    last_m: float                   # last snapshot that still had it
    gone_m: Optional[float] = None  # snapshot that listed it in "gone"
    first_usage: int = 0
    last_usage: int = 0


# ---------------------------------------------------------------------------------------------
# UPower (upower.py)
# ---------------------------------------------------------------------------------------------

UP_STATES = {0: "unknown", 1: "charging", 2: "discharging", 3: "empty",
             4: "fully-charged", 5: "pending-charge", 6: "pending-discharge"}
UP_PLUGGED = frozenset({1, 4, 5})
"""UPower states that count as plugged (DESIGN section 4, 是否插电)."""


@dataclass(slots=True)
class UpPoint:
    """One UPower history point. t: epoch s (corrected), value: % for charge, W for rate
    (rate is unsigned in UPower; direction comes from state), state: UP_STATES code."""
    t: float
    value: float
    state: int


@dataclass(slots=True)
class History:
    """Cleaned UPower history, oldest first. source says what was merged."""
    charge: list[UpPoint] = field(default_factory=list)
    rate: list[UpPoint] = field(default_factory=list)
    source: Literal["dbus", "dat", "dbus+dat", "none"] = "none"
    dropped: int = 0                # points dropped by clean() (backward / between boots / unfixable)


# ---------------------------------------------------------------------------------------------
# Journal (journal.py)
# ---------------------------------------------------------------------------------------------

@dataclass(slots=True)
class Consumed:
    """One user-journal "Consumed" message (MESSAGE_ID ae8f7b866b0347b9af31fe1c80b127c0).

    unit: USER_UNIT as-is (bare unit name, no slice, \\x escapes kept).
    cpu_usec: CPU_USAGE_NSEC // 1000 (lifetime total of the unit).
    boot8: first 8 hex chars of _BOOT_ID. m: __MONOTONIC_TIMESTAMP / 1e6. w: __REALTIME_TIMESTAMP / 1e6.
    """
    unit: str
    cpu_usec: int
    boot8: str
    m: float
    w: float


@dataclass(slots=True)
class ExitFix:
    """CPU a unit used after the ledger last saw it, to be added to the step containing m_exit.

    ukey: the matched ledger unit, or None when the ledger never saw it (then key is the
    guessed ledger key "u/app.slice/<unit>" etc.). extra_usec = cpu_usec - last ledger usage
    (>= 0; negative results are dropped by journal.attach).
    """
    consumed: Consumed
    ukey: Optional[UKey]
    key: str
    boot8: str
    m_exit: float
    extra_usec: int


# ---------------------------------------------------------------------------------------------
# Apps (apps.py)
# ---------------------------------------------------------------------------------------------

@dataclass(slots=True)
class DesktopEntry:
    """A .desktop file. id = file name without ".desktop". name = Name[zh_CN] -> Name[zh] -> Name.
    icon: theme name, or "file://<abs path>" when Icon= is absolute, or None.
    visible: Type=Application, not NoDisplay/Hidden, Exec non-empty, OnlyShowIn/NotShowIn ok
    for KDE (same test as dock apps.cpp). Earlier dirs win for the same id (apps.cpp order).
    steam_appid: N from "rungameid/N" in Exec, else None.
    """
    id: str
    path: str
    name: str
    icon: Optional[str]
    exec: str
    wmclass: Optional[str]
    visible: bool
    steam_appid: Optional[int] = None


ResolvedKind = Literal["app", "ui", "sys", "closed"]


@dataclass(slots=True)
class Resolved:
    """What a ledger unit key belongs to.

    kind "app":  id = desktop id, name/icon from the entry (or from the fg class when it was
                 foreground but has no visible entry: id = "class:<cls>", icon None).
    kind "ui" / "sys": id = the part label (rules.json labels or the bare unit name), name = the
                 same label in Chinese, icon None. These merge into the 系统界面 / 系统后台 items.
    kind "closed": an app.slice unit that is gone and unresolvable (已关闭的程序（认不出）).
    via: how it matched: exact|lower|alias|prefix|wmclass|fg|rule|default.
    """
    kind: ResolvedKind
    id: str
    name: str
    icon: Optional[str] = None
    via: str = "default"


# ---------------------------------------------------------------------------------------------
# Live state and config (sources.py, config.py)
# ---------------------------------------------------------------------------------------------

BatStatus = Literal["charging", "discharging", "full", "not_charging", "unknown"]


@dataclass(slots=True)
class LiveBattery:
    """sysfs battery now. charge_* in uAh (sysfs units). pct is capacity %."""
    pct: Optional[int]
    status: BatStatus
    plugged: bool                   # status in {charging, full, not_charging} or any supply online
    charge_full_uah: Optional[int] = None
    charge_full_design_uah: Optional[int] = None
    cycles: Optional[int] = None
    model_name: Optional[str] = None


@dataclass(slots=True)
class Sources:
    """Raw inputs, read either live or from a --from capture dir (sources.open_sources).

    Parsers take these texts, never paths to live system files, so tests and --from replay
    are the same code path. now / mono_now: epoch s / CLOCK_MONOTONIC s at report start
    (mono_now None in --from mode: then the current boot is anchored by its last line).
    """
    now: float
    tz_offset_min: int
    from_dir: Optional[str]
    state_dir: str                  # ledger dir to hand to ledger.read_dir
    boot_id: Optional[str]          # current boot, dashed
    mono_now: Optional[float]
    battery: LiveBattery
    upower_charge_json: Optional[str] = None
    upower_rate_json: Optional[str] = None
    upower_dat: dict[str, str] = field(default_factory=dict)   # file name -> text
    journal_lines: list[str] = field(default_factory=list)
    desktop: list[DesktopEntry] = field(default_factory=list)
    energy: Optional[str] = None    # /run/y700-flightrec/energy text
    energy_age_s: Optional[float] = None
    edge: Optional[str] = None
    rec_running: Optional[bool] = None   # None = decide from the ledger's newest write
    fg_dir_exists: bool = True


@dataclass(slots=True)
class Coeffs:
    """coeffs-v<N>.json loaded by config.load_coeffs. values: name -> value in the unit the
    file states (mW, MHz, mJ/pkt, 1/s, ...). b_points: B(l) as [(level, mW), ...] ascending."""
    version: int
    calibrated: bool
    date: Optional[str]
    source: Literal["package", "user", "dev"]
    path: str
    values: dict[str, float] = field(default_factory=dict)
    b_points: list[tuple[float, float]] = field(default_factory=list)

    def __getitem__(self, name: str) -> float:
        return self.values[name]


@dataclass(slots=True)
class Rules:
    """rules.json loaded by config.load_rules (see that file for the meaning of each list)."""
    full_pct: float = 98.0
    loose_plug_merge_s: int = 120
    just_full_s: int = 600
    weak_charger_mw: float = 50.0
    weak_charger_drop_pct: float = 1.0
    d_min_pct: float = 3.0
    apps_min_pct: float = 0.5
    segment_max_s: int = 3600
    short_on_merge_s: int = 300
    min_split_s: int = 300
    aliases: dict[str, str] = field(default_factory=dict)
    launcher_prefixes: list[str] = field(default_factory=list)
    parents: list[str] = field(default_factory=list)    # aggregate keys, never items themselves
    ui: list[str] = field(default_factory=list)         # key globs, first match wins over sys
    sys: list[str] = field(default_factory=list)
    labels: list[tuple[str, str]] = field(default_factory=list)   # (key glob, Chinese part name)
    desktop_classes: list[str] = field(default_factory=list)
    x11_classes: list[str] = field(default_factory=list)
    hidden_ok: list[str] = field(default_factory=list)  # NoDisplay ids still allowed as apps


# ---------------------------------------------------------------------------------------------
# Ranges (ranges.py)
# ---------------------------------------------------------------------------------------------

RangeKey = Literal["since_full", "24h", "7d"]
RangeState = Literal["ok", "just_full", "all_charger", "empty", "partial"]


@dataclass(slots=True)
class PlugSession:
    """One merged plugged-in session (gaps < rules.loose_plug_merge_s merged). Epoch s.
    b None = still plugged now. full: fully-charged seen or max_pct >= rules.full_pct.
    weak: the charger could not keep up (mean bat > +50 mW and the % fell >= 1); a weak session
    is counted as discharge, not as charger time. src: which source proved it
    (sysfs|upower|ledger, joined by "+")."""
    a: float
    b: Optional[float]
    full: bool
    max_pct: Optional[float] = None
    weak: bool = False
    src: str = ""


SegKind = Literal["on", "off", "charger", "gap", "uncovered"]


@dataclass(slots=True)
class Segment:
    """A piece of a range with one state (DESIGN section 4 段), epoch s, a < b, <= 60 min.

    kind:
      on / off   discharging with per-item records (ledger steps with cov=1 and fr present);
      uncovered  discharging but not itemisable: no ledger yet, or degraded (cov=0 / no acc);
      charger    plugged (not weak) - energy and time not counted;
      gap        nothing known (powered off, between boots, unknown-time boot).
    d_pct: battery % drop over the segment (from UPower charge points / ledger cap), >= 0.
    e_j:   measured discharge energy in J (fr don/doff), None for uncovered / charger / gap.
    degraded: uncovered because cov=0 (as opposed to "no ledger yet").
    steps: indices into the boot's Step list that make up this segment.
    """
    boot8: Optional[str]
    a: float
    b: float
    kind: SegKind
    d_pct: float = 0.0
    e_j: Optional[float] = None
    degraded: bool = False
    weak_charger: bool = False
    steps: list[int] = field(default_factory=list)


Anchor = Literal["full", "prev_round", "no_full", "window"]


@dataclass(slots=True)
class Range:
    """One of the three page ranges before attribution. Epoch s.

    anchor (since_full only, "window" for 24h/7d):
      full        start = unplug time of the latest finished full session;
      prev_round  plugged and full now: shows [previous unplug, plug_t] (DESIGN section 5 case 4);
      no_full     no full charge in the data: start = earliest data (case 7).
    mid_plugs: non-full plug sessions inside the range (case 8, 中间插电 N 次).
    charges: plug-ins shown in the range (24h / 7d 充电 N 次): non-weak sessions with charger time in it, two of
      them with nothing but gap between them counted once (a reboot or power-off while plugged in).
    bucket_s / bucket_t: the bucket grid (see ranges.bucket_grid and DESIGN 6b.a).
    curve: [(t, pct)] oldest first, not yet decimated. bands: kind -> sorted [(a, b)].
    """
    key: RangeKey
    start: float
    end: float
    state: RangeState
    anchor: Anchor = "window"
    anchor_t: Optional[float] = None
    plug_t: Optional[float] = None
    mid_plugs: int = 0
    charges: int = 0
    plugged_now: bool = False
    full_now: bool = False
    segments: list[Segment] = field(default_factory=list)
    curve: list[tuple[float, float]] = field(default_factory=list)
    bands: dict[str, list[tuple[float, float]]] = field(default_factory=dict)
    bucket_s: int = 3600
    bucket_t: list[int] = field(default_factory=list)
    unknown_time_boots: int = 0
    data_from: Optional[float] = None   # first itemised moment when the ledger starts late; with nothing
                                        # itemised, the moment the screen state becomes known


# ---------------------------------------------------------------------------------------------
# Attribution (model.py) and the whole report (cli.py)
# ---------------------------------------------------------------------------------------------

ItemKind = Literal["screen", "floor", "app", "apps_rest", "ui", "sys", "wifi", "other", "unrecorded"]


@dataclass(slots=True)
class ItemEnergy:
    """One list row before percent conversion. Energies in J, durations in s.

    id: "screen" | "floor" | "ui" | "sys" | "wifi" | "other" | "unrecorded" | "app:<desktop id>"
        | "app:class:<cls>" | "app:#closed". (apps_rest is created by out.py, not model.py.)
    e_j = fg_j + bg_j for apps; off_j <= bg_j is the screen-off part of bg_j.
    buckets_j: energy per range bucket, len == len(range.bucket_t), sums to e_j.
    unrecorded: e_j is the % drop of uncovered segments converted to J (D * E_full / 100).
    parts: for ui / sys / other: (Chinese part name, J), largest first.
    windows: apps only, (window name, foreground s), largest first.
    wake_off_n: screen-off wakeups attributed (count), None when no wk data.
    """
    id: str
    kind: ItemKind
    name: str
    icon: Optional[str] = None
    e_j: float = 0.0
    fg_j: float = 0.0
    bg_j: float = 0.0
    off_j: float = 0.0
    fg_s: Optional[float] = None
    bg_s: Optional[float] = None
    cpu_s: Optional[float] = None
    gpu_s: Optional[float] = None
    wake_off_n: Optional[float] = None
    buckets_j: list[float] = field(default_factory=list)
    windows: list[tuple[str, float]] = field(default_factory=list)
    parts: list[tuple[str, float]] = field(default_factory=list)
    note: Optional[str] = None


@dataclass(slots=True)
class RangeResult:
    """model.attribute() output for one Range.

    used_pct_raw: D (sum of % drops of discharge segments), or sum(E)/E_full*100 when D <
        rules.d_min_pct (used_pct_basis then says "energy").
    e_full_j: charge_full * 3.87 V in J, used for the D < 3 fallback and the unrecorded item.
    on_s/off_s: itemised + uncovered discharge seconds with the screen on / off;
    uncovered_s: discharge seconds that are not itemisable (part of on_s+off_s when dpms is
        known, otherwise only here); charger_s, gap_s.
    brightness_hint_pct_h: % per hour of screen-on saved by 10 % less backlight, None when no
        screen-on data.
    model_high_segments: segments whose reconciliation flagged 模型偏高 (lambda < 0.5 or Fix > E).
    unexplained_frac: "other" energy / itemised energy, for diag.
    learned_floor_off_mw: P25 of screen-off segment power >= 20 min long, None if too few.
    model_floor_off_mw: P25 of the model's power for the same segments before reconciliation (F_off + W + CPU /
        GPU / Wi-Fi), None if too few: what learned_floor_off_mw is compared with.
    alive_iv: apps only, item id -> [(boot8, a, b)]: mono s the app was open inside itemised discharge
        segments, disjoint per boot (bg_s = their total - fg_s); out.py takes the union of apps_rest's members.
    """
    range: Range
    items: list[ItemEnergy] = field(default_factory=list)
    used_pct_raw: float = 0.0
    used_pct_basis: Literal["pct", "energy"] = "pct"
    e_full_j: float = 0.0
    on_s: float = 0.0
    off_s: float = 0.0
    uncovered_s: float = 0.0
    charger_s: float = 0.0
    gap_s: float = 0.0
    brightness_hint_pct_h: Optional[float] = None
    model_high_segments: int = 0
    unexplained_frac: Optional[float] = None
    learned_floor_off_mw: Optional[float] = None
    model_floor_off_mw: Optional[float] = None
    alive_iv: dict[str, list[tuple[str, float, float]]] = field(default_factory=dict)
    fg_known: bool = True           # False when fg tracking was off for part of the range


@dataclass(slots=True)
class Inputs:
    """Everything parsed, built once by cli.py and handed to ranges.py / model.py / fit.py.

    steps / lives are keyed by boot8. apps is an apps.AppIndex (typed Any here to keep this
    module free of imports). sessions is filled by ranges.plug_timeline().
    """
    src: Sources
    coeffs: Coeffs
    rules: Rules
    ledger: Ledger
    history: History
    steps: dict[str, list[Step]] = field(default_factory=dict)
    lives: dict[str, dict[UKey, UnitLife]] = field(default_factory=dict)
    fixes: list[ExitFix] = field(default_factory=list)
    apps: Any = None
    sessions: list[PlugSession] = field(default_factory=list)


@dataclass(slots=True)
class Remain:
    """Remaining time estimate: hours at the mean drain rate of the discharge time in the last basis_h hours."""
    h: float
    basis_h: int = 24


@dataclass(slots=True)
class RecState:
    """Recorder status. since: epoch s of the oldest ledger line; last_write_age_s: now minus
    the newest ledger line's wall time."""
    running: bool
    degraded: bool
    since: Optional[float]
    last_write_age_s: Optional[float]
    fg_log: bool
    clock_unsynced: bool = False


@dataclass(slots=True)
class Diag:
    """Numbers for tools/y700-checklist.py (DESIGN 6b.a diag). Never shown by the page."""
    unexplained_median_7d: Optional[float]
    floor_off_learned_mw: Optional[float]
    floor_off_model_mw: float
    coeff_age_days: Optional[int]
    ledger_bytes: int
    ledger_newest_age_s: Optional[float]
    energy_age_s: Optional[float]
    segments_flagged_7d: int


@dataclass(slots=True)
class Report:
    """Everything out.py needs to write JSON v1 / --text."""
    now: float
    tz_offset_min: int
    took_ms: int
    rec: RecState
    battery: LiveBattery
    health_pct: Optional[int]
    coeffs: Coeffs
    ranges: dict[str, RangeResult]
    remain: Optional[Remain]
    diag: Diag
