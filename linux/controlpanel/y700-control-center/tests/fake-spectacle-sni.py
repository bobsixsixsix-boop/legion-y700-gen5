#!/usr/bin/env python3
# Stand-in for a recording Spectacle, to test Backend::stopRecording without recording the screen (10-22).
# Owns org.kde.Spectacle, exports a StatusNotifierItem on the same connection, registers it with the watcher
# and prints ACTIVATED x y when something calls its Activate (= a click on the tray icon = Spectacle's "stop").
# Exits after the first Activate or after 10 s (prints TIMEOUT). Run as the session user:
#   python3 fake-spectacle-sni.py & sleep 1; qdbus6 fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter.stopRecording
# Refuses to start while a real Spectacle owns the name (it would not get the name anyway).
import sys
from gi.repository import Gio, GLib

XML = """<node><interface name="org.kde.StatusNotifierItem">
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<property name="Id" type="s" access="read"/><property name="Status" type="s" access="read"/>
</interface></node>"""
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
loop = GLib.MainLoop()
rc = [1]

def call(conn, sender, path, iface, method, params, inv):
    print("ACTIVATED", *params.unpack(), "from", sender, flush=True)
    inv.return_value(None); rc[0] = 0; GLib.idle_add(loop.quit)

def prop(conn, sender, path, iface, name):
    return GLib.Variant("s", {"Id": "spectacle", "Status": "Active"}[name])

bus.register_object("/StatusNotifierItem", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, prop, None)
r = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                  GLib.Variant("(su)", ("org.kde.Spectacle", 4)), None, 0, -1, None)   # 4 = DO_NOT_QUEUE
if r.unpack()[0] != 1:
    print("NAME_TAKEN: a real Spectacle is running"); sys.exit(2)
bus.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
              "RegisterStatusNotifierItem", GLib.Variant("(s)", (bus.get_unique_name(),)), None, 0, -1, None)
print("READY", bus.get_unique_name(), flush=True)
GLib.timeout_add_seconds(10, lambda: (print("TIMEOUT", flush=True), loop.quit()))
loop.run()
sys.exit(rc[0])
