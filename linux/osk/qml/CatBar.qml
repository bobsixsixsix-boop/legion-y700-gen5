// Bottom category bar of the emoji and symbol panels: 返回 · categories · (delete).
import QtQuick
import "."

Rectangle {
    id: bar
    property real u: 1
    property var names: []
    property int sel: 0
    property bool showDelete: false
    property string toggleLabel: ""         // optional toggle after 返回 (the symbol panel's 锁定)
    property bool toggleOn: false
    signal picked(int index)
    signal back()
    signal deleted()
    signal toggled()
    radius: 14 * u
    color: Theme.card
    clip: true
    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 6 * bar.u; anchors.rightMargin: (bar.showDelete ? 70 : 6) * bar.u
        contentWidth: row.width; flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        Row {
            id: row
            height: parent.height
            spacing: 6 * bar.u
            PBtn {
                u: bar.u; quiet: true; radius: 10 * bar.u
                anchors.verticalCenter: parent.verticalCenter
                width: bt.implicitWidth + 32 * bar.u; height: 52 * bar.u
                onTapped: bar.back()
                Text { id: bt; anchors.centerIn: parent; text: "返回"; color: Theme.ink; font.family: Theme.font; font.pixelSize: 16 * bar.u }
            }
            PBtn {
                visible: bar.toggleLabel !== ""
                u: bar.u; quiet: !bar.toggleOn; on: bar.toggleOn; radius: 10 * bar.u
                anchors.verticalCenter: parent.verticalCenter
                width: visible ? tg.implicitWidth + 32 * bar.u : 0; height: 52 * bar.u
                Accessible.name: bar.toggleLabel
                onTapped: bar.toggled()
                Row {
                    id: tg
                    anchors.centerIn: parent; spacing: 6 * bar.u
                    Image { anchors.verticalCenter: parent.verticalCenter; width: 18 * bar.u; height: width
                            sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                            source: Theme.ic(bar.toggleOn ? "lock" : "unlock", bar.toggleOn ? "#ffffff" : Theme.icon, 2) }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: bar.toggleLabel; color: bar.toggleOn ? "#ffffff" : Theme.ink
                           font.family: Theme.font; font.weight: bar.toggleOn ? Font.DemiBold : Font.Normal; font.pixelSize: 16 * bar.u }
                }
            }
            Repeater {
                model: bar.names
                delegate: PBtn {
                    required property string modelData
                    required property int index
                    u: bar.u; quiet: index !== bar.sel; radius: 10 * bar.u
                    anchors.verticalCenter: parent.verticalCenter
                    width: ct.implicitWidth + 32 * bar.u; height: 52 * bar.u
                    color: index === bar.sel ? Theme.cardP : "transparent"
                    onTapped: bar.picked(index)
                    Text { id: ct; anchors.centerIn: parent; text: modelData; color: Theme.ink; font.family: Theme.font
                           font.weight: index === bar.sel ? Font.DemiBold : Font.Normal; font.pixelSize: 16 * bar.u }
                }
            }
        }
    }
    PBtn {
        visible: bar.showDelete
        u: bar.u; quiet: true; radius: 10 * bar.u
        anchors.right: parent.right; anchors.rightMargin: 6 * bar.u; anchors.verticalCenter: parent.verticalCenter
        width: 60 * bar.u; height: 52 * bar.u
        onTapped: bar.deleted()
        Image { anchors.centerIn: parent; width: 24 * bar.u; height: width
                sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                source: Theme.ic("backspace", Theme.icon, 2) }
    }
}
