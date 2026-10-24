// Voice wave: vertical accent bars with a centre-weighted envelope, driven by the mic level.
import QtQuick
import "."

Row {
    id: w
    property real u: 1
    property int bars: 31
    property bool live: false
    property real level: 0
    property real t: 0
    spacing: 7 * u
    height: 70 * u
    Timer { interval: 33; repeat: true; running: w.live && w.visible; onTriggered: w.t += 1 }
    Repeater {
        model: w.bars
        delegate: Rectangle {
            required property int index
            readonly property real mid: (w.bars - 1) / 2
            readonly property real env: w.live ? Math.max(0, 1 - Math.abs(index - mid) / mid * 1.25) : 0
            readonly property real v: env * (0.25 + 0.75 * w.level) * (0.35 + 0.65 * Math.abs(Math.sin(w.t * 0.13 + index * 0.7) * Math.cos(w.t * 0.05 + index)))
            anchors.verticalCenter: parent.verticalCenter
            width: 6 * w.u; radius: 3 * w.u
            height: Math.max(6 * w.u, v * 64 * w.u)
            color: Theme.accInk
        }
    }
}
