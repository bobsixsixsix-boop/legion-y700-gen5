// Vertical slider tile: icon on top, value label at the bottom. The track is drawn flat; the thumb is a
// short bar. `value` 0..100 follows the system while not being dragged; `moved(v)` is emitted while
// dragging (throttled by the caller if needed).
import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: tile
    property string icon
    property real value: 0          // 0..100, from the system
    property bool available: true
    signal moved(real v)

    implicitWidth: 74
    implicitHeight: 150

    property real dragValue: value
    property bool dragging: false
    readonly property real shown: dragging ? dragValue : value

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.09)
        opacity: tile.available ? 1 : 0.4

        Kirigami.Icon {
            id: ic
            source: tile.icon
            width: 22; height: 22
            anchors { top: parent.top; topMargin: 8; horizontalCenter: parent.horizontalCenter }
            color: Kirigami.Theme.textColor
            isMask: true
        }
        Item {
            id: track
            anchors { top: ic.bottom; topMargin: 8; bottom: lab.top; bottomMargin: 8; horizontalCenter: parent.horizontalCenter }
            width: 10
            Rectangle { anchors.fill: parent; radius: 5; color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.18) }
            Rectangle {   // filled part
                anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
                width: parent.width
                radius: 5
                height: Math.max(width, parent.height * tile.shown / 100)
                color: Kirigami.Theme.highlightColor
                Behavior on height { enabled: !tile.dragging; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
            Rectangle {   // thumb
                width: 28; height: 6; radius: 3
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height - parent.height * tile.shown / 100 - height / 2
                color: Kirigami.Theme.textColor
                scale: tile.dragging ? 1.15 : 1
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }
        }
        Text {
            id: lab
            anchors { bottom: parent.bottom; bottomMargin: 8; horizontalCenter: parent.horizontalCenter }
            text: Math.round(tile.shown) + "%"
            color: Kirigami.Theme.textColor
            font.pixelSize: 11
            font.weight: Font.DemiBold
        }
        MouseArea {
            // the whole tile is the touch target; vertical position = value
            anchors.fill: parent
            enabled: tile.available
            function at(y) {
                const top = track.y, h = track.height
                return Math.max(0, Math.min(100, 100 * (top + h - y) / h))
            }
            onPressed: (m) => { tile.dragging = true; tile.dragValue = at(m.y); tile.moved(tile.dragValue) }
            onPositionChanged: (m) => { if (pressed) { tile.dragValue = at(m.y); tile.moved(tile.dragValue) } }
            onReleased: { tile.dragging = false }
            onCanceled: { tile.dragging = false }
        }
    }
}
