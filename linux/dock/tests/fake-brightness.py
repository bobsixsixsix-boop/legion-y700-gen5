#!/usr/bin/env python3
# fake-brightness.py (10-31, cc-stall.sh): PowerDevil's screen brightness on the sb-bed's own bus, for the control
# centre's brightness pill (src/backend.cpp readBrightness / flushBrightness). Owns org.kde.ScreenBrightness with
# /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display: properties Brightness and MaxBrightness (i; the
# level starts at START, default 6000 of 10000) and SetBrightness(iu) (sets it). No BrightnessChanged signal: what
# the pill shows at an opening is what that opening read. A PowerDevil that holds its name but does not answer is
# this process stopped (kill -STOP). For the bed ONLY: refuses the user bus /run/user/UID/bus and a name that
# already has an owner.
#   python3 fake-brightness.py [START]
# stdout (the bed's log), one flushed line per event: "FAKEBRIGHT get NAME -> VALUE", "FAKEBRIGHT SetBrightness V F",
# "FAKEBRIGHT up as NAME pid PID".
import os
import sys
import warnings
from gi.repository import Gio, GLib

warnings.filterwarnings("ignore", category=DeprecationWarning)   # register_object, as fake-sni.py


def out(*a):
    print(*a, flush=True)


ADDR = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
if "/run/user/%d/bus" % os.getuid() in ADDR:
    out("FAKEBRIGHT REFUSED: this is the real session bus (%s); fake-brightness.py runs in the sb-bed only" % ADDR)
    sys.exit(2)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

XML = """<node><interface name="org.kde.ScreenBrightness.Display">
<property name="Brightness" type="i" access="read"/><property name="MaxBrightness" type="i" access="read"/>
<method name="SetBrightness"><arg name="brightness" type="i" direction="in"/><arg name="flags" type="u" direction="in"/></method>
</interface></node>"""
level = {"Brightness": int(sys.argv[1]) if len(sys.argv) > 1 else 6000, "MaxBrightness": 10000}


def get(conn, sender, path, iface, name):    # GDBus answers Get and GetAll with this
    out("FAKEBRIGHT get", name, "->", level[name])
    return GLib.Variant("i", level[name])


def call(conn, sender, path, iface, method, params, inv):
    v, f = params.unpack()
    level["Brightness"] = max(0, min(level["MaxBrightness"], v))
    out("FAKEBRIGHT SetBrightness", v, f)
    inv.return_value(None)


bus.register_object("/org/kde/ScreenBrightness/display0", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, get, None)
r = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                  GLib.Variant("(su)", ("org.kde.ScreenBrightness", 4)), None, Gio.DBusCallFlags.NONE, 2000, None)   # 4 = DO_NOT_QUEUE
if r.unpack()[0] != 1:
    out("FAKEBRIGHT REFUSED: org.kde.ScreenBrightness already has an owner")
    sys.exit(2)
out("FAKEBRIGHT up as", bus.get_unique_name(), "pid", os.getpid())
GLib.MainLoop().run()
