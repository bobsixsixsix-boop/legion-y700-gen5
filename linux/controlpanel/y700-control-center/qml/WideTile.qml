// A full-width tile (two grid columns): icon chip, title + one line of status on the left, an on/off
// pill on the right. Same press feedback and haptic tick as Tile. Used for Tailscale, where the status
// (tailnet address / not logged in / off) is the useful part. 60 high like every single-line control of
// the curtain (10-22: the pills, the performance segments, the power row), chip 44 like the pills'.
// toggle: false (11-01) drops the pill: the four actions at the bottom of the thumb column, half width.
import QtQuick

Item {
    id: tile
    property string icon: ""
    property string title
    property string status: ""
    property bool active: false
    property bool busy: false
    property bool toggle: true
    signal tapped()
    signal longPressed()
    implicitHeight: 60

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: tile.active ? "#2e6bf6" : Qt.rgba(1, 1, 1, tap.pressed ? 0.20 : 0.12)
        Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
        scale: tap.pressed ? 0.96 : 1
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        opacity: tile.busy ? 0.5 : 1
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Rectangle {
            id: chip
            x: 8; anchors.verticalCenter: parent.verticalCenter
            width: 44; height: 44; radius: 22
            color: Qt.rgba(1, 1, 1, tile.active ? 0.22 : 0.14)
            Behavior on color { ColorAnimation { duration: 150 } }
            Image { anchors.centerIn: parent; source: tile.icon !== "" ? "icons/" + tile.icon + ".svg" : ""; sourceSize: Qt.size(24, 24) }
        }
        Column {
            anchors { left: chip.right; leftMargin: 12; right: tile.toggle ? pillSw.left : parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 2
            Text { width: parent.width; elide: Text.ElideRight; text: tile.title; color: "white"; font.pixelSize: 16; font.weight: Font.DemiBold }
            Text { width: parent.width; elide: Text.ElideRight; text: tile.status; color: Qt.rgba(1, 1, 1, 0.75); font.pixelSize: 13; visible: text !== "" }
        }
        // on/off pill: the knob slides, the track tints
        Rectangle {
            id: pillSw
            visible: tile.toggle
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            width: 46; height: 26; radius: 13
            color: tile.active ? Qt.rgba(1, 1, 1, 0.30) : Qt.rgba(1, 1, 1, 0.18)
            Behavior on color { ColorAnimation { duration: 150 } }
            Rectangle {
                width: 20; height: 20; radius: 10; y: 3
                x: tile.active ? parent.width - width - 3 : 3
                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                color: "white"
            }
        }
        TapHandler {
            id: tap
            enabled: !tile.busy
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: { backend.haptic(); tile.tapped() }
            onLongPressed: { backend.haptic(); tile.longPressed() }
        }
    }
}
