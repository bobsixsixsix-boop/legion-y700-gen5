#!/usr/bin/env python3
# detail.py: a fullscreen window full of fine detail (2 px noise) for blur-flicker.sh to pull the curtain over.
# The verdict compares the sharpness under the curtain with the first frame's, so the first frame must have
# plenty: the wallpaper's top strip has next to none (10-22: sharp 180 over the region, the blur's own noise
# alone scored higher than that). Runs as the session user until killed. A normal window, so it sits under the
# overlay-layer pull strip and curtain.
import gi

gi.require_version("Gtk", "4.0")
import numpy as np
from gi.repository import Gdk, GLib, Gtk

rng = np.random.default_rng(7)
noise = rng.integers(0, 2, size=(502, 800), dtype=np.uint8) * 255   # half the logical size: 2 px blocks when stretched
rgb = np.ascontiguousarray(np.repeat(noise[:, :, None], 3, axis=2))
texture = Gdk.MemoryTexture.new(rgb.shape[1], rgb.shape[0], Gdk.MemoryFormat.R8G8B8, GLib.Bytes.new(rgb.tobytes()), rgb.shape[1] * 3)


def activate(app):
    win = Gtk.ApplicationWindow(application=app, title="y700-detail")
    pic = Gtk.Picture.new_for_paintable(texture)
    pic.set_content_fit(Gtk.ContentFit.FILL)
    win.set_child(pic)
    win.fullscreen()
    win.present()


app = Gtk.Application(application_id="fyi.y700.detail")
app.connect("activate", activate)
app.run(None)
