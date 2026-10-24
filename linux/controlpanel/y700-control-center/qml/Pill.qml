// Brightness / volume bar: a horizontal capsule, the whole bar is the slider. White fill grows from
// the left, the icon sits in an accent chip at the left end, the value at the right end. `value` 0..1 from
// the system; `moved(v)` while dragging.
// Relative drag (10-22, the thumb-first layout put both pills under the right thumb's resting spot, the
// volume's 100 % end right where it lands): a press changes nothing, the fill follows the finger's travel
// from the value on screen when the drag starts (press, move 10 % of the bar: +10 %, wherever the finger
// is), so a thumb parked on the bar does not slam the volume. A quick tap (lifted within 300 ms, less than
// 16 px from where it landed, thumb roll included) still jumps to the tapped spot, the end caps snapping to
// 0 / 100 %; a press held longer is a rest: the armed look relaxes at 300 ms and lifting changes nothing.
// A touch that slides off the bar (up into the tile above) is no tap either.
import QtQuick

Item {
    id: pill
    property string icon
    property real value: 0
    signal moved(real v)
    property bool dragging: false            // the armed look: pressed (until a rest relaxes it) or tracking
    property bool tracking: false            // the finger drives the shown value (past the slop)
    property real dragValue: 0
    readonly property real shown: Math.max(0, Math.min(1, tracking ? dragValue : value))   // sinks can sit above 100 %
    implicitHeight: 60

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.12)
        // fill: a white capsule as large as the track, clipped to the fraction, so it is the track's own outline cut
        // at x = width * fraction: both ends follow the end caps at any width. (Until 10-22 it was a full-height
        // bar with corner radius min(30, width / 2): below 60 px, at 2-8 %, its top and bottom corners stuck out of
        // the left cap's arc, a square bar on a round end. The owner saw it at the far left.)
        Item {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: parent.width * pill.shown
            visible: width > 0.5
            clip: true
            Behavior on width { enabled: !pill.tracking; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Rectangle {
                width: track.width; height: track.height; radius: track.radius
                color: Qt.rgba(1, 1, 1, pill.dragging ? 1.0 : 0.88)
                Behavior on color { ColorAnimation { duration: 120 } }
            }
        }
        Rectangle {   // icon chip, always on top of the fill
            id: chip
            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
            width: parent.height - 16; height: width; radius: width / 2
            color: "#2e6bf6"
            scale: pill.dragging ? 1.06 : 1
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Image { anchors.centerIn: parent; source: "icons/" + pill.icon + ".svg"; sourceSize: Qt.size(24, 24) }
        }
        Text {
            anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
            text: Math.round(pill.shown * 100) + "%"
            // readable on both the white fill and the dark track
            color: pill.shown > 0.82 ? "#1c1f25" : "white"
            font.pixelSize: 16; font.weight: Font.DemiBold
        }
        MouseArea {
            id: touch
            anchors.fill: parent
            // slop: x travel before a press is a drag (0.7 mm at 84.5 px/cm); the drag starts where the slop ends,
            // so the fill moves on continuously instead of skipping it. tapRadius / tapMs: a release this close to
            // where the finger landed, this soon, is a tap (a thumb pad rolls 8-12 px between down and up, so the
            // tap is decided on its own, not by "never entered the drag"); later or farther, it is nothing
            readonly property real slop: 6
            readonly property real tapRadius: 16
            readonly property int tapMs: 300
            property real xDown: 0; property real yDown: 0; property real tDown: 0
            property real x0: 0                  // the drag's anchor, re-anchored while the fill is pinned at an end
            property real v0: 0                  // the value when the drag started
            property bool drag: false            // past the slop: the fill follows the travel
            property real sent: -1               // the last value handed to moved(): pinned at an end, no repeats
            // a tap's target: the chip (left cap) is 0, the right cap is 1, the end caps read as "the end"
            function at(x) {
                if (x < chip.x + chip.width) return 0
                if (x > width - track.radius) return 1
                return x / width
            }
            onPressed: (m) => {
                xDown = m.x; yDown = m.y; tDown = Date.now(); drag = false; sent = -1
                pill.dragging = true                      // feedback only: the value stays
                relax.restart()
            }
            onPositionChanged: (m) => {
                if (!pressed) return
                if (!drag) {
                    const d = m.x - xDown
                    if (Math.abs(d) <= slop) return
                    drag = true; relax.stop()
                    v0 = Math.max(0, Math.min(1, pill.value))     // from what is on screen now, not at the press
                    x0 = xDown + (d > 0 ? slop : -slop)
                    sent = v0; pill.dragValue = v0
                    pill.tracking = true; pill.dragging = true
                }
                let v = v0 + (m.x - x0) / width
                if (v < 0 || v > 1) {            // pinned at an end: re-anchor, so coming back moves it at once
                    v = v < 0 ? 0 : 1
                    x0 = m.x - (v - v0) * width
                }
                pill.dragValue = v
                if (v !== sent) { sent = v; pill.moved(v) }
            }
            onReleased: (m) => {
                relax.stop()
                const tap = Date.now() - tDown < tapMs && Math.hypot(m.x - xDown, m.y - yDown) <= tapRadius
                pill.tracking = false; pill.dragging = false
                if (tap) pill.moved(at(m.x))              // the jump flows through `value`, animated
            }
            onCanceled: { relax.stop(); pill.tracking = false; pill.dragging = false }
            // a press held still this long is a rest: the armed look goes (lifting now does nothing); a drag that
            // starts later arms it again
            Timer { id: relax; interval: touch.tapMs; onTriggered: pill.dragging = false }
        }
    }
}
