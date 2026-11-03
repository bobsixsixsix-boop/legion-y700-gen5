"""Ledger unit -> app, and app -> .desktop name and icon (DESIGN.md section 3 "单元名 → 应用 id" / "id → .desktop").

The .desktop side copies the dock (linux/dock/y700-shellbar/src/apps.cpp) so the page names an app exactly as the dock
shows it: the same six directories in the same order plus ~/Desktop, the [Desktop Entry] group only, the same
visibility test, Name[zh_CN] -> Name[zh] -> Name, and an absolute Icon= as file://. Two apps.cpp details matter here:
- a hidden entry (NoDisplay, Hidden, wrong OnlyShowIn ...) in an earlier directory does not shadow a visible one of the
  same id further down (apps.cpp skips it before claiming the id);
- a ~/Desktop launcher whose Exec equals an app already found is that app under another id (CarPlay.desktop =
  dev.f-io.livi.desktop), not a second app.

Unit names come in four shapes (section 3 table): the dock's app-y700-<id>-<pid>-<seq>.scope (id with every char
outside [A-Za-z0-9_.-] made '_', dashes raw), the XDG app-[<launcher>-]<id>-<random>.scope / app-<id>@<random>.service
(dashes inside the id escaped as \\x2d), app-flatpak-<id>-<n>.scope, and our own helper units such as
app-steam-arm64-tri-restore-<n>.service that rules.json launcher_prefixes ties to their app.

scan() reads files because its interface takes directories; everything else works on strings and entries.
"""

from __future__ import annotations

import os
import re
from fnmatch import fnmatchcase
from typing import Iterable, Optional, Sequence

from .types import KERNEL, DesktopEntry, Resolved, Rules

CLOSED_ID = "#closed"
CLOSED_NAME = "已关闭的程序（认不出）"
XWAYLAND = "#xwayland"

_ESC = re.compile(r"\\x([0-9A-Fa-f]{2})")
_RUNGAME = re.compile(r"rungameid/(\d+)")
_STEAM_CLASS = re.compile(r"steam_app_(\d+)")


def app_dirs(home: str) -> list[str]:
    """apps.cpp appDirs() in its order (earlier wins), then ~/Desktop as its scan() appends it"""
    return [home + "/.local/share/applications", "/usr/local/share/applications", "/usr/share/applications",
            "/var/lib/flatpak/exports/share/applications", home + "/.local/share/flatpak/exports/share/applications",
            "/var/lib/snapd/desktop/applications", home + "/Desktop"]


# the same directories as path suffixes, to rank the absolute paths of a bp-capture desktop-files.txt (which lists
# /usr/share first). (needs a home in front, suffix)
_ROOTS = [(True, "/.local/share/applications/"), (False, "/usr/local/share/applications/"),
          (False, "/usr/share/applications/"), (False, "/var/lib/flatpak/exports/share/applications/"),
          (True, "/.local/share/flatpak/exports/share/applications/"), (False, "/var/lib/snapd/desktop/applications/"),
          (True, "/Desktop/")]


def unescape_unit(name: str) -> str:
    """systemd's \\xNN escapes (one per UTF-8 byte) undone: app-geoclue\\x2ddemo -> app-geoclue-demo"""
    if "\\x" not in name:
        return name
    out = bytearray()
    pos = 0
    for m in _ESC.finditer(name):
        out += name[pos:m.start()].encode("utf-8", "surrogateescape")
        out.append(int(m.group(1), 16))
        pos = m.end()
    out += name[pos:].encode("utf-8", "surrogateescape")
    return out.decode("utf-8", "replace")


def unit_app_id(unit: str) -> Optional[str]:
    """The app id a user unit name carries (section 3 table), \\xNN undone; None when it is not an app-* unit.

    The result may still need rules: a dock id keeps its '_' stand-ins, an alias (com.google.Chrome, CarPlay) or a
    launcher prefix (steam-arm64-tri-restore) is not a desktop id yet. AppIndex.resolve does those steps."""
    name = unit.rsplit("/", 1)[-1]
    if name.endswith(".scope"):
        name = name[:-6]
    elif name.endswith(".service"):
        name = name[:-8]
    else:
        return None
    if not name.startswith("app-"):
        return None
    rest = name[4:]
    if rest.startswith("y700-"):
        m = re.fullmatch(r"(.+)-\d+-\d+", rest[5:])
        core = m.group(1) if m else rest[5:]
    elif rest.startswith("flatpak-"):
        m = re.fullmatch(r"(.+)-\d+", rest[8:])
        core = m.group(1) if m else rest[8:]
    elif "@" in rest:
        core = rest[:rest.index("@")]
    else:
        m = re.fullmatch(r"(.+)-[0-9A-Fa-f]+", rest)
        core = m.group(1) if m else rest
    core = unescape_unit(core)
    return core or None


