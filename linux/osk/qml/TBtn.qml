// Toolbar / title-bar icon button: 56 x 50, 28 px icon. Press = control-centre feedback
// (card fill + scale .96 in 160 ms OutCubic) with the mallet tick on press; action on release.
import QtQuick
import "."

Item {
    id: b
    property real u: 1
    property string icon
    property string label
    property bool on: false
    property real iconSize: 28
    signal tapped()
    width: 56 * u; height: 50 * u
    Accessible.role: Accessible.Button
    Accessible.name: label
    Rectangle {
        anchors.fill: parent
        radius: 12 * b.u
        color: tap.pressed ? Theme.card : "transparent"
        scale: tap.pressed ? 0.96 : 1
        Behavior on scale { NumberAnimation { duration: Theme.pressMs; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Theme.colourMs } }
        Image {
            anchors.centerIn: parent
            width: b.iconSize * b.u; height: width
            sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
            source: Theme.ic(b.icon, b.on ? Theme.accInk : (tap.pressed ? Theme.icon : Theme.icon2), 2)
        }
    }
    TapHandler {
        id: tap
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onPressedChanged: if (pressed) { kbRoot().click("tool"); kbRoot().haptic(kbRoot().sideAt(b), "key") }
        onTapped: b.tapped()
    }
    function kbRoot() { var p = b.parent; while (p && !p.hasOwnProperty("vibLevels")) p = p.parent; return p }
}
