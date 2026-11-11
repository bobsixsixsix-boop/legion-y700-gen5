#!/usr/bin/env python3
# kbzone.py HEIGHT: a dark band along the bottom of the screen, HEIGHT px high, that reserves its height (a layer-shell
# exclusive zone), as the on-screen keyboard docked does (linux/osk/src/osk.cpp setPlacement): KWin's work area loses
# that much while it runs; killed, the band and the zone go. For sb-bed scenarios (stagestrip.sh, 11-09). Not the
# keyboard: no y700-osk class, so the stage script does not take it for a blocker (the column stays up).
# gtk4-layer-shell must come before libwayland-client (its 1.x shims it):
#   LD_PRELOAD=libgtk4-layer-shell.so.0 python3 kbzone.py 389 &
import sys

import gi
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, GLib, Gtk, Gtk4LayerShell as LS  # noqa: E402

h = int(sys.argv[1])
w = Gtk.Window(title="kbzone")
LS.init_for_window(w)
LS.set_layer(w, LS.Layer.TOP)
for e in (LS.Edge.BOTTOM, LS.Edge.LEFT, LS.Edge.RIGHT):
    LS.set_anchor(w, e, True)
LS.set_exclusive_zone(w, h)
w.set_default_size(1, h)   # the width comes from the anchors
css = Gtk.CssProvider()
css.load_from_string("window { background: #2b2d33; }")
Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
w.present()
print(f"kbzone: up, {h} px", flush=True)
GLib.MainLoop().run()
