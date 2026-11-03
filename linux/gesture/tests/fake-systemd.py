#!/usr/bin/env python3
# fake-systemd.py (10-31, ts-scenarios/appquit.sh): systemd's StartUnit on the ts-bed's own bus, for the task
# switcher's AppQuit (taskswitcher/ui/AppQuit.qml), which starts y700-appquit@PID_WINPIDS.service when a swiped
# card's window is gone. Owns org.freedesktop.systemd1 with /org/freedesktop/systemd1
# org.freedesktop.systemd1.Manager StartUnit(ss) -> o, the real signature: GDBus checks it as strictly as sd-bus
# does, so a wrong type from QML (a JS number goes out as int32) fails here as it would on the tablet. A name that is
# not y700-appquit@DIGITS[_DIGITS...].service within systemd's 255 characters, or a job mode systemd does not know,
# gets InvalidArgs as from systemd. Records the call, starts nothing. For the bed ONLY: refuses the user bus
# /run/user/UID/bus and a name that already has an owner. stdout (the bed's log), one flushed line per event:
# "FAKESD StartUnit NAME MODE", "FAKESD REJECTED NAME MODE", "FAKESD up as NAME pid PID".
import os
import re
import sys
import warnings
from gi.repository import Gio, GLib

warnings.filterwarnings("ignore", category=DeprecationWarning)   # register_object, as fake-sni.py


def out(*a):
    print(*a, flush=True)


ADDR = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
if "/run/user/%d/bus" % os.getuid() in ADDR:
    out("FAKESD REFUSED: this is the real session bus (%s); fake-systemd.py runs in the ts-bed only" % ADDR)
    sys.exit(2)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

XML = """<node><interface name="org.freedesktop.systemd1.Manager">
<method name="StartUnit"><arg name="name" type="s" direction="in"/><arg name="mode" type="s" direction="in"/>
<arg name="job" type="o" direction="out"/></method>
</interface></node>"""
jobs = [0]


MODES = {"replace", "fail", "isolate", "ignore-dependencies", "ignore-requirements", "flush", "triggering",
         "restart-dependencies", "lenient"}


def call(conn, sender, path, iface, method, params, inv):
    name, mode = params.unpack()
    if not re.fullmatch(r"y700-appquit@[0-9]+(?:_[0-9]+)*[.]service", name) or len(name) > 255 or mode not in MODES:
        out("FAKESD REJECTED", name, mode)
        inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "not a unit name / job mode systemd takes")
        return
    jobs[0] += 1
    out("FAKESD StartUnit", name, mode)
    inv.return_value(GLib.Variant("(o)", ("/org/freedesktop/systemd1/job/%d" % jobs[0],)))


bus.register_object("/org/freedesktop/systemd1", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
r = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                  GLib.Variant("(su)", ("org.freedesktop.systemd1", 4)), None, Gio.DBusCallFlags.NONE, 2000, None)   # 4 = DO_NOT_QUEUE
if r.unpack()[0] != 1:
    out("FAKESD REFUSED: org.freedesktop.systemd1 already has an owner")
    sys.exit(2)
out("FAKESD up as", bus.get_unique_name(), "pid", os.getpid())
GLib.MainLoop().run()
