// One square control: icon, title, small caption. Flat, no shadow. Press: scale 0.97 in 160 ms
// (ease-out), state: fill colour cross-fades in 150 ms (active = accent, danger = negative colour).
import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: tile
    property string icon
    property string title
    property string caption: ""
    property bool active: false
    property bool danger: false
    property bool busy: false
    signal tapped()

    implicitHeight: 74
    implicitWidth: 74

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: 6
        color: tile.danger ? Kirigami.Theme.negativeTextColor
             : tile.active ? Kirigami.Theme.highlightColor
             : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, mouse.pressed ? 0.16 : 0.09)
        Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
        scale: mouse.pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
        opacity: tile.busy ? 0.6 : 1
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Column {
            anchors.centerIn: parent
            spacing: 3
            Kirigami.Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                source: tile.icon
                width: 26; height: 26
                color: (tile.active || tile.danger) ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                isMask: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: tile.title
                color: (tile.active || tile.danger) ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                font.pixelSize: 11
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: tile.caption !== ""
                text: tile.caption
                color: (tile.active || tile.danger) ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.disabledTextColor
                opacity: (tile.active || tile.danger) ? 0.85 : 1
                font.pixelSize: 10
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: !tile.busy
        onClicked: tile.tapped()
    }
}
