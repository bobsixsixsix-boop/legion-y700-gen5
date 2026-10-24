#!/usr/bin/env python3
# fake-sni.py (10-23): the tray side of the sb-bed, for the control centre's 「后台应用」 (README stage 4: 托盘
# (StatusNotifierItem) 挪进控制中心; the scenario is tray.sh). For the bed's private session bus ONLY: it takes
# org.kde.StatusNotifierWatcher, which on the tablet is kded6's (plasmashell's tray would lose its items), so it
# refuses to start on the user bus /run/user/UID/bus or when that name already has an owner.
#  (a) the watcher (/StatusNotifierWatcher, org.kde.StatusNotifierWatcher), the part hosts use: RegisterStatusNotifierItem
#      in its three forms ("/path" = the caller + path; "service/path" kept as given; a bare "service" kept bare - kded6
#      stores "service/StatusNotifierItem" instead, this one does not, so the host's parsing of the bare form is
#      exercised), RegisterStatusNotifierHost with kded6's check (a name "org.kde.StatusNotifierHost-..." that has an
#      owner is taken, anything else silently ignored: "SNI watcher host added|ignored NAME"),
#      RegisteredStatusNotifierItems (registration order; "SNI watcher list N" for every read),
#      IsStatusNotifierHostRegistered, ProtocolVersion and the four signals. An item or host whose bus name loses its
#      owner is dropped (NameOwnerChanged), as kded6 does.
#  (b) six items, each on its own connection (own unique name, as separate apps are), after the live tray of 10-23 18:5x:
#      claude   Electron (Chromium's StatusIconLinuxDbus): owns org.freedesktop.StatusNotifierItem-PID-1, registers
#               "<that name>/StatusNotifierItem"; the 14 properties Chromium exports - NO IconName (a Get of it is an
#               error, GetAll leaves it out), IconPixmap one 64x64 ARGB32 network order (an orange #d97757 disc), Title
#               "", ToolTip ("", [], "Claude", ""); Introspect answers an empty <node/> on both paths (as Electron:
#               a host built on QDBusInterface gets nothing); menu /com/canonical/dbusmenu = the real Claude menu;
#               Activate and ProvideXdgActivationToken.
#      fcitx    registers "<unique name>/StatusNotifierItem"; IconName input-keyboard, Title 输入法, Category
#               SystemServices, Menu /MenuBar = the real fcitx layout (radio 100/101/102 with 101 checked, submenu 305
#               雾凇拼音 309/310/sep/307/308, items 311-315, item 4 with a mnemonic: "_Configure 输入法设置" shows
#               "Configure 输入法设置"). Like fcitx it fills the menu on AboutToShow: the root's children only after
#               AboutToShow(0), 305's after AboutToShow(305). Activate; no ProvideXdgActivationToken (UnknownMethod).
#      folder   ItemIsMenu true (a tap must open its menu, never Activate); registers its bare unique name; IconName
#               folder, Title 文件; menu: a checked checkmark item, an item with "__" (shows one "_"), an invisible one.
#      alert    Status NeedsAttention, IconName dialog-information, AttentionIconName dialog-warning, Title 提醒;
#               object at /org/ayatana/NotificationItem/alert, registered as that bare path (libappindicator's way).
#               Its own org.freedesktop.DBus.Properties without GetAll ("SNI alert GetAll refused", UnknownMethod;
#               "SNI alert Get NAME" for each property read singly): a host must fall back to Get.
#      noact    Title 无激活, IconName y700-fake-no-such-icon (in no theme) and no IconPixmap: the tile draws the label's
#               first character in a disc; owns org.kde.StatusNotifierItem-PID-5 and registers it bare;
#               Activate answers org.freedesktop.DBus.Error.UnknownMethod (a tap must fall back to its menu); menu: two
#               items between leading, double and trailing separators (shown: item, one separator, item).
#      passive  Status Passive, Title 被动: never shown.
#      claude, fcitx and folder are in the watcher's list before it takes its name (a host started after the apps reads
#      them from the list, they never register again: "SNI watcher preloaded ENTRY"); the other three register once a
#      host registered (at most 3 s later), so both the host's first read of the list and the Registered signal carry
#      items; "FAKESNI READY" when all six are in.
#      More, only on Spawn (registered "<unique name>/StatusNotifierItem"):
#      anim     Title 动画, no IconName, IconPixmap a 64x64 disc whose colour changes with NewIcon 30 times a second
#               (Spectacle's icon while it records); menu: 停止动画; Activate.
#      slow     Title 慢, Menu /NO_DBUSMENU (none); Activate is never answered (a hung app).
#      nomenu   Title 无菜单, Menu "/" (none); Activate answers UnknownMethod.
#  (c) fyi.y700.FakeSni /FakeSni (busctl --user call fyi.y700.FakeSni /FakeSni fyi.y700.FakeSni METHOD SIG ARGS):
#      SetStatus ss ITEM STATUS (NewStatus), SetTitle ss ITEM TITLE (NewTitle), SetIcon ss ITEM NAME (IconName,
#      NewIcon), Remove s ITEM (closes the item's connection: the watcher drops it), Relayout s ITEM (a menu label
#      changes, LayoutUpdated(rev, 0)), Spawn s ITEM (one of the Spawn-only items comes up), Quit (the whole fake, the
#      watcher too: the host must survive it and register again with the next watcher).
# stdout (the bed's log), one flushed line per event: "SNI <item> <Method> <args>" for every call into an item or its
# menu (Activate X Y, ProvideXdgActivationToken token=<first 8 chars>|EMPTY, AboutToShow ID, GetLayout PARENT DEPTH,
# Event ID EVENT, ...); "SNI <item> Get Status" once per property fetch (GetAll reads every property, a host reading
# single ones reads Status too); "SNI watcher ..." for the watcher's calls; "FAKESNI ..." for its own state.
import os
import sys
import warnings
from gi.repository import Gio, GLib