# ---------------------------------------------------------------------------------------------
# .desktop files
# ---------------------------------------------------------------------------------------------

def _entry(path: str, id: str, kv: dict[str, str]) -> DesktopEntry:
    def yes(k: str) -> bool:
        return kv.get(k, "").lower() == "true"

    exec_ = kv.get("Exec", "")
    only, not_in = kv.get("OnlyShowIn", ""), kv.get("NotShowIn", "")
    visible = (kv.get("Type") == "Application" and not yes("NoDisplay") and not yes("Hidden") and exec_ != ""
               and (only == "" or "KDE" in only.split(";")) and "KDE" not in not_in.split(";"))
    # an entry with no name at all would make an empty row; apps.cpp shows "" there, the page shows the id
    name = kv.get("Name[zh_CN]") or kv.get("Name[zh]") or kv.get("Name") or id
    icon = kv.get("Icon") or None
    if icon is not None and icon.startswith("/"):
        icon = "file://" + icon
    m = _RUNGAME.search(exec_)
    return DesktopEntry(id=id, path=path, name=name, icon=icon, exec=exec_, wmclass=kv.get("StartupWMClass") or None,
                        visible=visible, steam_appid=int(m.group(1)) if m else None)


def _file_id(path: str) -> str:
    base = path.replace("\\", "/").rsplit("/", 1)[-1]
    return base[:-8] if base.endswith(".desktop") else base


def parse_desktop(path: str, text: str, id: Optional[str] = None) -> Optional[DesktopEntry]:
    """One .desktop file; None when it has no [Desktop Entry] group. id defaults to the file name without .desktop
    (scan() passes the subdirectory form, kde/foo.desktop -> kde-foo). Keys as apps.cpp reads them: trimmed, later
    duplicates win, no locale or escape processing beyond Name[zh_CN] / Name[zh]."""
    kv: dict[str, str] = {}
    in_group = found = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("["):
            in_group = line == "[Desktop Entry]"
            found = found or in_group
            continue
        if not in_group or not line or line.startswith("#"):
            continue
        eq = line.find("=")
        if eq > 0:
            kv[line[:eq].strip()] = line[eq + 1:].strip()
    if not found:
        return None
    return _entry(path, id if id is not None else _file_id(path), kv)


def _rank(path: str) -> tuple[int, str]:
    """(apps.cpp directory rank, desktop id) of an absolute path; unknown directories rank last"""
    p = path.replace("\\", "/")
    for i, (homed, suf) in enumerate(_ROOTS):
        at = p.find(suf) if homed else (0 if p.startswith(suf) else -1)
        if at > 0 or (at == 0 and not homed):
            rel = p[at + len(suf):]
            return i, (rel[:-8] if rel.endswith(".desktop") else rel).replace("/", "-")
    return len(_ROOTS), _file_id(p)


def parse_capture(text: str) -> list[DesktopEntry]:
    """bp-capture's desktop-files.txt: "== <path>" then that file's text. 6b.b says the whole file; the 10-30 capture
    keeps only the keys used here and drops the group header, so a block without headers counts as [Desktop Entry].
    Returned in apps.cpp precedence, file order kept within a directory - the capture lists /usr/share first."""
    blocks: list[tuple[str, dict[str, str]]] = []
    in_group = True
    for raw in text.splitlines():
        if raw.startswith("== "):
            blocks.append((raw[3:], {}))
            in_group = True             # a block without group headers is all [Desktop Entry] (the 10-30 capture)
            continue
        if not blocks:
            continue
        line = raw.strip()
        if line.startswith("["):
            in_group = line == "[Desktop Entry]"    # 6b.b's full file text: [Desktop Action ...] keys must not leak in
            continue
        eq = line.find("=")
        if in_group and eq > 0 and not line.startswith("#"):
            blocks[-1][1][line[:eq].strip()] = line[eq + 1:].strip()
    ranked = []
    for n, (path, kv) in enumerate(blocks):
        r, id = _rank(path)
        ranked.append((r, n, _entry(path, id, kv)))
    ranked.sort(key=lambda x: (x[0], x[1]))
    return [e for _, _, e in ranked]


