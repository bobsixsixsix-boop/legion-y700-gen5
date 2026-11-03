// One item's detail (section 6 详情). Landscape: replaces the list in the right column, and the chart on the
// left grows the item's per-bucket bars. Portrait (`page`): a whole page pushed over the list, carrying its
// own chart with those bars, since the page's chart is scrolled away.
//   「‹ 谁用了电」 56 high (portrait: the range's short title on the right, so the page says which range)
//   icon 64 + name 30 px; 「约用掉 N% 电量」 44 Light; 「在前台时 a% · 在后台时 b%（其中熄屏 c%）」 20 px
//   explain (what a component is, how it is estimated), the screen's brightness hint
//   facts, 56 per row, only the fields the report filled in; the note; Steam's windows; ui/sys/other parts
// Its own Flickable scrolls only when the content is taller than the room (landscape: 846 px).
import QtQuick
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

Item {
    id: det
    property var item: null
    property var range: null
    signal back()

    property bool page: false
    property int tz: 0
    property real plotH: 260
    property real sidePad: 0
    property real topPad: 0
    property real bottomPad: 0

    implicitHeight: col.implicitHeight + topPad + bottomPad

    readonly property string itemId: item ? item.id : ""
    onItemIdChanged: flick.contentY = 0

    readonly property var factRows: Fmt.facts(item)
    readonly property var windowRows: item && item.windows ? item.windows : []
    readonly property var partRows: item && item.parts ? item.parts : []
    readonly property string split: Fmt.splitLine(item)

    component Line: Item {
        id: line
        property string label: ""
        property string value: ""
        property color labelColor: Fmt.TEXT2
        height: 56
        Text {
            id: valueText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: line.value
            color: Fmt.TEXT
            font.pixelSize: 22
            font.features: { "tnum": 1 }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, valueText.x - 16)
            elide: Text.ElideRight
            text: line.label
            color: line.labelColor
            font.pixelSize: 20
        }
        Rectangle {
            y: 55
            width: line.width
            height: 1
            color: Fmt.DIVIDER
        }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: det.implicitHeight
        interactive: contentHeight > height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col
            x: det.sidePad
            y: det.topPad
            width: Math.max(0, flick.width - 2 * det.sidePad)

            Item {
                width: col.width
                height: 56

                Item {
                    id: backBtn
                    x: -12
                    width: backText.implicitWidth + 24
                    height: 56
                    scale: backTap.pressed ? 0.96 : 1
                    Behavior on scale {
                        NumberAnimation { duration: 160; easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: 4
                        color: Qt.rgba(1, 1, 1, backTap.pressed ? 0.06 : 0)
                    }
                    Text {
                        id: backText
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: "‹ 谁用了电"
                        color: Fmt.TEXT
                        font.pixelSize: 22
                    }
                    TapHandler {
                        id: backTap
                        onTapped: det.back()
                    }
                }
                Text {
                    visible: det.page
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, Math.max(0, col.width - backBtn.width - 16))
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    text: det.range ? det.range.title : ""
                    color: Fmt.TEXT2
                    font.pixelSize: 18
                }
            }

            Item {
                width: col.width
                height: 80
                Kirigami.Icon {
                    y: 16
                    width: 64
                    height: 64
                    source: det.item && det.item.icon ? det.item.icon : "application-x-executable"
                    fallback: "application-x-executable"
                    roundToIconSize: false
                }
                Text {
                    x: 80
                    y: 16
                    width: Math.max(0, col.width - 80)
                    height: 64
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: det.item ? det.item.name : ""
                    color: Fmt.TEXT
                    font.pixelSize: 30
                    font.weight: Font.DemiBold
                }
            }

            Text {
                width: col.width
                topPadding: 16
                height: 56 + topPadding
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: det.item ? "约用掉 " + Fmt.pct(det.item.pct, det.item.pct_raw) + " 电量" : ""
                color: Fmt.TEXT
                font.pixelSize: 44
                font.weight: Font.Light
            }
            Text {
                visible: det.split !== ""
                width: col.width
                height: 32
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: det.split
                color: Fmt.TEXT2
                font.pixelSize: 20
            }

            Text {
                visible: text !== ""
                width: col.width
                topPadding: 16
                wrapMode: Text.Wrap
                lineHeightMode: Text.FixedHeight
                lineHeight: 30
                text: det.item && det.item.explain ? det.item.explain : ""
                color: Fmt.TEXT2
                font.pixelSize: 20
            }
            Text {
                visible: text !== ""
                width: col.width
                topPadding: 12
                wrapMode: Text.Wrap
                lineHeightMode: Text.FixedHeight
                lineHeight: 30
                text: det.item && det.item.hint ? det.item.hint : ""
                color: Fmt.TEXT
                font.pixelSize: 20
            }

            Loader {
                active: det.page && det.range !== null
                visible: active
                width: col.width
                sourceComponent: Component {
                    Item {
                        implicitHeight: pageChart.implicitHeight + 24
                        Chart {
                            id: pageChart
                            y: 24
                            width: parent.width
                            range: det.range
                            tz: det.tz
                            plotH: det.plotH
                            holdToRead: true
                            detailBuckets: det.item ? det.item.buckets : null
                            showUncovered: det.item !== null && det.item.kind === "unrecorded"
                        }
                    }
                }
            }

            Column {
                visible: det.factRows.length > 0
                width: col.width
                topPadding: 16
                Repeater {
                    model: det.factRows
                    delegate: Line {
                        required property var modelData
                        width: col.width
                        label: modelData[0]
                        value: modelData[1]
                    }
                }
            }

            Text {
                visible: text !== ""
                width: col.width
                topPadding: 16
                wrapMode: Text.Wrap
                lineHeightMode: Text.FixedHeight
                lineHeight: 28
                text: det.item && det.item.note ? det.item.note : ""
                color: Fmt.TEXT2
                font.pixelSize: 18
            }

            Column {
                visible: det.windowRows.length > 0
                width: col.width
                topPadding: 8
                Repeater {
                    model: det.windowRows
                    delegate: Line {
                        required property var modelData
                        width: col.width
                        label: modelData[0]
                        value: Fmt.dur(modelData[1])
                        labelColor: Fmt.TEXT
                    }
                }
            }

            Column {
                visible: det.partRows.length > 0
                width: col.width
                topPadding: 16
                Repeater {
                    model: det.partRows
                    delegate: Line {
                        required property var modelData
                        width: col.width
                        label: modelData[0]
                        value: Fmt.pctRaw(modelData[1])
                        labelColor: Fmt.TEXT
                    }
                }
            }
        }
    }
}