# PyGObject 3.50 marks DBusConnection.register_object deprecated (for register_object_with_closures2, which older
# ones lack); it works, and the warning would only clutter the bed's log
warnings.filterwarnings("ignore", category=DeprecationWarning)

PID = os.getpid()
FLAGS = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
WATCHER = "org.kde.StatusNotifierWatcher"


def out(*a):
    print(*a, flush=True)


ADDR = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
if "/run/user/%d/bus" % os.getuid() in ADDR:
    out("FAKESNI REFUSED: this is the real session bus (%s); fake-sni.py runs in the sb-bed only" % ADDR)
    sys.exit(2)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()


def V(t, v):
    return v if isinstance(v, GLib.Variant) else GLib.Variant(t, v)


def pixmaps(imgs):
    """a(iiay) from [(w, h, ARGB32 bytes in network order)]; the ay built from the bytes as they are"""
    return GLib.Variant.new_array(GLib.VariantType.new("(iiay)"), [
        GLib.Variant.new_tuple(GLib.Variant("i", w), GLib.Variant("i", h),
                               GLib.Variant.new_from_bytes(GLib.VariantType.new("ay"), GLib.Bytes.new(data), True))
        for w, h, data in imgs])


def tooltip(icon, title, text):
    return GLib.Variant.new_tuple(GLib.Variant("s", icon), pixmaps([]), GLib.Variant("s", title), GLib.Variant("s", text))


def disc(size=64, rgb=(0xd9, 0x77, 0x57)):
    """Claude's icon: an orange disc on transparent, ARGB32 big-endian (A, R, G, B per pixel), edge anti-aliased"""
    c, r = (size - 1) / 2, size / 2 - 3
    buf = bytearray()
    for y in range(size):
        for x in range(size):
            a = max(0.0, min(1.0, r - ((x - c) ** 2 + (y - c) ** 2) ** 0.5 + 0.5))
            buf += bytes((int(a * 255 + 0.5),) + rgb) if a > 0 else b"\0\0\0\0"
    return bytes(buf)


# ---------------- the watcher

WATCHER_XML = """<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg name="service" type="s" direction="in"/></method>
<method name="RegisterStatusNotifierHost"><arg name="service" type="s" direction="in"/></method>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
<signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
<signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
<signal name="StatusNotifierHostRegistered"/>
<signal name="StatusNotifierHostUnregistered"/>
</interface></node>"""

entries = []          # registered items, in registration order: (entry string, service whose owner keeps it)
hosts = []
on_host = []          # callbacks for the first host


def wemit(name, args=None):
    bus.emit_signal(None, "/StatusNotifierWatcher", WATCHER, name, args)


