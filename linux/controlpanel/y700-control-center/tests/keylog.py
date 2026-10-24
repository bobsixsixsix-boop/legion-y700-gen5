#!/usr/bin/env python3
# a plain window that logs every key press to /tmp/y700-keylog.txt (for the back-key test)
import sys, gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk
out = open("/tmp/y700-keylog.txt", "a", buffering=1)
w = Gtk.Window(title="keylog")
w.set_wmclass("keylog", "keylog")
w.add(Gtk.Label(label="keylog"))
def key(_, ev):
    mods = "Alt+" if ev.state & Gdk.ModifierType.MOD1_MASK else ""
    out.write(mods + Gdk.keyval_name(ev.keyval) + "\n")
w.connect("key-press-event", key)
w.connect("destroy", Gtk.main_quit)
w.show_all()
Gtk.main()
