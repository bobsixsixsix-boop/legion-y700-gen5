// One background app in the curtain's 「后台应用」: a StatusNotifierItem (src/tray.h), the icon that sat in the Plasma
// tray before phase 3. Icon 32 over a short label, 104 x 84 (the approved mockup, design/y700-dock-mockup.html .titem).
// Tap = open the app (the item's Activate), long press = its own menu. Press: scale 0.96 in 160 ms + a haptic tick,
// as Tile. No icon (or one that does not load): the label's first character in a disc. NeedsAttention: an accent dot.
// Also the section's last tile when there are more apps than whole rows: `glyph` ("+3") in the disc, a tap opens
// the list of all of them.
import QtQuick

Item {
    id: tile
    property string label
    property string icon: ""            // image://sni/... or ""
    property string glyph: ""           // in the disc instead of the label's first character
    property bool attention: false
    // its tap is on its way to the app (an Activate waits up to 1 s for the answer): dimmed, no second tap
    property bool busy: false
    signal tapped(point centre)         // in window (= screen) coordinates: Activate takes a position
    signal longPressed()
    implicitWidth: 104
    implicitHeight: 84

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: Qt.rgba(1, 1, 1, tap.pressed ? 0.20 : 0.12)
        Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
        scale: tap.pressed ? 0.96 : 1
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        opacity: tile.busy ? 0.5 : 1
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        // fixed rows (icon 14..46, label 54..70: the 32 + 8 + 16 block centred in 84), the same line on every tile
        Image {
            id: img
            x: (parent.width - 32) / 2; y: 14
            width: 32; height: 32
            source: tile.icon
            sourceSize: Qt.size(32, 32)
            fillMode: Image.PreserveAspectFit
            // Synchronous: the provider only hands over a stored image (src/tray.cpp renders it at this size on the
            // GUI thread), and an icon that changes (a new url per change: Spectacle's animation while it records)
            // must swap in place - loaded in the background, every change was a frame of the letter disc in between.
            // Not cached: each url is used once, the cache would keep every frame of an animation.
            asynchronous: false
            cache: false
            visible: img.status === Image.Ready
        }
        Rectangle {
            x: (parent.width - 32) / 2; y: 14
            width: 32; height: 32; radius: 16
            visible: tile.glyph !== "" || img.status === Image.Null || img.status === Image.Error
            color: Qt.rgba(1, 1, 1, 0.14)
            Text {
                anchors.centerIn: parent
                // a code point, not a UTF-16 unit (an emoji or a rare CJK character is two)
                text: tile.glyph !== "" ? tile.glyph
                    : tile.label === "" ? "?" : String.fromCodePoint(tile.label.codePointAt(0)).toUpperCase()
                color: "white"; font.pixelSize: tile.glyph !== "" ? 14 : 16; font.weight: Font.DemiBold
            }
        }
        Text {
            x: 8; y: 54; width: parent.width - 16; height: 16
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: tile.label; color: "white"
            font.pixelSize: 13; font.weight: Font.DemiBold
        }
        // NeedsAttention (the app wants to be looked at): a dot in the corner, the icon is its attention icon
        Rectangle {
            visible: tile.attention
            x: parent.width - 18; y: 10
            width: 8; height: 8; radius: 4
            color: "#2e6bf6"
        }
        TapHandler {
            id: tap
            enabled: !tile.busy
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: { backend.haptic(); tile.tapped(tile.mapToItem(null, tile.width / 2, tile.height / 2)) }
            onLongPressed: { backend.haptic(); tile.longPressed() }
        }
    }
}