def has_owner(name):
    try:
        return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                             GLib.Variant("(s)", (name,)), GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE,
                             1000, None).unpack()[0]
    except GLib.Error:
        return False


def watcher_call(conn, sender, path, iface, method, params, inv):
    (arg,) = params.unpack()
    if method == "RegisterStatusNotifierItem":
        if arg.startswith("/"):
            svc, entry = sender, sender + arg
        else:
            svc, entry = arg.split("/", 1)[0], arg
        if not svc or not has_owner(svc):
            out("SNI watcher RegisterStatusNotifierItem", arg, "-> ignored (no owner)")
            inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "no such service " + svc)
            return
        inv.return_value(None)
        if any(e == entry for e, _ in entries):
            return
        entries.append((entry, svc))
        out("SNI watcher RegisterStatusNotifierItem", arg, "->", entry)
        wemit("StatusNotifierItemRegistered", GLib.Variant("(s)", (entry,)))
    elif method == "RegisterStatusNotifierHost":
        # kded6 (statusnotifierwatcher.cpp): only "org.kde.StatusNotifierHost-..." with an owner, never an error -
        # a host that gets the name wrong waits for items that never come
        inv.return_value(None)
        out("SNI watcher RegisterStatusNotifierHost", arg)
        if not arg.startswith("org.kde.StatusNotifierHost-") or not has_owner(arg):
            out("SNI watcher host ignored", arg)
            return
        out("SNI watcher host added", arg)
        if arg not in hosts:
            hosts.append(arg)
            wemit("StatusNotifierHostRegistered")
        while on_host:
            on_host.pop(0)()
    else:
        inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)


def watcher_prop(conn, sender, path, iface, name):
    if name == "RegisteredStatusNotifierItems":
        out("SNI watcher list", len(entries))
        return GLib.Variant("as", [e for e, _ in entries])
    if name == "IsStatusNotifierHostRegistered":
        return GLib.Variant("b", bool(hosts))
    return GLib.Variant("i", 0)


def owner_changed(conn, sender, path, iface, signal, params, *user):
    name, old, new = params.unpack()
    if new:
        return
    for e in [e for e, s in entries if s == name]:
        entries[:] = [x for x in entries if x[0] != e]
        out("SNI watcher dropped", e)
        wemit("StatusNotifierItemUnregistered", GLib.Variant("(s)", (e,)))
    if name in hosts:
        hosts.remove(name)
        out("SNI watcher host gone", name)
        if not hosts:
            wemit("StatusNotifierHostUnregistered")


# ---------------- items

SNI_TYPES = {"Category": "s", "Id": "s", "Title": "s", "Status": "s", "WindowId": "i", "IconThemePath": "s",
             "Menu": "o", "ItemIsMenu": "b", "IconName": "s", "IconPixmap": "a(iiay)", "OverlayIconName": "s",
             "OverlayIconPixmap": "a(iiay)", "AttentionIconName": "s", "AttentionIconPixmap": "a(iiay)",
             "AttentionMovieName": "s", "ToolTip": "(sa(iiay)ss)", "XAyatanaLabel": "s", "XAyatanaLabelGuide": "s",
             "XAyatanaOrderingIndex": "u"}

INTROSPECTABLE_XML = """<node><interface name="org.freedesktop.DBus.Introspectable">
<method name="Introspect"><arg type="s" direction="out"/></method></interface></node>"""

DBUSMENU_XML = """<node><interface name="com.canonical.dbusmenu">
<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
  <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/>
  <arg type="a(ia{sv})" direction="out"/></method>
<method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/>
  <arg type="u" direction="in"/></method>
<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/>
  <arg type="ai" direction="out"/></method>
<signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
<signal name="ItemActivationRequested"><arg type="i"/><arg type="u"/></signal>
</interface></node>"""


def mi(label=None, sep=False, enabled=True, visible=True, icon=None, toggle=None, state=None, submenu=False):
    """one dbusmenu item's properties, defaults left out as apps do"""
    p = {}
    if sep:
        p["type"] = GLib.Variant("s", "separator")
    if label is not None:
        p["label"] = GLib.Variant("s", label)
    if not enabled:
        p["enabled"] = GLib.Variant("b", False)
    if not visible:
        p["visible"] = GLib.Variant("b", False)
    if icon:
        p["icon-name"] = GLib.Variant("s", icon)
    if toggle:
        p["toggle-type"] = GLib.Variant("s", toggle)
        p["toggle-state"] = GLib.Variant("i", state or 0)
    if submenu:
        p["children-display"] = GLib.Variant("s", "submenu")
    return p


