// Y700 home gesture (owner, 2026-10-17: "从最底部往上一滑，能够退出或者最小化全屏的窗口"):
// a touch swipe up from the bottom screen edge minimizes the active window - fullscreen or not; a
// fullscreen one stays fullscreen and comes back as it was from the taskbar (the owner's choice).
//
// The swipe is KWin's own touch screen edge, not ours: ScreenEdgeInputFilter runs ahead of every
// window, so the touch is consumed (the game or video under the finger never sees it), the edge
// follows the rotation, a second finger cancels it, it fires on lift after 44 logical px up, and
// KWin's screenedge effect draws the glow while the finger moves. Over a fullscreen window KWin
// blocks all edges unless kwinrc [ScreenEdges] RemainActiveOnFullscreen=true (install.sh sets it).
//
// Off while the on-screen keyboard (or our control centre overlay) is mapped: the edge strip
// (kwinrc TouchTarget, 8 logical px) would eat taps on the keyboard's bottom row, and a flick up
// there is a key gesture; with the control centre open the app to minimize is hidden behind it.
// Both unmap when closed, so windowAdded/windowRemoved say when.
//
// 2026-10-21: the bottom edge now belongs to the y700-taskswitcher effect (Plasma Mobile's task
// switcher: flick = home, swipe and hold = cards); taskswitcher/install.sh sets kwinrc
// [Script-y700-home] BottomEdge=false and this script keeps only the y700-home-minimize shortcut.
// Two touch callbacks on one edge would both fire. BottomEdge=true (the default) restores the old edge.

const ElectricBottom = 4;   // KWin ElectricBorder: Top 0, TopRight 1, Right 2, BottomRight 3, Bottom 4
const BLOCKERS = ["y700-osk", "y700-control-center"];   // layer-shell surfaces: resourceClass = executable

const EDGE = String(readConfig("BottomEdge", true)) !== "false";   // kwinrc gives strings
let armed = false;

function isBlocker(w) {
    return w.inputMethod || BLOCKERS.indexOf(w.resourceClass) >= 0;   // inputMethod: fcitx5-osk fallback
}

// windowRemoved fires while the window may still be listed, windowAdded maybe before: say which one
function blocked(added, removed) {
    if (added && isBlocker(added)) {
        return true;
    }
    return workspace.windowList().some(function (w) { return w !== removed && isBlocker(w); });
}

function leave() {
    let w = workspace.activeWindow;
    while (w && w.transient && w.transientFor) {   // a dialog: its main window
        w = w.transientFor;
    }
    if (!w || !w.normalWindow || w.minimized || !w.minimizable) {
        print("y700-home: nothing to minimize (" + (w ? w.resourceClass : "no active window") + ")");
        return;
    }
    const full = w.fullScreen;
    w.minimized = true;
    print("y700-home: minimized " + w.resourceClass + (full ? " (fullscreen)" : ""));
}

function update(added, removed) {
    const want = EDGE && !blocked(added, removed);
    if (want === armed) {
        return;
    }
    if (want) {
        registerTouchScreenEdge(ElectricBottom, leave);
    } else {
        unregisterTouchScreenEdge(ElectricBottom);
    }
    armed = want;
    print("y700-home: bottom edge " + (armed ? "on" : "off"));
}

// The same action without the edge, for the G9 gamepad's home key double tap (y700-padkeys, 2026-10-20:
// in the pad's frame the bottom edge can't be swiped). No default key; invoked over D-Bus with
// org.kde.kglobalaccel /component/kwin invokeShortcut "y700-home-minimize". Not tied to `armed`.
registerShortcut("y700-home-minimize", "Y700: minimize the active window", "", leave);

workspace.windowAdded.connect(function (w) { if (isBlocker(w)) update(w, null); });
workspace.windowRemoved.connect(function (w) { if (isBlocker(w)) update(null, w); });
update(null, null);
if (!EDGE) {
    print("y700-home: bottom edge left to y700-taskswitcher (BottomEdge=false)");
}
