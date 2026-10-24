// The notification centre: the curtain's left half (pulled from the top edge's left half, vivo OriginOS style).
// Phase 2 mirrors plasmashell's notifications: libnotificationmanager's WatchedNotificationsModel registers this
// process as a watcher (org.kde.NotificationManager.RegisterWatcher) and gets a copy of every Notify. So the list
// holds what came in since this process started (no history from before), popups are still plasmashell's, and
// a timed-out notification stays here marked expired (its actions are gone). Clearing here clears only this list.
// Tap = the app's default action (if it has one and has not expired), then the curtain closes. Swipe a card
// sideways to remove it; 「清除」 removes all.
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kitemmodels as KItemModels
import org.kde.notificationmanager as NotificationManager

Item {
    id: pane
    signal invoked()          // a notification's action ran: the curtain closes
    property var now: new Date()
    readonly property int count: list.count

    // the model, rebuilt when the server changes owner (backend.notifyGen): the watcher registration lives in
    // the old owner. The old model must be gone before the new one registers /NotificationWatcher again.
    property var model: null
    Component { id: modelComp; NotificationManager.WatchedNotificationsModel {} }
    Component.onCompleted: model = modelComp.createObject(pane)
    readonly property int gen: backend.notifyGen
    onGenChanged: { if (model) { model.destroy(); model = null } rebuild.restart() }
    Timer { id: rebuild; interval: 1500; onTriggered: if (!pane.model) pane.model = modelComp.createObject(pane) }
    // the model appends (newest last); the list shows newest first
    KItemModels.KSortFilterProxyModel {
        id: sorted
        sourceModel: pane.model
        sortRoleName: "created"
        sortOrder: Qt.DescendingOrder
    }

    function ago(created) {
        const t = new Date(created), s = (pane.now - t) / 1000
        if (s < 60) return "刚刚"
        if (s < 3600) return Math.floor(s / 60) + " 分钟前"
        const sameDay = t.toDateString() === pane.now.toDateString()
        return (sameDay ? "" : (t.getMonth() + 1) + "月" + t.getDate() + "日 ") + Qt.formatTime(t, "HH:mm")
    }
    Timer { interval: 30000; repeat: true; running: pane.visible; triggeredOnStart: true; onTriggered: pane.now = new Date() }

    function clearAll() {
        if (!model) return
        const ids = []
        for (let i = 0; i < model.rowCount(); i++) ids.push(model.data(model.index(i, 0), NotificationManager.Notifications.IdRole))
        ids.forEach(id => model.close(id))
    }

    RowLayout {
        id: head
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 44
        spacing: 10
        Text { text: "通知"; color: "white"; font.pixelSize: 22; font.weight: Font.Bold }
        Text {
            visible: pane.count > 0
            text: pane.count; color: Qt.rgba(1, 1, 1, 0.55)
            font.pixelSize: 17; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
        }
        Item { Layout.fillWidth: true }
        Rectangle {
            visible: pane.count > 0
            Layout.preferredWidth: clearText.implicitWidth + 32; Layout.preferredHeight: 36; radius: 18
            color: Qt.rgba(1, 1, 1, clearTap.pressed ? 0.22 : 0.12)
            scale: clearTap.pressed ? 0.96 : 1
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Text { id: clearText; anchors.centerIn: parent; text: "清除"; color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold }
            TapHandler { id: clearTap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); pane.clearAll() } }
        }
    }

    Text {
        visible: pane.count === 0
        anchors { left: parent.left; right: parent.right; top: head.bottom; topMargin: 72 }
        horizontalAlignment: Text.AlignHCenter
        text: "没有通知"
        color: Qt.rgba(1, 1, 1, 0.5); font.pixelSize: 16
    }

    ListView {
        id: list
        anchors { left: parent.left; right: parent.right; top: head.bottom; topMargin: 14; bottom: parent.bottom }
        model: sorted
        clip: true
        spacing: 10
        boundsBehavior: Flickable.StopAtBounds
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic } }
        remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 150 } }
        displaced: Transition { NumberAnimation { properties: "y"; duration: 220; easing.type: Easing.OutCubic } }

        delegate: Item {
            id: card
            required property var model
            required property int index
            width: ListView.view.width
            height: box.height
            readonly property bool canOpen: !!model.hasDefaultAction && !model.expired

            Rectangle {
                id: box
                width: parent.width
                height: col.implicitHeight + 28
                radius: 16
                color: Qt.rgba(1, 1, 1, tap.pressed ? 0.20 : 0.12)
                Behavior on color { ColorAnimation { duration: 120 } }
                x: drag.active ? drag.dx : 0
                opacity: 1 - Math.min(0.6, Math.abs(x) / width)
                Behavior on x { enabled: !drag.active; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                ColumnLayout {
                    id: col
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14; leftMargin: 16; rightMargin: 16 }
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Kirigami.Icon {
                            Layout.preferredWidth: 20; Layout.preferredHeight: 20
                            source: card.model.applicationIconName || card.model.desktopEntry || "preferences-desktop-notification"
                        }
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: card.model.applicationName || "通知"
                            color: Qt.rgba(1, 1, 1, 0.7); font.pixelSize: 13; font.weight: Font.DemiBold
                        }
                        Text {
                            text: pane.ago(card.model.created)
                            color: Qt.rgba(1, 1, 1, 0.5); font.pixelSize: 13
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                text: card.model.summary || ""
                                color: "white"; font.pixelSize: 16; font.weight: Font.DemiBold
                                textFormat: Text.PlainText
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: text !== ""
                                text: card.model.body || ""
                                color: Qt.rgba(1, 1, 1, 0.82); font.pixelSize: 14; lineHeight: 1.25
                                wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                                textFormat: Text.StyledText
                            }
                        }
                        // the notification's own picture (a screenshot, a sender's avatar), when it sent one
                        Kirigami.Icon {
                            visible: !!card.model.image || !!card.model.iconName
                            Layout.preferredWidth: 48; Layout.preferredHeight: 48
                            source: card.model.image || card.model.iconName || ""
                        }
                    }
                }

                TapHandler {
                    id: tap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: {
                        if (!card.canOpen) return
                        backend.haptic()
                        pane.model.invokeDefaultAction(card.model.notificationId, NotificationManager.Notifications.None)
                        pane.invoked()
                    }
                }
                // sideways past a third of the card (or a flick) removes it. The offset and speed are kept from the
                // last move: by the time onActiveChanged says the drag ended, activeTranslation is back to 0 and the
                // centroid's velocity is ~0 (Qt 6.10, seen in the sb-bed).
                DragHandler {
                    id: drag
                    target: null
                    yAxis.enabled: false
                    property real dx: 0
                    property real vx: 0
                    onCentroidChanged: if (active) { dx = centroid.scenePosition.x - centroid.scenePressPosition.x; vx = centroid.velocity.x }
                    onActiveChanged: if (active) { dx = centroid.scenePosition.x - centroid.scenePressPosition.x; vx = 0 } else {
                        if (Math.abs(dx) > box.width / 3 || (Math.abs(dx) > 40 && Math.abs(vx) > 600)) {
                            backend.haptic()
                            pane.model.close(card.model.notificationId)
                        }
                    }
                }
            }
        }
    }
}
