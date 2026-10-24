// Window shell: a layer-shell surface (configured in C++) that slides the keyboard in and out,
// and keeps the compositor-side geometry (anchors/margins/exclusive zone, blur, input region)
// in step with the QML layout.
import QtQuick
import "."
import QtQuick.Window

Window {
    id: win
    visible: false
    color: "transparent"
    flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus
    width: kbd.implicitWidth
    height: kbd.implicitHeight

    Item {
        id: slider
        width: win.width; height: win.height
        // slide: 260 ms drawer curve in, 200 ms out (the design's .kb / .kb.hidden)
        property real off: osk.shown ? 0 : height + 24
        y: off
        opacity: osk.shown ? 1 : 0
        Behavior on y { NumberAnimation { id: slideAnim; duration: osk.shown ? 260 : 200; easing.type: osk.shown ? Easing.BezierSpline : Easing.InCubic
                                          easing.bezierCurve: [0.32, 0.72, 0, 1, 1, 1] } }
        Behavior on opacity { NumberAnimation { duration: 200 } }
        onYChanged: if (!osk.shown && y >= height) osk.hideDone()

        Keyboard {
            id: kbd
            width: win.width; height: win.height
            screenW: osk.screenWidth
        }
    }

    // ---- compositor geometry ----
    function sync() {
        var fl = kbd.mode === "float"
        if (fl) {   // keep the floating keyboard on screen (rotation, portrait, a taller keyboard)
            var fx = Math.max(0, Math.min(osk.screenWidth - kbd.kbW, kbd.prefs.floatX))
            var fy = Math.max(0, Math.min(osk.screenHeight - kbd.kbH, kbd.prefs.floatY))
            if (fx !== kbd.prefs.floatX) kbd.prefs.floatX = fx
            if (fy !== kbd.prefs.floatY) kbd.prefs.floatY = fy
        }
        osk.setPlacement(fl, Math.round(kbd.prefs.floatX - kbd.fpad), Math.round(kbd.prefs.floatY - kbd.fpad),
                         Math.round(kbd.implicitWidth), Math.round(kbd.implicitHeight), fl ? 0 : Math.round(kbd.kbH))
        var u = kbd.u, f = kbd.fpad, W = kbd.kbW, H = kbd.kbH, r = 20 * u, rects
        if (fl) rects = [{ x: f, y: f, w: W, h: H, tl: r, tr: r, bl: r, br: r }]
        else if (kbd.splitGlassNow) {
            var half = kbd.splitHalfW, b = kbd.bandH
            rects = [{ x: 0, y: 0, w: W, h: b, tl: r, tr: r, bl: 0, br: 0 },
                     { x: 0, y: b - 1, w: half, h: H - b + 1, tl: 0, tr: 0, bl: 0, br: 18 * u },
                     { x: W - half, y: b - 1, w: half, h: H - b + 1, tl: 0, tr: 0, bl: 18 * u, br: 0 }]
        } else rects = [{ x: 0, y: 0, w: W, h: H, tl: r, tr: r, bl: 0, br: 0 }]
        osk.setRegions(rects, Theme.glass)
    }
    Timer { id: syncLater; interval: 0; onTriggered: win.sync() }
    function queueSync() { syncLater.restart() }
    Connections {
        target: kbd
        function onImplicitWidthChanged() { win.queueSync() }
        function onImplicitHeightChanged() { win.queueSync() }
        function onModeChanged() { win.queueSync() }
        function onSplitGlassNowChanged() { win.queueSync() }
    }
    Connections { target: kbd.prefs; function onFloatXChanged() { win.sync() } function onFloatYChanged() { win.sync() } }
    Connections { target: Theme; function onSkinChanged() { win.queueSync() } }
    Connections { target: osk; function onShownChanged() { if (osk.shown) win.queueSync() } function onScreenChanged() { win.queueSync() } }
    Component.onCompleted: queueSync()
}