def scan(dirs: Sequence[str]) -> list[DesktopEntry]:
    """Every *.desktop under dirs (subdirectories too, ids joined with '-'), in the order given, files sorted within a
    directory. Unreadable files and missing directories are skipped."""
    out: list[DesktopEntry] = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for root, subdirs, files in os.walk(d):
            subdirs.sort()
            for f in sorted(files):
                if not f.endswith(".desktop"):
                    continue
                full = os.path.join(root, f)
                rel = os.path.relpath(full, d).replace(os.sep, "/")
                try:
                    with open(full, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                e = parse_desktop(full, text, id=rel[:-8].replace("/", "-"))
                if e is not None:
                    out.append(e)
    return out


def _in_desktop_dir(path: str) -> bool:
    parts = path.replace("\\", "/").rsplit("/", 2)
    return len(parts) == 3 and parts[1] == "Desktop"


# ---------------------------------------------------------------------------------------------
# The index
# ---------------------------------------------------------------------------------------------

class AppIndex:
    """Lookups over the scanned entries with the dock's precedence. rules: types.Rules (aliases, launcher_prefixes,
    ui / sys / labels / parents, desktop_classes, x11_classes, hidden_ok)."""

    def __init__(self, entries: Iterable[DesktopEntry], rules: Rules):
        self.rules = rules
        self._by_id: dict[str, DesktopEntry] = {}
        self._hidden: dict[str, DesktopEntry] = {}
        self._by_key: dict[str, str] = {}      # apps.cpp byKey: lowercase id / wmclass / ~/Desktop alias -> id
        alias: dict[str, str] = {}
        by_exec: dict[str, str] = {}
        entries = list(entries)
        for e in entries:
            if e.id in self._by_id:
                continue                        # earlier directories win
            if not (e.visible or e.id in rules.hidden_ok):
                self._hidden.setdefault(e.id, e)
                continue
            if _in_desktop_dir(e.path) and e.exec in by_exec:
                alias[e.id.lower()] = by_exec[e.exec]
                continue
            self._by_id[e.id] = e
            by_exec.setdefault(e.exec, e.id)
        self._by_key.update(alias)
        for i in sorted(self._by_id):           # QVariantMap order: ids override, a wmclass only fills a gap
            self._by_key[i.lower()] = i
            wm = (self._by_id[i].wmclass or "").lower()
            if wm and wm not in self._by_key:
                self._by_key[wm] = i
        self._steam: dict[int, str] = {}
        for e in entries:
            if e.steam_appid is not None and self._by_id.get(e.id) is e:
                self._steam.setdefault(e.steam_appid, e.id)
        self._ids_sorted = sorted(self._by_id)
        self._aliases_lower = {k.lower(): v for k, v in rules.aliases.items()}

    # -- plain lookups

    def get(self, id: str) -> Optional[DesktopEntry]:
        """The visible (or hidden_ok) entry with exactly this desktop id."""
        return self._by_id.get(id)

    def steam_game(self, appid: int) -> Optional[DesktopEntry]:
        """The visible entry whose Exec has rungameid/<appid> (Steam's own game launchers)."""
        i = self._steam.get(int(appid))
        return self._by_id.get(i) if i is not None else None

    def by_class(self, cls: Optional[str]) -> Optional[DesktopEntry]:
        """A window class -> its app: steam_app_<N> -> the game's launcher, then apps.cpp byKey (lowercase id or
        StartupWMClass), then rules.json aliases (TelegramDesktop, steam, CarPlay ...)."""
        if not cls:
            return None
        m = _STEAM_CLASS.fullmatch(cls)
        if m:
            return self.steam_game(int(m.group(1)))
        i = self._by_key.get(cls.lower())
        if i is not None:
            return self._by_id[i]
        hit = self._alias(cls)
        return hit

    def _alias(self, name: str) -> Optional[DesktopEntry]:
        t = self.rules.aliases.get(name) or self._aliases_lower.get(name.lower())
        if t is None:
            return None
        if t in self._by_id:
            return self._by_id[t]
        i = self._by_key.get(t.lower())
        return self._by_id[i] if i is not None else None

    def _plain(self, app_id: str) -> Optional[tuple[DesktopEntry, str]]:
        if app_id in self._by_id:
            return self._by_id[app_id], "exact"
        i = self._by_key.get(app_id.lower())
        if i is not None:
            return self._by_id[i], "lower"
        e = self._alias(app_id)
        if e is not None:
            return e, "alias"
        return None

    def lookup(self, app_id: str, wildcard: bool = False) -> Optional[tuple[DesktopEntry, str]]:
        """(entry, via) for an app id from unit_app_id(): exact -> lowercase -> alias -> (dock ids: '_' as a one-char
        wildcard) -> launcher prefix -> the longest known desktop id it starts with -> leading segments stripped."""
        hit = self._plain(app_id)
        if hit is not None:
            return hit
        if wildcard and "_" in app_id:
            rx = re.compile("".join("." if c == "_" else re.escape(c) for c in app_id), re.IGNORECASE)
            for i in self._ids_sorted:
                if rx.fullmatch(i):
                    return self._by_id[i], "exact"
        low = app_id.lower()
        for pre in self.rules.launcher_prefixes:
            if low == pre.lower() or low.startswith(pre.lower() + "-"):
                hit = self._plain(pre)
                if hit is not None:
                    return hit[0], "prefix"
        best: Optional[str] = None
        for i in self._ids_sorted:
            if low.startswith(i.lower() + "-") and (best is None or len(i) > len(best)):
                best = i
        if best is not None:
            return self._by_id[best], "prefix"
        segs = app_id.split("-")
        for k in range(1, len(segs)):
            hit = self._plain("-".join(segs[k:]))
            if hit is not None:
                return hit[0], "prefix"
        return None

    # -- classes

    def is_desktop_class(self, cls: Optional[str]) -> bool:
        """The desktop itself (rules.json desktop_classes, "" included): its foreground time goes to 系统界面."""
        return (cls or "") in self.rules.desktop_classes

    def is_x11(self, cls: Optional[str]) -> bool:
        """An X11 app's window (rules.json x11_classes globs): Xwayland's cost goes to it while it is foreground."""
        return bool(cls) and any(fnmatchcase(cls, g) for g in self.rules.x11_classes)

    def window_name(self, cls: Optional[str], title: Optional[str] = None) -> str:
        """The name of one window for an app's windows list: a Steam game's launcher name for steam_app_<N>, the app
        name for a known class, else the title, else the class itself."""
        e = self.by_class(cls)
        if e is not None:
            return e.name
        return title or cls or ""

    # -- ledger keys

    def label(self, key: str) -> str:
        """The Chinese part name of a ledger key (rules.json labels, first glob wins), the bare unit name if none."""
        for g, name in self.rules.labels:
            if fnmatchcase(key, g):
                return name
        return key.rsplit("/", 1)[-1]

    def _part(self, kind: str, key: str, via: str) -> Resolved:
        name = self.label(key)
        return Resolved(kind=kind, id=name, name=name, icon=None, via=via)

    def resolve(self, key: str, alive: bool = True, fg_classes: Sequence[str] = ()) -> Resolved:
        """What a ledger key belongs to (types.Resolved).

        alive: the unit is still running at the end of the range; an app.slice unit that resolves to nothing is 系统后台
        while alive and 已关闭的程序（认不出） once gone. fg_classes: the window classes the fg log saw for this unit,
        most foreground time first; they match StartupWMClass, and an app with no visible .desktop that was foreground
        still counts as an app ("class:<cls>")."""
        r = self.rules
        if key in (KERNEL, "/"):
            return self._part("sys", KERNEL, "rule")     # root minus its slices: the kernel
        if key == XWAYLAND:
            return self._part("ui", key, "rule")
        for g in r.ui:
            if fnmatchcase(key, g):
                return self._part("ui", key, "rule")
        for g in r.sys:
            if fnmatchcase(key, g):
                return self._part("sys", key, "rule")
        if key == "u/app.slice":
            return Resolved(kind="closed", id=CLOSED_ID, name=CLOSED_NAME, via="rule")
        if key in r.parents or not key.startswith("u/app.slice/"):
            return self._part("sys", key, "rule" if key in r.parents else "default")
        unit = key[len("u/app.slice/"):].split("/", 1)[0]
        app_id = unit_app_id(unit)
        if app_id is not None:
            hit = self.lookup(app_id, wildcard=unit.startswith("app-y700-"))
            if hit is not None:
                e, via = hit
                return Resolved(kind="app", id=e.id, name=e.name, icon=e.icon, via=via)
        classes = [c for c in fg_classes if not self.is_desktop_class(c)]
        for c in classes:
            e = self.by_class(c)
            if e is not None:
                return Resolved(kind="app", id=e.id, name=e.name, icon=e.icon, via="wmclass")
        if classes:
            return Resolved(kind="app", id="class:" + classes[0], name=classes[0], icon=None, via="fg")
        if alive:
            return self._part("sys", key, "default")
        return Resolved(kind="closed", id=CLOSED_ID, name=CLOSED_NAME, via="default")
