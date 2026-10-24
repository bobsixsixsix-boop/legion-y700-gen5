// Panel button: card fill, press = brighter card + scale .96 (160 ms OutCubic), `on` = accent.
// Feedback (mallet + haptic) on press, action on release inside the button.
import QtQuick
import "."

Rectangle {
    id: b
    property real u: 1
    property bool on: false
    property bool quiet: false            // no fill at rest (bars, segmented controls)
    property string sound: "tool"         // tool | char | expand | none
    default property alias content: inner.data
    signal tapped()
    radius: 12 * u
    color: on ? (tap.pressed ? Theme.accP : Theme.acc) : tap.pressed ? Theme.cardP : (quiet ? "transparent" : Theme.card)
    scale: tap.pressed ? 0.96 : 1
    Behavior on scale { NumberAnimation { duration: Theme.pressMs; easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: Theme.colourMs } }
    Accessible.role: Accessible.Button
    // content children see the button state as parent.on / parent.pressed
    Item { id: inner; anchors.fill: parent; property bool on: b.on; property bool pressed: tap.pressed }
    TapHandler {
        id: tap
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onPressedChanged: if (pressed) {
            var k = b.kbRoot(); if (!k) return
            if (b.sound !== "none") k.click(b.sound)
            k.haptic(k.sideAt(b), "key")
        }
        onTapped: b.tapped()
    }
    function kbRoot() { var p = b.parent; while (p && !p.hasOwnProperty("vibLevels")) p = p.parent; return p }
}
