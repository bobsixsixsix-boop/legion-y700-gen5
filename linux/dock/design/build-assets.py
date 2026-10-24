# Packs the wallpaper and app icons pulled from the tablet into assets.js for the mockup.
# The committed assets.js holds neutral placeholders only; run this on your own icons to get the real look.
# usage: py -3 -I build-assets.py <dir with wall-1600.jpg and icons/> <out assets.js>
import base64, io, json, os, sys
from PIL import Image

src, out = sys.argv[1], sys.argv[2]

def png_uri(path, size=144):
    im = Image.open(path).convert("RGBA")
    im.thumbnail((size, size), Image.LANCZOS)
    b = io.BytesIO(); im.save(b, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(b.getvalue()).decode()

def svg_uri(path):
    return "data:image/svg+xml;base64," + base64.b64encode(open(path, "rb").read()).decode()

icons = {}
d = os.path.join(src, "icons")
for f in sorted(os.listdir(d)):
    name, ext = os.path.splitext(f)
    p = os.path.join(d, f)
    icons[name] = png_uri(p) if ext == ".png" else svg_uri(p)

wall = "data:image/jpeg;base64," + base64.b64encode(open(os.path.join(src, "wall-1600.jpg"), "rb").read()).decode()
with open(out, "w", encoding="utf-8") as fh:
    fh.write("window.ICONS=" + json.dumps(icons) + ";\nwindow.WALL=" + json.dumps(wall) + ";\n")
print(len(icons), "icons,", os.path.getsize(out) // 1024, "KB")
