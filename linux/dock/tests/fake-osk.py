#!/usr/bin/env python3
# fake-osk.py (10-30, kbtile.sh): the keyboard's D-Bus face on the sb-bed's own bus, for the control centre's 「键盘」
# tile. Owns fyi.fortime.Fcitx5Osk with /fyi/fortime/Fcitx5Osk/Controller fyi.fortime.Fcitx5Osk.Controller1
# (ForceShow, Show, Hide: the methods the tile and the keyboard's other callers use; linux/osk/src/osk.cpp), so the
# bed's bus never activates the real keyboard: its XDG_DATA_DIRS reach ~user/.local/share, where the activation
# file of the real y700-osk lives. Start it before anything calls that name. For the bed ONLY: refuses the user bus
# /run/user/UID/bus and a name that already has an owner.
# Modes (fyi.y700.FakeOsk /FakeOsk fyi.y700.FakeOsk SetMode s MODE): ok (the default: answers at once), fail (answers
# org.freedesktop.DBus.Error.Failed "fake-osk: refused"), mute (never answers: a hung keyboard; the caller's timeout),
# late (answers yes after 2 s: an answer arriving after the owner closed and opened the curtain again).
# stdout (the bed's log), one flushed line per event: "FAKEOSK <Method> from <sender> -> ok|fail|mute|late",
# "FAKEOSK late answered", "FAKEOSK mode MODE", "FAKEOSK up as NAME".
import os
import sys
import warnings
from gi.repository import Gio, GLib

warnings.filterwarnings("ignore", category=DeprecationWarning)   # register_object, as fake-sni.py


def out(*a):
    print(*a, flush=True)


ADDR = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
if "/run/user/%d/bus" % os.getuid() in ADDR:
    out("FAKEOSK REFUSED: this is the real session bus (%s); fake-osk.py runs in the sb-bed only" % ADDR)
    sys.exit(2)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

OSK_XML = """<node><interface name="fyi.fortime.Fcitx5Osk.Controller1">
<method name="ForceShow"/><method name="Show"/><method name="Hide"/>
</interface></node>"""
CONTROL_XML = """<node><interface name="fyi.y700.FakeOsk">
<method name="SetMode"><arg name="mode" type="s" direction="in"/></method>
</interface></node>"""
mode = ["ok"]
held = []    # mute: the invocations kept unanswered (a dropped one would answer NoReply at once)


def osk_call(conn, sender, path, iface, method, params, inv):
    m = mode[0]
    out("FAKEOSK", method, "from", sender, "->", m)
    if m == "ok":
        inv.return_value(None)
    elif m == "fail":
        inv.return_dbus_error("org.freedesktop.DBus.Error.Failed", "fake-osk: refused")
    elif m == "late":
        def answer():
            out("FAKEOSK late answered")
            inv.return_value(None)
            return False
        GLib.timeout_add(2000, answer)
    else:
        held.append(inv)


def control_call(conn, sender, path, iface, method, params, inv):
    m = params.unpack()[0]
    if m not in ("ok", "fail", "mute", "late"):
        inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "mode: ok | fail | mute | late")
        return
    mode[0] = m
    out("FAKEOSK mode", m)
    inv.return_value(None)


bus.register_object("/fyi/fortime/Fcitx5Osk/Controller", Gio.DBusNodeInfo.new_for_xml(OSK_XML).interfaces[0],
                    osk_call, None, None)
bus.register_object("/FakeOsk", Gio.DBusNodeInfo.new_for_xml(CONTROL_XML).interfaces[0], control_call, None, None)
for name in ("fyi.fortime.Fcitx5Osk", "fyi.y700.FakeOsk"):
    r = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                      GLib.Variant("(su)", (name, 4)), None, Gio.DBusCallFlags.NONE, 2000, None)   # 4 = DO_NOT_QUEUE
    if r.unpack()[0] != 1:
        out("FAKEOSK REFUSED: %s already has an owner" % name)
        sys.exit(2)
out("FAKEOSK up as", bus.get_unique_name(), "pid", os.getpid())
GLib.MainLoop().run()
