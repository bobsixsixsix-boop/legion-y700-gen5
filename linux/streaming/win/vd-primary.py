#!/usr/bin/env python3
r"""Make Apollo's virtual display the Windows primary display (and back).

Steam Big Picture (and most fullscreen games) open on the primary display.  Apollo's
own "Enforce Virtual Display Primary" does not work on this PC (its UI says "Broken on
Windows 11 24H2"; this is build 26300): the SudoMaker display stays secondary at the
bottom right and Big Picture opens on the physical 2560x1440 monitor instead.

usage (py -3, no admin needed):
  vd-primary.py            make the SudoMaker virtual display primary; remembers the old
                           primary in %TEMP%\vd-primary-prev.txt
  vd-primary.py --restore  make the remembered (or the first physical) display primary
  vd-primary.py --status   list the displays
As Apollo prep command (app "Virtual Display" / global): do = the plain call,
undo = --restore, so the physical monitor is primary again before the display goes away.
Never exits non-zero there (a failing prep "do" aborts the app); with pythonw it logs to
%TEMP%\vd-primary.log.
Primary = the display at (0, 0): every display is shifted by the same offset, the
layout itself stays as it was.
"""
import ctypes, ctypes.wintypes as wt, os, struct, sys, time
from pathlib import Path

u = ctypes.windll.user32
PREV = Path(os.environ.get("TEMP", ".")) / "vd-primary-prev.txt"
VD_ADAPTER = "SudoMaker Virtual Display Adapter"
ENUM_CURRENT_SETTINGS = -1
ATTACHED, PRIMARY = 0x1, 0x4


class DISPLAY_DEVICEW(ctypes.Structure):
    _fields_ = [("cb", wt.DWORD), ("DeviceName", wt.WCHAR * 32), ("DeviceString", wt.WCHAR * 128),
                ("StateFlags", wt.DWORD), ("DeviceID", wt.WCHAR * 128), ("DeviceKey", wt.WCHAR * 128)]


class DEVMODEW(ctypes.Structure):  # display variant of the union
    _fields_ = [("dmDeviceName", wt.WCHAR * 32), ("dmSpecVersion", wt.WORD), ("dmDriverVersion", wt.WORD),
                ("dmSize", wt.WORD), ("dmDriverExtra", wt.WORD), ("dmFields", wt.DWORD),
                ("dmPositionX", wt.LONG), ("dmPositionY", wt.LONG),
                ("dmDisplayOrientation", wt.DWORD), ("dmDisplayFixedOutput", wt.DWORD),
                ("dmColor", ctypes.c_short), ("dmDuplex", ctypes.c_short), ("dmYResolution", ctypes.c_short),
                ("dmTTOption", ctypes.c_short), ("dmCollate", ctypes.c_short), ("dmFormName", wt.WCHAR * 32),
                ("dmLogPixels", wt.WORD), ("dmBitsPerPel", wt.DWORD), ("dmPelsWidth", wt.DWORD),
                ("dmPelsHeight", wt.DWORD), ("dmDisplayFlags", wt.DWORD), ("dmDisplayFrequency", wt.DWORD),
                ("dmICMMethod", wt.DWORD), ("dmICMIntent", wt.DWORD), ("dmMediaType", wt.DWORD),
                ("dmDitherType", wt.DWORD), ("dmReserved1", wt.DWORD), ("dmReserved2", wt.DWORD),
                ("dmPanningWidth", wt.DWORD), ("dmPanningHeight", wt.DWORD)]


def displays():
    out, i = [], 0
    while True:
        d = DISPLAY_DEVICEW(); d.cb = ctypes.sizeof(d)
        if not u.EnumDisplayDevicesW(None, i, ctypes.byref(d), 0):
            return out
        i += 1
        if not d.StateFlags & ATTACHED:
            continue
        dm = DEVMODEW(); dm.dmSize = ctypes.sizeof(dm)
        if not u.EnumDisplaySettingsExW(d.DeviceName, ENUM_CURRENT_SETTINGS, ctypes.byref(dm), 0):
            continue
        out.append({"name": d.DeviceName, "adapter": d.DeviceString, "primary": bool(d.StateFlags & PRIMARY),
                    "x": dm.dmPositionX, "y": dm.dmPositionY, "w": dm.dmPelsWidth, "h": dm.dmPelsHeight,
                    "hz": dm.dmDisplayFrequency})