class Menu:
    """nodes: id -> (properties, child ids); lazy: ids whose children appear only after AboutToShow(id)"""

    def __init__(self, nodes, lazy=()):
        self.nodes, self.lazy, self.shown, self.rev = nodes, set(lazy), set(), 1

    def layout(self, nid, depth, names):
        props, kids = self.nodes[nid]
        p = {k: v for k, v in props.items() if not names or k in names}
        ch = []
        if depth != 0 and (nid not in self.lazy or nid in self.shown):
            ch = [GLib.Variant("(ia{sv}av)", self.layout(k, depth - 1 if depth > 0 else -1, names)) for k in kids]
        return (nid, p, ch)


ROOT = mi(submenu=True)
CLAUDE_MENU = {0: (ROOT, [11, 12, 13, 14, 15, 16, 17]),
               11: (mi("显示应用"), []), 12: (mi("打开快速输入"), []), 13: (mi(sep=True), []),
               14: (mi("Demo 套餐", enabled=False), []), 15: (mi("用量：50%", enabled=False), []),
               16: (mi(sep=True), []), 17: (mi("退出"), [])}
FCITX_MENU = {0: (ROOT, [100, 101, 102, 2, 305, 311, 312, 313, 314, 315, 3, 4]),
              100: (mi("键盘 - 英语（美国）", icon="input-keyboard", toggle="radio", state=0), []),
              101: (mi("中州韵", icon="fcitx-rime", toggle="radio", state=1), []),
              102: (mi("Mozc", icon="fcitx-mozc", toggle="radio", state=0), []),
              2: (mi(sep=True), []),
              305: (mi("雾凇拼音", submenu=True), [309, 310, 306, 307, 308]),
              309: (mi("英文模式", toggle="radio", state=0), []), 310: (mi("雾凇拼音", toggle="radio", state=1), []),
              306: (mi(sep=True), []), 307: (mi("重新部署"), []), 308: (mi("同步"), []),
              311: (mi("¥ → $"), []), 312: (mi("简 → 繁"), []), 313: (mi("😄 → 💀"), []),
              314: (mi("半角 → 全角"), []), 315: (mi("正常 → 单字"), []),
              3: (mi(sep=True), []), 4: (mi("_Configure 输入法设置", icon="configure"), [])}
FOLDER_MENU = {0: (ROOT, [1, 2, 3]),
               1: (mi("显示隐藏文件", toggle="checkmark", state=1), []), 2: (mi("打开 my__files"), []),
               3: (mi("看不见的项", visible=False), [])}
ALERT_MENU = {0: (ROOT, [1]), 1: (mi("知道了"), [])}
NOACT_MENU = {0: (ROOT, [9, 1, 10, 11, 2, 12]),
              9: (mi(sep=True), []), 1: (mi("打开设置"), []), 10: (mi(sep=True), []), 11: (mi(sep=True), []),
              2: (mi("退出"), []), 12: (mi(sep=True), [])}


PROPS_XML = """<node><interface name="org.freedesktop.DBus.Properties">
<method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
<method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
</interface></node>"""


