#!/usr/bin/env python3
# sb-wall.py IMAGE: the wallpaper of the headless dock test bed (sb-bed.sh), a background-layer surface over the
# whole screen with IMAGE scaled to cover it (Plasma's desktop is not started there). gtk4-layer-shell has to be
# loaded before libwayland-client: run with LD_PRELOAD=libgtk4-layer-shell.so (sb-bed.sh does).
# Namespace "desktop" (10-22): KWin types a layer-shell window by its namespace, and only a NET::Desktop window is
# what the task switcher's DesktopBackground paints on its desktop layer (plasmashell's desktop uses the same
# name). Without it the effect's scene had a black floor where the wallpaper should be, and dock-glass.sh could
# not see the dock's glass against anything.
import sys

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gtk, Gtk4LayerShell as LS  # noqa: E402


def activate(app):
    w = Gtk.ApplicationWindow(application=app)
    LS.init_for_window(w)
    LS.set_namespace(w, "desktop")
    LS.set_layer(w, LS.Layer.BACKGROUND)
    for e in (LS.Edge.TOP, LS.Edge.BOTTOM, LS.Edge.LEFT, LS.Edge.RIGHT):
        LS.set_anchor(w, e, True)
    LS.set_exclusive_zone(w, -1)
    pic = Gtk.Picture.new_for_filename(sys.argv[1])
    pic.set_content_fit(Gtk.ContentFit.COVER)
    w.set_child(pic)
    w.present()


app = Gtk.Application(application_id="fyi.y700.SbWall")
app.connect("activate", activate)
app.run([])
