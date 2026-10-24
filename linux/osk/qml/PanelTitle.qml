// Panel title bar: back button, title (+ small note), optional right-side content, hairline below.
import QtQuick
import "."

Item {
    id: t
    property real u: 1
    property string title
    property string note: ""
    property string leftIcon: "back"
    property bool centred: false
    default property alias rightContent: rightBox.data
    signal back()
    TBtn { id: backBtn; u: t.u; x: 8 * t.u; anchors.verticalCenter: parent.verticalCenter; icon: t.leftIcon; label: "返回"; onTapped: t.back() }
    Row {
        x: t.centred ? (t.width - width) / 2 : backBtn.x + backBtn.width + 6 * t.u
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8 * t.u
        Text { id: titleText; text: t.title; color: Theme.ink; font.family: Theme.font
               font.weight: t.centred ? Font.Medium : Font.DemiBold; font.pixelSize: 19 * t.u }
        Text { anchors.baseline: titleText.baseline; text: t.note; visible: t.note !== ""; color: Theme.ink3; font.family: Theme.font; font.pixelSize: 14 * t.u }
    }
    Row { id: rightBox; anchors.right: parent.right; anchors.rightMargin: 14 * t.u; anchors.verticalCenter: parent.verticalCenter; spacing: 6 * t.u }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.sep }
}