class Item:
    """form: how it registers ("service/path", "service" bare, "path" bare); activate: True, False (UnknownMethod) or
    "hang" (never answered); own_props: its own org.freedesktop.DBus.Properties without GetAll"""

    def __init__(self, name, props, register, path="/StatusNotifierItem", wellknown=None, menu=None, lazy=(),
                 activate=True, token=False, electron=False, own_props=False):
        self.name, self.props, self.form, self.path = name, props, register, path
        self.wellknown, self.activate, self.token, self.electron = wellknown, activate, token, electron
        self.own_props = own_props
        self.menu = Menu(menu, lazy) if menu else None
        self.menu_path = props.get("Menu") if menu else None
        self.conn = None
        self.held = []            # Activate calls never answered (activate="hang"), kept so they stay unanswered

    def xml(self):
        ps = "".join('<property name="%s" type="%s" access="read"/>' % (n, SNI_TYPES[n]) for n in self.props)
        ms = "".join('<method name="%s"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>' % m
                     for m in ("Activate", "SecondaryActivate", "ContextMenu"))
        ms += '<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>'
        if self.token:
            ms += '<method name="ProvideXdgActivationToken"><arg type="s" direction="in"/></method>'
        ss = "".join('<signal name="%s"/>' % s for s in ("NewTitle", "NewIcon", "NewAttentionIcon", "NewOverlayIcon",
                                                         "NewMenu", "NewToolTip"))
        ss += '<signal name="NewStatus"><arg type="s"/></signal><signal name="NewIconThemePath"><arg type="s"/></signal>'
        return '<node><interface name="org.kde.StatusNotifierItem">%s%s%s</interface></node>' % (ps, ms, ss)

    def connect(self):
        """its own connection, its objects and its name: an app that is up, not yet in any watcher's list.
        Returns the entry a watcher keeps for it and the service whose owner keeps it there."""
        self.conn = Gio.DBusConnection.new_for_address_sync(ADDR, FLAGS, None, None)
        self.conn.register_object(self.path, Gio.DBusNodeInfo.new_for_xml(self.xml()).interfaces[0],
                                  self.call, self.get, None)
        if self.own_props:     # registered by hand, GDBus's own Properties handling steps aside for this object
            self.conn.register_object(self.path, Gio.DBusNodeInfo.new_for_xml(PROPS_XML).interfaces[0],
                                      self.props_call, None, None)
        if self.menu:
            self.conn.register_object(self.menu_path, Gio.DBusNodeInfo.new_for_xml(DBUSMENU_XML).interfaces[0],
                                      self.menu_call, self.menu_get, None)
        if self.electron:      # Chromium's objects carry no introspection data
            for p in [self.path] + ([self.menu_path] if self.menu else []):
                self.conn.register_object(p, Gio.DBusNodeInfo.new_for_xml(INTROSPECTABLE_XML).interfaces[0],
                                          lambda c, s, p, i, m, a, inv: inv.return_value(GLib.Variant("(s)", ("<node/>",))),
                                          None, None)
        if self.wellknown:
            r = self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                    GLib.Variant("(su)", (self.wellknown, 4)), None, Gio.DBusCallFlags.NONE, 2000, None)
            if r.unpack()[0] != 1:
                out("FAKESNI", self.name, "could not own", self.wellknown)
        svc = self.wellknown or self.conn.get_unique_name()
        self.arg = {"service/path": svc + self.path, "service": svc, "path": self.path}[self.form]
        # what watcher_call makes of that argument (a bare path: the caller's unique name in front)
        entry = self.conn.get_unique_name() + self.path if self.form == "path" else self.arg
        return entry, (self.conn.get_unique_name() if self.form == "path" else svc)

    def register(self, done):
        def registered(conn, res, *user):
            try:
                conn.call_finish(res)
            except GLib.Error as e:
                out("FAKESNI", self.name, "registration failed:", e.message)
            done()
        # async: the watcher is this process, a blocking call would wait on our own main loop
        self.conn.call(WATCHER, "/StatusNotifierWatcher", WATCHER, "RegisterStatusNotifierItem", GLib.Variant("(s)", (self.arg,)),
                       None, Gio.DBusCallFlags.NONE, 2000, None, registered)

    def emit(self, signal, args=None, path=None, iface="org.kde.StatusNotifierItem"):
        if self.conn and not self.conn.is_closed():
            self.conn.emit_signal(None, path or self.path, iface, signal, args)

    def get(self, conn, sender, path, iface, name):
        if name == "Status":
            out("SNI", self.name, "Get Status")
        return V(SNI_TYPES[name], self.props[name])

    def props_call(self, conn, sender, path, iface, method, params, inv):
        args = params.unpack()
        if method == "GetAll":
            out("SNI", self.name, "GetAll refused")
            inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", "No such method 'GetAll'")
        elif method == "Get" and args[0] == "org.kde.StatusNotifierItem" and args[1] in self.props:
            out("SNI", self.name, "Get", args[1])
            inv.return_value(GLib.Variant.new_tuple(GLib.Variant("v", V(SNI_TYPES[args[1]], self.props[args[1]]))))
        elif method == "Get":
            out("SNI", self.name, "Get", args[1], "-> no such property")
            inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "No such property " + args[1])
        else:
            inv.return_dbus_error("org.freedesktop.DBus.Error.PropertyReadOnly", "read-only")

    def call(self, conn, sender, path, iface, method, params, inv):
        args = params.unpack()
        if method == "ProvideXdgActivationToken":
            out("SNI", self.name, method, "token=" + (args[0][:8] if args[0] else "EMPTY"))
            inv.return_value(None)
            return
        out("SNI", self.name, method, *args)
        if method == "Activate" and self.activate == "hang":
            self.held.append(inv)
            return
        if method == "Activate" and not self.activate:
            inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", "No such method 'Activate'")
            return
        inv.return_value(None)

    def menu_get(self, conn, sender, path, iface, name):
        return {"Version": GLib.Variant("u", 3), "TextDirection": GLib.Variant("s", "ltr"),
                "Status": GLib.Variant("s", "normal"), "IconThemePath": GLib.Variant("as", [])}[name]

    def menu_call(self, conn, sender, path, iface, method, params, inv):
        m = self.menu
        args = params.unpack()
        if method == "GetLayout":
            parent, depth, names = args
            out("SNI", self.name, method, parent, depth)
            if parent not in m.nodes:
                inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "no item %d" % parent)
                return
            inv.return_value(GLib.Variant("(u(ia{sv}av))", (m.rev, m.layout(parent, depth, names))))
        elif method == "AboutToShow":
            out("SNI", self.name, method, args[0])
            need = args[0] in m.lazy and args[0] not in m.shown
            m.shown.add(args[0])
            inv.return_value(GLib.Variant("(b)", (need,)))
        elif method == "AboutToShowGroup":      # one line per id, as EventGroup: tray.sh greps "AboutToShow ID"
            for i in args[0]:
                out("SNI", self.name, "AboutToShow", i)
            need = [i for i in args[0] if i in m.lazy and i not in m.shown]
            m.shown.update(args[0])
            inv.return_value(GLib.Variant("(aiai)", (need, [i for i in args[0] if i not in m.nodes])))
        elif method == "Event":
            out("SNI", self.name, method, args[0], args[1])
            inv.return_value(None)
        elif method == "EventGroup":
            for e in args[0]:
                out("SNI", self.name, "Event", e[0], e[1])
            inv.return_value(GLib.Variant("(ai)", ([e[0] for e in args[0] if e[0] not in m.nodes],)))
        elif method == "GetGroupProperties":
            out("SNI", self.name, method, *args[0])
            ids = args[0] or list(m.nodes)
            inv.return_value(GLib.Variant("(a(ia{sv}))", ([(i, m.layout(i, 0, args[1])[1]) for i in ids if i in m.nodes],)))
        elif method == "GetProperty":
            out("SNI", self.name, method, args[0], args[1])
            v = m.nodes.get(args[0], ({}, []))[0].get(args[1])
            if v is None:
                inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "no property " + args[1])
            else:
                inv.return_value(GLib.Variant.new_tuple(GLib.Variant("v", v)))
        else:
            inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)


