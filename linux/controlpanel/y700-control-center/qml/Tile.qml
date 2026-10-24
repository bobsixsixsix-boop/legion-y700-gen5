// One control tile: round icon chip + title. Press: scale 0.96 in 160 ms + a haptic tick; state: fill
// cross-fades (active = accent). Long press (Wi-Fi, Bluetooth) opens the device list. `glyph` draws
// short text (e.g. "60") instead of an icon.
import QtQuick

Item {
    id: tile
    property string icon: ""
    property string glyph: ""
    property string title
    property bool active: false
    property bool busy: false
    signal tapped()
    signal longPressed()
    implicitHeight: 100

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: tile.active ? "#2e6bf6" : Qt.rgba(1, 1, 1, tap.pressed ? 0.20 : 0.12)
        Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
        scale: tap.pressed ? 0.96 : 1
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        opacity: tile.busy ? 0.5 : 1
        Behavior on opacity { NumberAnimation { duration: 150 } }

        // fixed rows (chip 16..64, title 70..90): the icon line is the same on every tile
        Rectangle {
            x: (parent.width - 48) / 2; y: 16
            width: 48; height: 48; radius: 24
            color: Qt.rgba(1, 1, 1, tile.active ? 0.22 : 0.14)
            Behavior on color { ColorAnimation { duration: 150 } }
            Image { visible: tile.glyph === ""; anchors.centerIn: parent; source: tile.icon !== "" ? "icons/" + tile.icon + ".svg" : ""; sourceSize: Qt.size(26, 26) }
            Text { visible: tile.glyph !== ""; anchors.centerIn: parent; text: tile.glyph; color: "white"; font.pixelSize: 19; font.weight: Font.Bold }
        }
        Text {
            x: 0; y: 70; width: parent.width; height: 20
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            text: tile.title; color: "white"
            font.pixelSize: 16; font.weight: Font.DemiBold
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
