// Summary block (section 6, 横屏 y 104-196): the live battery % big on the left, three lines from x 192
// (= x 248 in the landscape window). Line 1 is live (C++ reads sysfs when the page opens or is activated);
// lines 2-3 come from the report and dim with the rest of the old data when the report failed (stale), and line 1
// then leaves out the report's remaining time instead of dimming its live half.
//   1  「正在用电池 · 按过去一天的用法还能用约 9 小时」 22 px
//   2  range.sub, written by the report                     18 px grey
//   3  「亮屏 X · 熄屏 Y · 亮灭不明 U · 插电 Z」 from the range's seconds, hidden when empty
import QtQuick
import "Fmt.js" as Fmt

Item {
    id: sum
    property var doc: null
    property var range: null
    property int livePct: -1
    property string liveStatus: "unknown"
    property bool livePlugged: false
    implicitHeight: 92

    readonly property real cachedOpacity: backend.stale ? 0.4 : 1

    // 「100%」 at 72 px Light is about 181 px against the lines at 192; shrink rather than touch them
    Text {
        id: big
        x: 0
        y: 0
        width: 180
        height: 92
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: 56
        verticalAlignment: Text.AlignVCenter
        text: sum.livePct >= 0 ? sum.livePct + "%" : "–"
        color: Fmt.TEXT
        font.pixelSize: 72
        font.weight: Font.Light
        font.features: { "tnum": 1 }
    }

    Item {
        x: 192
        width: Math.max(0, sum.width - 192)
        height: 92

        Text {
            y: 0
            width: parent.width
            height: 32
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: Fmt.statusLine(sum.liveStatus, sum.livePlugged, sum.doc && !backend.stale ? sum.doc.remain : null)
            color: Fmt.TEXT
            font.pixelSize: 22
        }
        Text {
            y: 32
            width: parent.width
            height: 30
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: sum.range ? sum.range.sub : ""
            color: Fmt.TEXT2
            font.pixelSize: 18
            opacity: sum.cachedOpacity
        }
        Text {
            y: 62
            width: parent.width
            height: 30
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: Fmt.summaryLine3(sum.range)
            visible: text !== ""
            color: Fmt.TEXT2
            font.pixelSize: 18
            opacity: sum.cachedOpacity
        }
    }
}
