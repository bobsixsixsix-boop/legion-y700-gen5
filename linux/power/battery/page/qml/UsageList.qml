// 「谁用了电」 (section 6 右栏, window y 104-950 in landscape). Header 24 px with 「占用掉的电量」 16 px grey
// on its right; the report's data_from_text under it (y 148-172) when the split starts late; then the rows
// from y 184. The landscape column scrolls its own list (`scrolls`); the portrait page lays every row out and
// scrolls as a whole, so there the list is as tall as its rows.
// The states without a split show range.empty instead: title, text, and for just_full a 56 px
// 「看 24 小时」 button that asks for the 24 h range (6b.a 状态).
import QtQuick
import "Fmt.js" as Fmt

Item {
    id: list
    property var range: null
    property bool scrolls: true
    signal open(string id)
    signal showRange(string key)

    readonly property var items: range && range.items ? range.items : []
    // a new range scrolls back to the top; a refresh of the same one keeps the place
    readonly property string rangeKey: range ? range.key : ""
    onRangeKeyChanged: view.positionViewAtBeginning()
    readonly property var emptyInfo: range && range.empty ? range.empty : null
    readonly property bool split: range !== null && emptyInfo === null && items.length > 0
    readonly property real maxPct: {
        var m = 0
        for (var i = 0; i < items.length; i++)
            m = Math.max(m, items[i].pct_raw)
        return m
    }
    readonly property real listTop: 80

    implicitHeight: listTop + (split ? items.length * 76 : (emptyInfo ? emptyBlock.implicitHeight : 0))

    Text {
        id: title
        y: 0
        height: 40
        verticalAlignment: Text.AlignVCenter
        text: "谁用了电"
        color: Fmt.TEXT
        font.pixelSize: 24
        font.weight: Font.DemiBold
    }
    Text {
        anchors.right: parent.right
        anchors.baseline: title.baseline
        text: "占用掉的电量"
        color: Fmt.TEXT2
        font.pixelSize: 16
    }
    Text {
        y: 44
        width: list.width
        height: 24
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        visible: list.split && !!list.range.data_from_text
        text: list.range && list.range.data_from_text ? list.range.data_from_text : ""
        color: Fmt.TEXT2
        font.pixelSize: 18
    }

    ListView {
        id: view
        x: -12
        y: list.listTop
        width: list.width + 24
        height: list.scrolls ? Math.max(0, list.height - list.listTop) : list.items.length * 76
        visible: list.split
        interactive: list.scrolls
        clip: list.scrolls
        boundsBehavior: Flickable.StopAtBounds
        // the row count, not the array: every refresh brings a new array, and a new model makes the view clear itself
        // and jump to the top (QQuickItemView::setModel); an equal count leaves it where the finger put it (10-31 审计)
        model: list.split ? list.items.length : 0
        delegate: UsageRow {
            required property int index
            width: view.width
            item: list.items[index]
            range: list.range
            maxPct: list.maxPct
            onClicked: list.open(list.items[index].id)
        }
    }

    Column {
        id: emptyBlock
        y: list.listTop
        width: list.width
        spacing: 12
        visible: !list.split && list.emptyInfo !== null

        Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: list.emptyInfo ? list.emptyInfo.title : ""
            color: Fmt.TEXT
            font.pixelSize: 22
            font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            wrapMode: Text.Wrap
            lineHeightMode: Text.FixedHeight
            lineHeight: 28
            text: list.emptyInfo ? list.emptyInfo.text : ""
            color: Fmt.TEXT2
            font.pixelSize: 18
        }
        Item {
            visible: list.emptyInfo !== null && list.emptyInfo.action === "show_24h"
            width: parent.width
            height: 64

            Rectangle {
                id: btn
                y: 8
                width: btnText.implicitWidth + 48
                height: 56
                radius: 4
                color: Fmt.ACCENT
                scale: btnTap.pressed ? 0.96 : 1
                Behavior on scale {
                    NumberAnimation { duration: 160; easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
                }
                Text {
                    id: btnText
                    anchors.centerIn: parent
                    text: "看 24 小时"
                    color: "#ffffff"
                    font.pixelSize: 22
                }
                TapHandler {
                    id: btnTap
                    onTapped: list.showRange("24h")
                }
            }
        }
    }
}
