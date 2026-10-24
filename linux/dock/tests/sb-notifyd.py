#!/usr/bin/env python3
# sb-notifyd.py: a stand-in for plasmashell's notification server in the sb-bed (there is no plasmashell there).
# Owns org.freedesktop.Notifications and does the part the control centre's notification centre relies on:
# Notify / CloseNotification / NotificationClosed, and plasmashell's org.kde.NotificationManager watcher
# interface (RegisterWatcher: every Notify is passed on to the watcher's /NotificationWatcher, like
# libnotificationmanager's server_p.cpp; InvokeAction emits ActionInvoked). No popups, no expiry.
# Logs one line per call to stdout ("notifyd: ...") for the bed's expects.
import sys
from gi.repository import Gio, GLib

XML = """
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/>
    </method>
    <method name="CloseNotification"><arg type="u" direction="in"/></method>
    <method name="GetCapabilities"><arg type="as" direction="out"/></method>
    <method name="GetServerInformation">
      <arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/>
    </method>
    <signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
    <signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
  </interface>
  <interface name="org.kde.NotificationManager">
    <method name="RegisterWatcher"/>
    <method name="UnRegisterWatcher"/>
    <method name="InvokeAction"><arg type="u" direction="in"/><arg type="s" direction="in"/></method>
  </interface>
</node>
"""

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
watchers = set()
next_id = [1]


def log(*a):
    print("notifyd:", *a, flush=True)


def emit(name, sig, args):
    bus.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", name,
                    GLib.Variant(sig, args))


def call(conn, sender, path, iface, method, params, inv):
    if method == "Notify":
        app, rid, icon, summary, body, actions, hints, timeout = params.unpack()
        nid = rid or next_id[0]
        if not rid:
            next_id[0] += 1
        log("Notify", nid, app, summary)
        for w in list(watchers):
            # server_p.cpp: (id, app name, replaces id, app icon, summary, raw body, actions, hints, timeout)
            # the hints go on as they came (a{sv} built back from Python would lose the variant types)
            args = GLib.Variant.new_tuple(GLib.Variant("u", nid), GLib.Variant("s", app), GLib.Variant("u", rid),
                                          GLib.Variant("s", icon), GLib.Variant("s", summary), GLib.Variant("s", body),
                                          GLib.Variant("as", actions), params.get_child_value(6), GLib.Variant("i", timeout))
            bus.call(w, "/NotificationWatcher", "org.kde.NotificationWatcher", "Notify", args,
                     None, Gio.DBusCallFlags.NONE, -1, None, None, None)
        inv.return_value(GLib.Variant("(u)", (nid,)))
    elif method == "CloseNotification":
        (nid,) = params.unpack()
        log("CloseNotification", nid)
        emit("NotificationClosed", "(uu)", (nid, 3))
        inv.return_value(None)
    elif method == "GetCapabilities":
        inv.return_value(GLib.Variant("(as)", (["body", "body-markup", "actions", "persistence"],)))
    elif method == "GetServerInformation":
        inv.return_value(GLib.Variant("(ssss)", ("sb-notifyd", "y700", "1", "1.2")))
    elif method == "RegisterWatcher":
        watchers.add(sender)
        log("RegisterWatcher", sender)
        inv.return_value(None)
    elif method == "UnRegisterWatcher":
        watchers.discard(sender)
        log("UnRegisterWatcher", sender)
        inv.return_value(None)
    elif method == "InvokeAction":
        nid, action = params.unpack()
        log("InvokeAction", nid, action)
        emit("ActionInvoked", "(us)", (nid, action))
        inv.return_value(None)
    else:
        inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)


node = Gio.DBusNodeInfo.new_for_xml(XML)
for iface in node.interfaces:
    bus.register_object("/org/freedesktop/Notifications", iface, call, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.Notifications", Gio.BusNameOwnerFlags.NONE,
                               lambda *a: log("owner"), lambda *a: (log("name lost"), sys.exit(1)))
GLib.MainLoop().run()
