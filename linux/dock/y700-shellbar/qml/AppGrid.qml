// All apps, from the dock's first button: the whole screen blurred, apps in a scrolling grid sorted by their
// Chinese name. Tap starts (or brings forward) an app; a long press pins it to the dock or unpins it, said in a
// short toast. Closed by a tap on the empty background, Esc / the back key, or starting an app.
// No search box and no pages (deliberately, for now: README 「有意不做」).
import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami

Window {
    id: win
    required property var shellRoot
    readonly property var r: shellRoot
    width: Screen.width
    height: Screen.height
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "y700-appgrid"

    // mapped for the opening and the closing animation, unmapped otherwise
    property real shownT: r.gridOpen ? 1 : 0
    Behavior on shownT { NumberAnimation { duration: win.r.gridOpen ? 240 : 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
    visible: r.ready && shownT > 0.001
    onVisibleChanged: {
        if (visible) {
            shell.setBlur(win, 0, 0, width, height, 0);
            grid.contentY = grid.originY;
            content.forceActiveFocus();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(14 / 255, 15 / 255, 18 / 255, 0.42)
        opacity: win.shownT
    }
    TapHandler { onTapped: win.r.gridOpen = false }   // the empty background

    Item {
        id: content
        anchors.fill: parent
        opacity: win.shownT
        scale: 0.96 + 0.04 * win.shownT
        focus: true
        Keys.onEscapePressed: win.r.gridOpen = false
        Keys.onBackPressed: win.r.gridOpen = false

        readonly property int cols: 8
        readonly property int cellW: Math.floor((width - 2 * 96) / cols)

        GridView {
            id: grid
            anchors.fill: parent
            anchors.topMargin: 72
            anchors.leftMargin: 96
            anchors.rightMargin: 96
            cellWidth: content.cellW
            cellHeight: 140
            clip: true
            model: apps.all
            boundsBehavior: Flickable.OvershootBounds
            bottomMargin: 40
            delegate: Item {
                id: cell
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight
                readonly property bool pinned: apps.pinned.indexOf(modelData.id) >= 0
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 14
                    spacing: 10
                    Item {
                        width: 72; height: 72
                        anchors.horizontalCenter: parent.horizontalCenter
                        scale: tap.pressed ? 0.90 : 1
                        Behavior on scale {
                            NumberAnimation {
                                duration: tap.pressed ? 200 : 250
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: tap.pressed ? [0.25, 0.45, 0.30, 1, 1, 1] : [0.25, 0.45, 0.35, 1, 1, 1]
                            }
                        }
                        Kirigami.Icon {
                            anchors.fill: parent
                            source: cell.modelData.icon || "application-x-executable"
                            roundToIconSize: false
                        }
                        Rectangle {   // pinned to the dock: a small dot at the corner
                            visible: cell.pinned
                            width: 10; height: 10; radius: 5
                            x: 66; y: -2
                            color: "#ffffff"
                            border.width: 2
                            border.color: Qt.rgba(0, 0, 0, 0.25)
                        }
                    }
                    Text {
                        width: content.cellW - 16
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        color: "#ffffff"
                        font.pixelSize: 15
                        text: cell.modelData.name
                        style: Text.Raised
                        styleColor: Qt.rgba(0, 0, 0, 0.35)
                    }
                }
                TapHandler {
                    id: tap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: win.r.open(cell.modelData.id, win)
                    onLongPressed: {
                        apps.togglePin(cell.modelData.id);
                        toast.say(apps.isPinned(cell.modelData.id) ? "已固定到 dock" : "已从 dock 移除");
                    }
                }
            }
        }
    }

    Rectangle {
        id: toast
        function say(t) { label.text = t; opacity = 1; hideToast.restart() }
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - 120
        width: label.implicitWidth + 40
        height: 44
        radius: 22
        color: Qt.rgba(0.12, 0.13, 0.15, 0.9)
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Text { id: label; anchors.centerIn: parent; color: "#ffffff"; font.pixelSize: 15 }
        Timer { id: hideToast; interval: 1600; onTriggered: toast.opacity = 0 }
    }
}