NOPIX = pixmaps([])
ITEMS = [
    # Chromium's 14 properties, in its order; no IconName at all
    Item("claude", register="service/path", wellknown="org.freedesktop.StatusNotifierItem-%d-1" % PID, token=True,
         electron=True, menu=CLAUDE_MENU,
         props={"ItemIsMenu": False, "WindowId": 0, "Menu": "/com/canonical/dbusmenu", "AttentionIconName": "",
                "AttentionMovieName": "", "Category": "ApplicationStatus", "Id": "Claude_status_icon_1",
                "OverlayIconName": "", "Status": "Active", "Title": "", "AttentionIconPixmap": NOPIX,
                "OverlayIconPixmap": NOPIX, "IconPixmap": pixmaps([(64, 64, disc())]),
                "ToolTip": tooltip("", "Claude", "")}),
    Item("fcitx", register="service/path", menu=FCITX_MENU, lazy=(0, 305),
         props={"Category": "SystemServices", "Id": "Fcitx", "Title": "输入法", "Status": "Active", "WindowId": 0,
                "IconThemePath": "", "Menu": "/MenuBar", "ItemIsMenu": False, "IconName": "input-keyboard",
                "IconPixmap": NOPIX, "OverlayIconName": "", "OverlayIconPixmap": NOPIX, "AttentionIconName": "",
                "AttentionIconPixmap": NOPIX, "AttentionMovieName": "",
                "ToolTip": tooltip("input-keyboard", "中州韵", ""), "XAyatanaLabel": "", "XAyatanaLabelGuide": "",
                "XAyatanaOrderingIndex": 0}),
    Item("folder", register="service", menu=FOLDER_MENU,
         props={"Category": "ApplicationStatus", "Id": "fake-folder", "Title": "文件", "Status": "Active",
                "WindowId": 0, "IconName": "folder", "IconPixmap": NOPIX, "AttentionIconName": "",
                "ToolTip": tooltip("", "", ""), "Menu": "/MenuBar", "ItemIsMenu": True}),
    Item("alert", register="path", path="/org/ayatana/NotificationItem/alert", menu=ALERT_MENU, own_props=True,
         props={"Category": "Communications", "Id": "fake-alert", "Title": "提醒", "Status": "NeedsAttention",
                "WindowId": 0, "IconName": "dialog-information", "IconPixmap": NOPIX,
                "AttentionIconName": "dialog-warning", "AttentionIconPixmap": NOPIX, "ToolTip": tooltip("", "", ""),
                "Menu": "/org/ayatana/NotificationItem/alert/Menu", "ItemIsMenu": False}),
    Item("noact", register="service", wellknown="org.kde.StatusNotifierItem-%d-5" % PID, activate=False,
         menu=NOACT_MENU,
         props={"Category": "ApplicationStatus", "Id": "fake-noact", "Title": "无激活", "Status": "Active",
                "WindowId": 0, "IconName": "y700-fake-no-such-icon", "IconPixmap": NOPIX, "AttentionIconName": "",
                "ToolTip": tooltip("", "", ""), "Menu": "/MenuBar", "ItemIsMenu": False}),
    # KStatusNotifierItem's "no menu" path
    Item("passive", register="service/path",
         props={"Category": "ApplicationStatus", "Id": "fake-passive", "Title": "被动", "Status": "Passive",
                "WindowId": 0, "IconName": "user-idle", "IconPixmap": NOPIX, "AttentionIconName": "",
                "ToolTip": tooltip("", "", ""), "Menu": "/NO_DBUSMENU", "ItemIsMenu": False}),
]
PRELOAD = 3           # ITEMS[:3] are in the watcher's list before it takes its name