def make_primary(name):
    """Shift every active source so that `name` sits at (0, 0) and apply it with the CCD
    API.  The legacy ChangeDisplaySettingsEx(CDS_SET_PRIMARY) route returns
    DISP_CHANGE_FAILED for both virtual displays on this build (probably what broke
    Apollo's own option)."""
    ds = displays()
    new = next((d for d in ds if d["name"] == name), None)
    if new is None:
        sys.exit(f"no attached display {name}")
    if new["primary"]:
        print(f"primary -> {name}: already")
        return 0
    QDC_ONLY_ACTIVE_PATHS = 0x2
    # APPLY | USE_SUPPLIED | ALLOW_CHANGES, deliberately without SAVE_TO_DATABASE (0x200): with it Windows
    # stored "VD primary at (0,0)" for this display set, and every later Apollo session came up with the VD as
    # primary even without this script -- the host then rendered the test page at the VD's pace (2026-10-20,
    # runs h120-* contaminated). Unsaved, a forgotten --restore ends with the session.
    SDC_FLAGS = 0x80 | 0x20 | 0x400
    PATH_SIZE, MODE_SIZE = 72, 64
    np_, nm = ctypes.c_uint32(), ctypes.c_uint32()
    if u.GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, ctypes.byref(np_), ctypes.byref(nm)):
        sys.exit("GetDisplayConfigBufferSizes failed")
    paths = (ctypes.c_ubyte * (PATH_SIZE * np_.value))()
    modes = (ctypes.c_ubyte * (MODE_SIZE * nm.value))()
    r = u.QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ctypes.byref(np_), paths, ctypes.byref(nm), modes, None)
    if r:
        sys.exit(f"QueryDisplayConfig failed: {r}")
    ox, oy = new["x"], new["y"]
    buf = memoryview(modes).cast("B")
    moved = 0
    for i in range(nm.value):
        o = i * MODE_SIZE
        info_type = struct.unpack_from("<I", buf, o)[0]
        if info_type != 1:  # DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE: width, height, format, x, y at +16
            continue
        x, y = struct.unpack_from("<ii", buf, o + 28)
        struct.pack_into("<ii", buf, o + 28, x - ox, y - oy)
        moved += 1
    r = u.SetDisplayConfig(np_.value, paths, nm.value, modes, SDC_FLAGS)
    ok = any(d["name"] == name and d["primary"] for d in displays())
    print(f"primary -> {name}: {'ok' if ok else 'FAILED'} (SetDisplayConfig {r}, {moved} sources shifted)")
    return 0 if ok else 1


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--status":
        for d in displays():
            print(f"{d['name']:14s} {d['w']}x{d['h']}@{d['hz']} at ({d['x']},{d['y']}) "
                  f"{'PRIMARY ' if d['primary'] else ''}{d['adapter']}")
        return 0
    # as an Apollo global prep command this runs for every app, and a failing "do"
    # aborts the launch: never fail, just log (pythonw has no console)
    try:
        if arg == "--restore":
            ds = displays()
            want = PREV.read_text().strip() if PREV.exists() else ""
            if not any(d["name"] == want for d in ds):
                want = next((d["name"] for d in ds if d["adapter"] != VD_ADAPTER), "")
            if want:
                make_primary(want)
            return 0
        for _ in range(20):  # Apollo creates the display just before the prep commands
            ds = displays()
            vd = [d for d in ds if d["adapter"] == VD_ADAPTER]
            if vd:
                break
            time.sleep(0.25)
        else:
            print("no SudoMaker virtual display attached, nothing to do")
            return 0
        cur = next((d["name"] for d in ds if d["primary"]), "")
        if cur and cur != vd[-1]["name"]:
            PREV.write_text(cur)
        make_primary(vd[-1]["name"])
    except SystemExit as e:
        print(f"error: {e}")
    return 0


if __name__ == "__main__":
    if sys.stdout is None or "pythonw" in sys.executable.lower():  # run by Apollo: log to a file
        sys.stdout = sys.stderr = open(Path(os.environ.get("TEMP", ".")) / "vd-primary.log", "a", buffering=1)
        print(time.strftime("%F %T"), sys.argv[1:])
    sys.exit(main())
