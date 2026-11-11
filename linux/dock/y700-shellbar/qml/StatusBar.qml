// The status bar (OriginOS pad layout): time on the left, Wi-Fi / Bluetooth / battery on the right, 28 px; with them
// a crescent while do not disturb is on and a keyboard's / mouse's battery while one is connected (11-03, 11-04: the
// Magic Keyboard, the Magic Mouse).
// See-through on the desktop and over the stage manager's backdrop; over an app it is solid (maximized windows start
// under it, the exclusive zone).
// A pull down from it opens the sheets (src/main.cpp Puller): left half = notifications, right half = controls.
// Nothing here animates while idle: the clock wakes once a minute, the icons only when status says so.
import QtQuick
import QtQuick.Shapes
import QtQuick.Window

Window {
    id: bar
    required property var shellRoot
    visible: shellRoot.ready
    width: Screen.width
    height: 28
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "y700-statusbar"

    readonly property color ink: "#ffffff"

    Rectangle {
        anchors.fill: parent
        color: "#0e0f12"
        opacity: bar.shellRoot.onDesktop || shell.stage ? 0 : 1   // see-through over the stage's backdrop too
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }

    // ---- left: time
    Text {
        id: clock
        x: 22
        anchors.verticalCenter: parent.verticalCenter
        color: bar.ink
        font.pixelSize: 14
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
        // the sheet shows the big clock; two clocks at once look like a glitch (the mockup does the same)
        opacity: shell.ccOpen ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 200 } }
        text: Qt.formatTime(new Date(), "HH:mm")
    }
    Timer {
        // fire just after each minute turns, nothing in between
        running: bar.visible
        repeat: false
        interval: 1000
        triggeredOnStart: true
        onTriggered: {
            const d = new Date();
            clock.text = Qt.formatTime(d, "HH:mm");
            interval = (60 - d.getSeconds()) * 1000 - d.getMilliseconds() + 50;
            start();
        }
    }

    // ---- the performance line (HudLine.qml): the game numbers while y700-hud-overlay's sampler runs, in an app
    // only; on the desktop they are a widget under the clock (HudWidget.qml)
    HudLine {
        anchors.left: clock.right
        anchors.leftMargin: 22
        anchors.verticalCenter: parent.verticalCenter
        visible: hud.on && !bar.shellRoot.onDesktop
        opacity: clock.opacity   // away with the clock while the sheet is open
    }

    // ---- right: do not disturb, Wi-Fi, Bluetooth, the keyboard's and the mouse's battery, battery
    Row {
        anchors.right: parent.right
        anchors.rightMargin: 22
        anchors.verticalCenter: parent.verticalCenter
        spacing: 12

        // do not disturb (Banners.qml dnd; fn+F6 on the Magic Keyboard): a crescent
        Item {
            visible: !!bar.shellRoot.bannerWin && bar.shellRoot.bannerWin.dnd
            width: 15; height: 15
            anchors.verticalCenter: parent.verticalCenter
            Shape {
                width: 24; height: 24
                scale: 15 / 24
                transformOrigin: Item.TopLeft
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: "transparent"; fillColor: bar.ink
                    PathSvg { path: "M21 12.8A9 9 0 1 1 11.2 3A7 7 0 0 0 21 12.8z" }
                }
            }
        }

        // Wi-Fi: three arcs and a dot (24-unit drawing scaled to 17 px); arcs above the strength are dim
        Item {
            visible: sysStatus.wifi >= 0
            width: 17; height: 17
            anchors.verticalCenter: parent.verticalCenter
            Shape {
                width: 24; height: 24
                scale: 17 / 24
                transformOrigin: Item.TopLeft
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, sysStatus.wifi >= 4 ? 1 : 0.35)
                    strokeWidth: 2.1; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                    PathSvg { path: "M2.5 9a14 14 0 0 1 19 0" }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, sysStatus.wifi >= 3 ? 1 : 0.35)
                    strokeWidth: 2.1; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                    PathSvg { path: "M5.5 12.3a9.5 9.5 0 0 1 13 0" }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, sysStatus.wifi >= 2 ? 1 : 0.35)
                    strokeWidth: 2.1; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                    PathSvg { path: "M8.6 15.5a5 5 0 0 1 6.8 0" }
                }
                ShapePath {
                    strokeColor: "transparent"
                    fillColor: Qt.rgba(1, 1, 1, sysStatus.wifi >= 1 ? 1 : 0.35)
                    PathAngleArc { centerX: 12; centerY: 19; radiusX: 1.4; radiusY: 1.4; startAngle: 0; sweepAngle: 360 }
                }
            }
        }
        // wired (USB / Ethernet): a small plug-like glyph is enough, the tablet is rarely on a cable
        Text {
            visible: sysStatus.wired
            anchors.verticalCenter: parent.verticalCenter
            color: bar.ink; font.pixelSize: 12; font.weight: Font.DemiBold
            text: "有线"
        }
        // Bluetooth rune; a dot under it when something is connected
        Item {
            visible: sysStatus.bt > 0
            width: 16; height: 17
            anchors.verticalCenter: parent.verticalCenter
            Shape {
                width: 24; height: 24
                scale: 16 / 24
                transformOrigin: Item.TopLeft
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: bar.ink; strokeWidth: 2.2; fillColor: "transparent"
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: "M7 7l10 10-5 4V3l5 4L7 17" }
                }
            }
            Rectangle {
                visible: sysStatus.bt === 2
                width: 3; height: 3; radius: 1.5
                color: bar.ink
                anchors.horizontalCenter: parent.horizontalCenter
                y: 16
            }
        }
        // the keyboard's battery (a Bluetooth keyboard that reports one: the Magic Keyboard), then its number;
        // green on the cable, red at 15 and under as the tablet's own
        Row {
            id: kbdBattery
            visible: sysStatus.kbdBattery >= 0
            spacing: 5
            anchors.verticalCenter: parent.verticalCenter
            readonly property color tint: sysStatus.kbdCharging ? "#34c759" : sysStatus.kbdBattery <= 15 ? "#ff3b30" : bar.ink
            Rectangle {   // a keyboard: the outline, two rows of keys, the space bar
                width: 19; height: 13; radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                border.width: 1.5
                border.color: kbdBattery.tint
                Repeater {
                    model: 8
                    Rectangle {
                        required property int index
                        x: 3.5 + (index % 4) * 3.3
                        y: 3 + Math.floor(index / 4) * 2.8
                        width: 1.6; height: 1.6; radius: 0.4
                        color: kbdBattery.tint
                    }
                }
                Rectangle { x: 6; y: 9; width: 7; height: 1.5; radius: 0.75; color: kbdBattery.tint }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: kbdBattery.tint
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                text: sysStatus.kbdBattery
            }
        }
        // the mouse's battery (the Magic Mouse), the same way
        Row {
            id: mouseBattery
            visible: sysStatus.mouseBattery >= 0
            spacing: 5
            anchors.verticalCenter: parent.verticalCenter
            readonly property color tint: sysStatus.mouseCharging ? "#34c759" : sysStatus.mouseBattery <= 15 ? "#ff3b30" : bar.ink
            Rectangle {   // a mouse: the body, the line between its two buttons
                width: 10; height: 15; radius: 5
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                border.width: 1.5
                border.color: mouseBattery.tint
                Rectangle { x: 4.25; y: 2.5; width: 1.5; height: 4; radius: 0.75; color: mouseBattery.tint }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: mouseBattery.tint
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                text: sysStatus.mouseBattery
            }
        }
        // battery: cell + level, then the number (vivo puts the number next to the cell)
        Row {
            visible: sysStatus.battery >= 0
            spacing: 5
            anchors.verticalCenter: parent.verticalCenter
            Item {
                width: 28; height: 12
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    id: cell
                    width: 24; height: 12; radius: 3.5
                    color: "transparent"
                    border.width: 1.5
                    border.color: Qt.rgba(1, 1, 1, 0.8)
                    Rectangle {
                        x: 2.5; y: 2.5
                        height: parent.height - 5
                        width: Math.max(1.5, (parent.width - 5) * Math.max(0, sysStatus.battery) / 100)
                        radius: 1.5
                        color: sysStatus.charging ? "#34c759" : sysStatus.battery <= 15 ? "#ff3b30" : bar.ink
                    }
                }
                Rectangle {
                    x: 25; y: 4
                    width: 2; height: 4; radius: 1
                    color: Qt.rgba(1, 1, 1, 0.8)
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: bar.ink
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                text: sysStatus.battery
            }
        }
    }
}