def plain(title, **kw):
    return dict({"Category": "ApplicationStatus", "Id": "fake-" + title, "Title": title, "Status": "Active",
                 "WindowId": 0, "IconName": "", "IconPixmap": NOPIX, "AttentionIconName": "",
                 "ToolTip": tooltip("", "", ""), "Menu": "/NO_DBUSMENU", "ItemIsMenu": False}, **kw)


# only on Spawn
EXTRA = [
    Item("anim", register="service/path", menu={0: (ROOT, [1]), 1: (mi("停止动画"), [])},
         props=plain("动画", Menu="/MenuBar")),
    Item("slow", register="service/path", activate="hang", props=plain("慢")),
    Item("nomenu", register="service/path", activate=False, props=plain("无菜单", Menu="/")),
]
BY_NAME = {i.name: i for i in ITEMS + EXTRA}
HUES = [(0xd9, 0x77, 0x57), (0xe8, 0xb3, 0x3c), (0x5c, 0xb8, 0x5c), (0x3c, 0x9c, 0xe8), (0x8e, 0x5c, 0xe8),
        (0xe8, 0x5c, 0x9c)]
FRAMES = []           # anim's icon frames, made on its first Spawn (a few tenths of a second of Python)


def animate(it):
    """NewIcon 30 times a second with the next frame as IconPixmap, until its connection closes"""
    it.frame = 0

    def tick():
        if not it.conn or it.conn.is_closed():
            return False
        it.frame = (it.frame + 1) % len(FRAMES)
        it.props["IconPixmap"] = FRAMES[it.frame]
        it.emit("NewIcon")
        return True
    GLib.timeout_add(33, tick)

# ---------------- control

