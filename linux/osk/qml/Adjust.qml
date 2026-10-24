// 键盘调节: drag the handle on top to change the keyboard height (vivo range 1/1.1 .. 1.1).
import QtQuick
import "."

Rectangle {
    id: a
    required property var kb
    readonly property real u: kb.u
    property real base: 1
    property int edge: 0
    color: Theme.mask
    topLeftRadius: 20 * u; topRightRadius: 20 * u
    bottomLeftRadius: kb.mode === "float" ? 20 * u : 0; bottomRightRadius: bottomLeftRadius
    opacity: kb.adjusting ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 160 } }

    function start() { base = kb.prefs.hadj; edge = 0; kb.adjusting = true }
    function cancel() { if (!kb.adjusting) return; kb.prefs.hadj = base; kb.adjusting = false }
    function save() { base = kb.prefs.hadj; kb.adjusting = false; kb.toast("已保存键盘高度", "", 1000) }

    MouseArea { anchors.fill: parent }        // swallow touches meant for the keys underneath
    Item {
        id: hdl
        anchors.horizontalCenter: parent.horizontalCenter
        width: 133 * a.u; height: 93 * a.u
        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: 10 * a.u; width: 64 * a.u; height: 8 * a.u; radius: 4 * a.u; color: "#ffffff" }
        DragHandler {
            target: null
            xAxis.enabled: false
            property real v0: 1
            property real top0: 0
            // on-screen y of the window top: docked/split keyboards grow upwards under the finger, so
            // window-relative translation alone would follow at half speed
            function winTop() {
                var t = osk.screenHeight - a.kb.implicitHeight
                return a.kb.mode === "float" ? Math.min(a.kb.prefs.floatY - a.kb.fpad, t) : t
            }
            onActiveChanged: if (active) { v0 = a.kb.prefs.hadj; top0 = winTop() }
            onTranslationChanged: {
                var screenDy = translation.y + (winTop() - top0)
                var raw = v0 - screenDy / (296 * a.u)
                var hi = a.kb.portrait ? 1.2 : 1.1          // vivo: ÷1.1..×1.1 landscape, ÷1.2..×1.2 portrait
                var v = Math.max(1 / hi, Math.min(hi, raw))
                if (Math.abs(v - a.kb.prefs.hadj) > 0.004) a.kb.prefs.hadj = v
                var at = raw >= hi ? 1 : raw <= 1 / hi ? -1 : 0
                if (at && at !== a.edge) a.kb.toast(at > 0 ? "最大高度" : "最小高度", "", 900)
                a.edge = at
            }
        }
    }
    Text {
        anchors.centerIn: parent
        text: "键盘高度 " + Math.round(a.kb.kbH / Math.max(1, osk.screenHeight) * 100) + "%"
        color: "#ffffff"; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 22 * a.u
    }
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: 30 * a.u
        spacing: 16 * a.u
        Repeater {
            model: [{ t: "默认", pri: false }, { t: "保存", pri: true }]
            delegate: Rectangle {
                required property var modelData
                width: 120 * a.u; height: 44 * a.u; radius: 14 * a.u
                color: modelData.pri ? "#ffffff" : "transparent"
                border.width: modelData.pri ? 0 : 1.5; border.color: Qt.rgba(1, 1, 1, .7)
                scale: th.pressed ? 0.96 : 1
                Behavior on scale { NumberAnimation { duration: Theme.pressMs; easing.type: Easing.OutCubic } }
                Text { anchors.centerIn: parent; text: modelData.t; color: modelData.pri ? "#1c1f25" : "#ffffff"; font.family: Theme.font; font.pixelSize: 17 * a.u }
                TapHandler { id: th; gesturePolicy: TapHandler.ReleaseWithinBounds
                             onTapped: modelData.pri ? a.save() : (a.kb.prefs.hadj = 1) }
            }
        }
    }
}
