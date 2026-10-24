// Y700: a touch swipe in from the left or the right screen edge = the back key (owner 10-21: 「左右两边向内
// 滑动应该是返回键」). The control centre sends the key (KWin's fake_input) and picks it per app: Alt+Left in
// browsers / file managers, Esc elsewhere (y700-control-center src/backend.cpp backKeys). Before 10-21 the
// right edge toggled the control centre; that is now pulled down from the top edge's right half by the
// control centre itself (a KWin touch edge cannot say where along the edge the finger was).
// ElectricRight = 2, ElectricLeft = 6 (KWin ElectricBorder enum). Mouse-push on the edges is left alone.
//
// Off while the on-screen keyboard or the control centre is mapped, as the bottom edge (linux/gesture
// kwin-script): KWin's edge strip (8 logical px) eats every touch that starts in it, so the keyboard's
// outermost keys and the open sheet's right edge would lose taps.
const EDGES = [2, 6];
const BLOCKERS = ["y700-osk", "y700-control-center"];   // layer-shell surfaces: resourceClass = executable
let armed = false;

function isBlocker(w) {
    return w.inputMethod || BLOCKERS.indexOf(w.resourceClass) >= 0;
}

function blocked(added, removed) {
    if (added && isBlocker(added)) {
        return true;
    }
    return workspace.windowList().some(function (w) { return w !== removed && isBlocker(w) && !w.deleted; });
}

function back() {
    let w = workspace.activeWindow;
    const cls = w ? String(w.resourceClass) : "";
    const full = !!(w && w.fullScreen);
    callDBus("fyi.y700.ControlCenter", "/ControlCenter", "fyi.y700.ControlCenter", "back", cls, full);
}

function update(added, removed) {
    const want = !blocked(added, removed);
    if (want === armed) {
        return;
    }
    EDGES.forEach(function (e) {
        if (want) {
            registerTouchScreenEdge(e, back);
        } else {
            unregisterTouchScreenEdge(e);
        }
    });
    armed = want;
    print("y700-edge: side edges (back) " + (armed ? "on" : "off"));
}

workspace.windowAdded.connect(function (w) { if (isBlocker(w)) update(w, null); });
workspace.windowRemoved.connect(function (w) { if (isBlocker(w)) update(null, w); });
update(null, null);