CONTROL_XML = """<node><interface name="fyi.y700.FakeSni">
<method name="SetStatus"><arg type="s" direction="in"/><arg type="s" direction="in"/></method>
<method name="SetTitle"><arg type="s" direction="in"/><arg type="s" direction="in"/></method>
<method name="SetIcon"><arg type="s" direction="in"/><arg type="s" direction="in"/></method>
<method name="Remove"><arg type="s" direction="in"/></method>
<method name="Relayout"><arg type="s" direction="in"/></method>
<method name="Spawn"><arg type="s" direction="in"/></method>
<method name="Quit"/>
</interface></node>"""


def control_call(conn, sender, path, iface, method, params, inv):
    args = params.unpack()
    out("FAKESNI", method, *args)
    if method == "Quit":
        inv.return_value(None)
        GLib.timeout_add(100, loop.quit)
        return
    it = BY_NAME.get(args[0])
    if method == "Spawn":
        if it not in EXTRA or (it.conn and not it.conn.is_closed()):
            inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "not a Spawn item, or up already: " + args[0])
            return
        if it.name == "anim":
            if not FRAMES:
                FRAMES.extend(pixmaps([(64, 64, disc(64, rgb))]) for rgb in HUES)
            it.props["IconPixmap"] = FRAMES[0]
        it.connect()
        it.register(lambda: out("FAKESNI spawned", it.name))
        if it.name == "anim":
            animate(it)
        inv.return_value(None)
        return
    if not it or not it.conn or it.conn.is_closed():
        inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "no live item " + args[0])
        return
    if method == "SetStatus":
        it.props["Status"] = args[1]
        it.emit("NewStatus", GLib.Variant("(s)", (args[1],)))
    elif method == "SetTitle":
        it.props["Title"] = args[1]
        it.emit("NewTitle")
    elif method == "SetIcon":
        it.props["IconName"] = args[1]
        it.emit("NewIcon")
    elif method == "Remove":
        it.conn.close_sync(None)
    elif method == "Relayout":
        if not it.menu:
            inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", args[0] + " has no menu")
            return
        m = it.menu
        if it.name == "claude":
            m.nodes[15] = (mi("用量：51%", enabled=False), [])
        m.rev += 1
        it.emit("LayoutUpdated", GLib.Variant("(ui)", (m.rev, 0)), it.menu_path, "com.canonical.dbusmenu")
    inv.return_value(None)


# ---------------- start: the objects first, then the names (a host reacting to the watcher's name finds it whole)

bus.register_object("/StatusNotifierWatcher", Gio.DBusNodeInfo.new_for_xml(WATCHER_XML).interfaces[0],
                    watcher_call, watcher_prop, None)
bus.register_object("/FakeSni", Gio.DBusNodeInfo.new_for_xml(CONTROL_XML).interfaces[0], control_call, None, None)
bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", None,
                     Gio.DBusSignalFlags.NONE, owner_changed)
# apps that were up before this watcher (and the host) came: in its list from the start, as kded6 has them for a
# control centre started after them; they do not register again
for it in ITEMS[:PRELOAD]:
    entry, svc = it.connect()
    entries.append((entry, svc))
    out("SNI watcher preloaded", entry)
for name in (WATCHER, "fyi.y700.FakeSni"):
    r = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                      GLib.Variant("(su)", (name, 4)), None, Gio.DBusCallFlags.NONE, 2000, None)   # 4 = DO_NOT_QUEUE
    if r.unpack()[0] != 1:
        out("FAKESNI REFUSED: %s already has an owner (kded6? another fake-sni.py?)" % name)
        sys.exit(2)
out("FAKESNI watcher up as", bus.get_unique_name(), "pid", PID)


def start(i, waited=False):
    if i == len(ITEMS):
        out("FAKESNI READY %d items" % len(entries))
        return
    if i == PRELOAD and not hosts and not waited:
        # the rest once a host is there (it has read the list by then, these come by the Registered signal)
        fired = []

        def go():
            if not fired:
                fired.append(1)
                if not hosts:
                    out("FAKESNI no host after 3 s")
                GLib.timeout_add(300, lambda: (start(i, True), False)[1])
        on_host.append(go)
        GLib.timeout_add(3000, lambda: (go(), False)[1])
        return
    ITEMS[i].connect()
    ITEMS[i].register(lambda: start(i + 1, waited))


start(PRELOAD)
loop.run()
out("FAKESNI QUIT")
