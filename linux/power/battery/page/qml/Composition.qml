// 「用电去向」 (section 6, 横屏 y 688-788): title 20 px, a 24 px stacked bar (y 728-752 in the landscape
// window), and an inline legend 「名字 pct%」 16 px that wraps to a second line when eight kinds do not fit.
// Each legend entry carries its 16 px gap as right padding and the Flow has no spacing: Flow's spacing also
// opens a gap between lines, which would push a second line to y 800-824, into the 说明 at 812. Line 2 sits
// at y 784-808 instead (page/tests/fmt-test.mjs models this wrap).
// Segment widths follow pct_raw (6b.a 堆叠条); every kind keeps at least 2 px so a sliver stays visible.
// The states without a split (just_full, all_charger, empty) have no composition: the landscape page keeps
// the section in place with an empty track and the range's empty.title, the portrait page hides it.
import QtQuick
import "Fmt.js" as Fmt

Item {
    id: comp
    property var range: null
    implicitHeight: legend.y + legend.height

    readonly property var list: range && range.composition ? range.composition : []
    readonly property var boxes: {
        var raws = []
        for (var i = 0; i < list.length; i++)
            raws.push(list[i].pct_raw)
        return Fmt.segments(raws, width, 2, 2)
    }

    Text {
        y: 0
        height: 28
        verticalAlignment: Text.AlignVCenter
        text: "用电去向"
        color: Fmt.TEXT
        font.pixelSize: 20
        font.weight: Font.DemiBold
    }

    Item {
        id: bar
        y: 40
        width: comp.width
        height: 24

        Rectangle {
            anchors.fill: parent
            radius: 2
            color: Fmt.DIVIDER
            visible: comp.list.length === 0
        }
        Repeater {
            model: comp.list.length
            delegate: Rectangle {
                required property int index
                readonly property var box: comp.boxes[index] || ({ x: 0, w: 0 })
                x: box.x
                width: box.w
                height: 24
                radius: 2
                color: Fmt.roleColor(comp.list[index].role)
            }
        }
    }

    Flow {
        id: legend
        y: 72
        width: comp.width
        spacing: 0

        Repeater {
            model: comp.list
            delegate: Row {
                id: entry
                required property var modelData
                height: 24
                spacing: 6
                rightPadding: 16
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 10
                    height: 10
                    radius: 2
                    color: Fmt.roleColor(entry.modelData.role)
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: entry.modelData.name + " " + Fmt.pct(entry.modelData.pct, entry.modelData.pct_raw)
                    color: Fmt.TEXT2
                    font.pixelSize: 16
                }
            }
        }
        Text {
            visible: comp.list.length === 0
            height: 24
            verticalAlignment: Text.AlignVCenter
            text: comp.range && comp.range.empty ? comp.range.empty.title : ""
            color: Fmt.TEXT2
            font.pixelSize: 16
        }
    }
}
