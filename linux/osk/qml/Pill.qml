// Pill slider (control centre style, 60 high): ticks under a white fill, accent chip with the
// icon on the left, value on the right. Press jumps to the value under the finger, drag follows;
// `moved` fires only when the integer step changes (no work per pixel).
import QtQuick
import "."

Rectangle {
    id: p
    property real u: 1
    property int max: 10
    property int value: 0
    property string icon: "sound"
    property string label: ""
    signal moved(int v)
    height: 60 * u
    radius: height / 2
    color: Theme.pillTrack
    clip: true
    Accessible.role: Accessible.Slider
    readonly property real frac: value / Math.max(1, max)

    Row {
        // ticks stop short of the value on the right so they never touch it
        x: 60 * p.u; y: (p.height - 6 * p.u) / 2
        width: p.width - 130 * p.u; height: 6 * p.u
        spacing: (width - (p.max + 1) * 6 * p.u) / Math.max(1, p.max)
        Repeater { model: p.max + 1; delegate: Rectangle { width: 6 * p.u; height: width; radius: width / 2; color: Theme.ink2 } }
    }
    Rectangle {
        width: Math.max(p.height, p.frac * p.width); height: p.height
        topLeftRadius: p.radius; bottomLeftRadius: p.radius
        topRightRadius: p.frac >= 0.995 ? p.radius : 0; bottomRightRadius: topRightRadius
        color: Theme.pillFill
        border.width: Theme.light ? 1 : 0; border.color: Qt.rgba(0, 0, 0, .06)
        Behavior on width { enabled: !ma.pressed; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }
    Rectangle {
        x: 8 * p.u; y: 8 * p.u; width: 44 * p.u; height: width; radius: width / 2
        color: Theme.acc
        scale: ma.pressed ? 1.06 : 1
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Image { anchors.centerIn: parent; width: 24 * p.u; height: width
                sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                source: Theme.ic(p.icon, "#ffffff", 2) }
    }
    Text {
        anchors.right: parent.right; anchors.rightMargin: 20 * p.u; anchors.verticalCenter: parent.verticalCenter
        text: p.label
        color: p.frac > 0.8 ? "#1c1f25" : Theme.ink
        font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 17 * p.u
        font.features: { "tnum": 1 }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        preventStealing: true
        function at(x) { return Math.round(Math.max(0, Math.min(1, x / width)) * p.max) }
        onPressed: (e) => { var v = at(e.x); if (v !== p.value) p.moved(v) }
        onPositionChanged: (e) => { var v = at(e.x); if (v !== p.value) p.moved(v) }
    }
    Keys.onLeftPressed: if (value > 0) moved(value - 1)
    Keys.onRightPressed: if (value < max) moved(value + 1)
}
