#!/usr/bin/env python3
# ts-app.py NAME COLOR [CLASS] [--fullscreen|--small] [--refuse-close|--tray] [--delay MS]: a plain window for the headless task-switcher test bed
# (linux/gesture/tests/ts-bed.sh): a flat colour with its name in big letters, maximized unless asked
# otherwise, so screenshots show which card is which. CLASS sets the Wayland app id (e.g. steam_app_1 to
# get a guarded "game" card). --refuse-close ignores the close request, like an app asking "save changes?".
# --tray hides the window on close and keeps running, like Steam or Claude going to the tray, and shows it again
# on SIGUSR1, like a tap on its dock icon (10-31, ts-scenarios/appquit.sh). --delay MS maps the window MS ms after start (a slow app appearing while a gesture is under way).
import signal
import sys

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

name, color = sys.argv[1], sys.argv[2]
cls = sys.argv[3] if len(sys.argv) > 3 and not sys.argv[3].startswith("--") else "ts-" + name.lower()
GLib.set_prgname(cls)
w = Gtk.Window(title=name)
w.set_default_size(800, 500)
css = Gtk.CssProvider()
css.load_from_data(f"window {{ background: {color}; }} label {{ color: white; font-size: 96px; font-weight: 600; }}".encode())
Gtk.StyleContext.add_provider_for_screen(w.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
w.add(Gtk.Label(label=name))
if "--fullscreen" in sys.argv:
    w.fullscreen()
elif "--small" not in sys.argv:
    w.maximize()
if "--refuse-close" in sys.argv:
    w.connect("delete-event", lambda *a: True)
elif "--tray" in sys.argv:
    w.connect("delete-event", lambda *a: w.hide() or True)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, lambda: w.show_all() or True)
w.connect("destroy", Gtk.main_quit)
if "--delay" in sys.argv:
    GLib.timeout_add(int(sys.argv[sys.argv.index("--delay") + 1]), lambda: w.show_all() or False)
else:
    w.show_all()
Gtk.main()
