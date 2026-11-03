// Range switch: 自上次充满 / 24 小时 / 7 天. The accent block slides to the picked segment in 180 ms (the
// only motion here: it says "this moved"); the data under it swaps at once. Cells split the width on whole
// pixels (portrait 938 = 312 + 313 + 313). A freshly built control (start, rotation) places the block
// without sliding.
import QtQuick
import "Fmt.js" as Fmt

Item {
    id: seg
    property var model: []                // [{key, label}]
    property string current: ""
    signal picked(string key)
    implicitHeight: 56

    readonly property int count: model ? model.length : 0
    readonly property int sel: {
        for (var i = 0; i < count; i++)
            if (model[i].key === current)
                return i
        return -1
    }
    property bool ready: false

    function cellX(i) { return Math.floor(i * width / Math.max(1, count)) }
    function cellW(i) { return cellX(i + 1) - cellX(i) }

    // binding the block's x would also slide it when the width settles after creation; placing it by hand
    // animates only a change of selection
    function place(animate) {
        slide.stop()
        if (sel < 0)
            return
        ind.width = cellW(sel)
        var tx = cellX(sel)
        if (animate && ind.x !== tx) {
            slide.to = tx
            slide.start()
        } else {
            ind.x = tx
        }
    }
    onSelChanged: place(ready)
    onWidthChanged: place(false)
    onCountChanged: place(false)
    Component.onCompleted: { place(false); ready = true }

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: Fmt.DIVIDER
    }
    Rectangle {
        id: ind
        height: seg.height
        radius: 4
        color: Fmt.ACCENT
        visible: seg.sel >= 0
    }
    NumberAnimation {
        id: slide
        target: ind
        property: "x"
        duration: 180
        easing.type: Easing.Bezier
        easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
    }

    Repeater {
        model: seg.model
        delegate: Item {
            id: cell
            required property var modelData
            required property int index
            x: seg.cellX(index)
            width: seg.cellW(index)
            height: seg.height

            Rectangle {
                anchors.fill: parent
                radius: 4
                color: Qt.rgba(1, 1, 1, tap.pressed ? 0.06 : 0)
            }
            Text {
                anchors.centerIn: parent
                text: cell.modelData.label
                color: cell.index === seg.sel ? "#ffffff" : Fmt.TEXT2
                font.pixelSize: 22
                scale: tap.pressed ? 0.96 : 1
                Behavior on scale {
                    NumberAnimation { duration: 160; easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
                }
            }
            TapHandler {
                id: tap
                onTapped: if (cell.modelData.key !== seg.current) seg.picked(cell.modelData.key)
            }
        }
    }
}
