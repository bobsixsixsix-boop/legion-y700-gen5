// One row of 「谁用了电」 (section 6 右栏), 76 px high. The row reaches `pad` (12) px past the column on both
// sides so the press highlight has room; the content then lands on the section 6 grid:
//   icon 44 at column x 0 (window x 1016), y 16
//   name 22 DemiBold at column x 60 (x 1076); grey sub-line 18 px under it, or the name centred alone
//   percentage 24 px, right edge at the column edge (x 1544)
//   share bar 3 px at y 66 from x 60, pct_raw / maxPct of the bar room (468 px in landscape)
//   separator at the row bottom from x 60
// Press: the whole row scales to 0.98 on a 6 % white ground, 120 ms; a drag past the threshold goes to the
// list's Flickable instead and cancels the press.
import QtQuick
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

Item {
    id: row
    property var item: null
    property var range: null
    property real maxPct: 1
    property real pad: 12
    signal clicked()

    implicitHeight: 76
    height: 76

    readonly property string sub: Fmt.rowSub(item, range)
    readonly property real barRoom: Math.max(0, width - 2 * pad - 60)

    scale: tap.pressed ? 0.98 : 1
    Behavior on scale {
        NumberAnimation { duration: 120; easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
    }

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: Qt.rgba(1, 1, 1, 0.06)
        opacity: tap.pressed ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: 120; easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
        }
    }

    Kirigami.Icon {
        x: row.pad
        y: 16
        width: 44
        height: 44
        source: row.item && row.item.icon ? row.item.icon : "application-x-executable"
        fallback: "application-x-executable"
        roundToIconSize: false
    }

    Text {
        id: pctText
        anchors.right: parent.right
        anchors.rightMargin: row.pad
        y: 0
        height: 70
        verticalAlignment: Text.AlignVCenter
        text: row.item ? Fmt.pct(row.item.pct, row.item.pct_raw) : ""
        color: Fmt.TEXT
        font.pixelSize: 24
        font.features: { "tnum": 1 }
    }

    Text {
        x: row.pad + 60
        y: row.sub === "" ? 20 : 8
        width: Math.max(0, pctText.x - 16 - x)
        height: 30
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: row.item ? row.item.name : ""
        color: Fmt.TEXT
        font.pixelSize: 22
        font.weight: Font.DemiBold
    }
    Text {
        x: row.pad + 60
        y: 38
        width: Math.max(0, pctText.x - 16 - x)
        height: 24
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        visible: row.sub !== ""
        text: row.sub
        color: Fmt.TEXT2
        font.pixelSize: 18
    }

    Rectangle {
        x: row.pad + 60
        y: 66
        width: row.item && row.maxPct > 0 ? Math.max(2, Math.min(1, row.item.pct_raw / row.maxPct) * row.barRoom) : 0
        height: 3
        radius: 1
        color: Fmt.roleColor(row.item ? row.item.role : "")
    }

    Rectangle {
        x: row.pad + 60
        y: 75
        width: Math.max(0, row.width - row.pad - x)
        height: 1
        color: Fmt.DIVIDER
    }

    TapHandler {
        id: tap
        onTapped: row.clicked()
    }
}
