// The dock, OriginOS pad style (geometry and press motion: linux/dock/rom-report.md):
//   [all apps] [pinned …] | [up to 3 recent, not pinned]      icon 60, padding 16, gap 20, height 92, 18 above the edge,
//   radius 30, divider 2 × 22. No running dots (the reference dock has none).
// Material: KWin blur behind the rounded body plus a tint; OriginOS 7 glass on top of it (a 1 px light rim, a sheen,
// and light that spreads from the finger, 「点触光感」). In an app (revealed) the tint is the lighter in-app one.
// Shown on the desktop; in an app only after reveal(), then away again after 4 s untouched, or when an app comes up.
// The window is a band along the bottom of the screen; only the dock body takes touches (input mask), the rest
// falls through to the desktop or the app.
import QtQuick
import QtQuick.Shapes
import QtQuick.Window
import org.kde.kirigami as Kirigami

Window {
    id: win
    required property var shellRoot
    readonly property var r: shellRoot
    width: Screen.width
    height: 120
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "y700-dock"

    readonly property bool shown: r.ready && ((r.onDesktop && !r.gridOpen) || r.revealed)
    readonly property bool inApp: !r.onDesktop
    // the body slides down out of the window to go away; the window is unmapped once it is out
    property real away: shown ? 0 : 130
    Behavior on away {
        NumberAnimation {
            // coming: the drawer curve; going: the move curve, quicker
            duration: win.shown ? 320 : 220
            easing.type: Easing.BezierSpline
            easing.bezierCurve: win.shown ? [0.32, 0.72, 0, 1, 1, 1] : [0.25, 0.10, 0.25, 1, 1, 1]
        }
    }
    visible: r.ready && away < 129.5

    // blur + input follow the body (while sliding and while its width changes as recents come and go)
    function sync() {
        if (!visible) return;
        const x = Math.round(body.x), y = Math.round(body.y + body.slide);
        shell.setBlur(win, x, y, Math.round(bg.width), 92, 30);
        shell.setInput(win, x, y, Math.round(bg.width), 92);
    }
    onVisibleChanged: Qt.callLater(sync)
    onAwayChanged: Qt.callLater(sync)
    onWidthChanged: Qt.callLater(sync)

    Item {
        id: body
        readonly property real slide: win.away
        width: bg.width
        height: 92
        x: Math.round((win.width - bg.width) / 2)
        y: win.height - 18 - 92
        transform: Translate { y: body.slide }
        onXChanged: Qt.callLater(win.sync)

        // ---- material
        Rectangle {
            id: bg
            width: row.width
            height: 92
            radius: 30
            Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.25, 0.10, 0.25, 1, 1, 1] } }
            onWidthChanged: Qt.callLater(win.sync)
            // desktop: light veil over the blur, then a dark one (a dark material); in an app: one grey veil
            color: win.inApp ? Qt.rgba(128 / 255, 128 / 255, 134 / 255, 0.30) : Qt.rgba(236 / 255, 236 / 255, 236 / 255, 0.13)
            Rectangle {
                anchors.fill: parent
                radius: 30
                color: Qt.rgba(10 / 255, 10 / 255, 12 / 255, 0.20)
                opacity: win.inApp ? 0 : 1
            }
        }
        // OS7 glass: top sheen and a faint diagonal band, in the body's rounded outline
        Shape {
            width: bg.width; height: 92
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: "transparent"
                fillGradient: LinearGradient {
                    x1: 0; y1: 0; x2: 0; y2: 92
                    GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.12) }
                    GradientStop { position: 0.46; color: Qt.rgba(1, 1, 1, 0) }
                }
                PathRectangle { width: bg.width; height: 92; radius: 30 }
            }
            ShapePath {
                strokeColor: "transparent"
                fillGradient: LinearGradient {
                    x1: bg.width * 0.30; y1: 0; x2: bg.width * 0.52; y2: 92
                    GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0) }
                    GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.07) }
                    GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
                }
                PathRectangle { width: bg.width; height: 92; radius: 30 }
            }
            // light from the finger: a radial fill of the same outline, so it never leaves the rounded body
            ShapePath {
                id: glowPath
                property real cx: 0
                property real cy: 46
                property real rad: 48
                property real alpha: 0
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                    centerX: glowPath.cx; centerY: glowPath.cy; centerRadius: glowPath.rad
                    focalX: glowPath.cx; focalY: glowPath.cy
                    GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.24 * glowPath.alpha) }
                    GradientStop { position: 0.6; color: Qt.rgba(1, 1, 1, 0.06 * glowPath.alpha) }
                    GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
                }
                PathRectangle { width: bg.width; height: 92; radius: 30 }
            }
        }
        Rectangle {   // the rim
            width: bg.width; height: 92; radius: 30
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.13)
        }
        ParallelAnimation {
            id: glowOn
            NumberAnimation { target: glowPath; property: "alpha"; to: 1; duration: 80 }
            NumberAnimation { target: glowPath; property: "rad"; from: 48; to: 120; duration: 360; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
        }
        NumberAnimation { id: glowOff; target: glowPath; property: "alpha"; to: 0; duration: 300 }
        function press(item, pt) {
            const p = item.mapToItem(body, pt.x, pt.y);
            glowPath.cx = p.x; glowPath.cy = p.y;
            glowOff.stop(); glowOn.restart();
            win.r.keepRevealed();
        }
        function release() { glowOn.stop(); glowOff.restart() }

        // ---- icons
        Row {
            id: row
            height: 92
            leftPadding: 16; rightPadding: 16
            spacing: 20
            move: Transition {
                NumberAnimation { property: "x"; duration: 250; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.25, 0.10, 0.25, 1, 1, 1] }
            }
            add: Transition {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 250 }
                NumberAnimation { property: "scale"; from: 0.6; to: 1; duration: 250; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.25, 0.10, 0.25, 1, 1, 1] }
            }

            DockButton {
                anchors.verticalCenter: parent.verticalCenter
                onPressedAt: (pt) => body.press(this, pt)
                onReleased: body.release()
                onTapped: { win.r.revealed = false; win.r.gridOpen = true }
                // all apps: nine dots on a soft square (as the reference dock's drawer button)
                Rectangle {
                    anchors.fill: parent
                    radius: 15
                    color: Qt.rgba(1, 1, 1, 0.16)
                    Grid {
                        anchors.centerIn: parent
                        columns: 3; spacing: 7
                        Repeater {
                            model: 9
                            Rectangle { width: 8; height: 8; radius: 4; color: Qt.rgba(1, 1, 1, 0.88) }
                        }
                    }
                }
            }
            Repeater {
                model: apps.pinned
                AppButton { required property string modelData; appId: modelData }
            }
            Rectangle {
                visible: win.r.recentShown.length > 0
                anchors.verticalCenter: parent.verticalCenter
                width: 2; height: 22; radius: 1
                color: Qt.rgba(1, 1, 1, 0.6)
            }
            Repeater {
                model: win.r.recentShown
                AppButton { required property string modelData; appId: modelData }
            }
        }
    }

    component AppButton: DockButton {
        property string appId
        readonly property var entry: { apps.all; return apps.entry(appId) }   // apps.all: re-read after a rescan
        visible: entry.id !== undefined
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        onPressedAt: (pt) => body.press(this, pt)
        onReleased: body.release()
        onTapped: win.r.open(appId, win)
        Kirigami.Icon {
            anchors.fill: parent
            source: entry.icon || "application-x-executable"
            roundToIconSize: false
        }
    }
}
