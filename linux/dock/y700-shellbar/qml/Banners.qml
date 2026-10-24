// Notification banners (phase 2 of the vivo-style shell, 2026-10-22). y700-shellbar is the session's notification
// server: the Notifications model below is libnotificationmanager's, the one plasmashell's applet ran; its first
// instance registers org.freedesktop.Notifications (src/main.cpp sets _plasma_dbus_master, so it takes the name
// over from whoever has it and keeps it). The control centre's notification centre (NotesPane.qml) watches this
// server (org.kde.NotificationWatcher), so what comes up here is there too, and an expiry here marks it there.
// A new notification is a banner at the top of the screen, OriginOS style: a frosted card, centred, the newest on
// top, three at most (more wait in the model and come up as these go). It goes by itself after 5 s (longer for a
// long body, 10 s at most; an app's own timeout as given; a critical one stays until a finger sends it off), on a
// swipe up or sideways (expired: still in the notification centre), on a tap (the notification's default action,
// then closed, as vivo does; just expired when it has none) or on one of its action buttons. The banners' own
// clocks, not the model's: that one is the 3-minute history expiry. When the curtain comes down every banner is
// expired at once: the centre shows them all. Only the cards take touches (setInputRects) and are blurred
// (setBlurRects); the window is a 680 px band hung from the top edge, KWin centres it (src/main.cpp).
import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami
import org.kde.notificationmanager as NotificationManager

Window {
    id: win
    required property var shellRoot
    readonly property var r: shellRoot
    width: 680
    height: 480
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "y700-banners"

    readonly property int cardTop: 40        // screen y of the first card: under the 28 px status bar (the mockup's 38)
    readonly property int radius: 22

    NotificationManager.Notifications {
        id: notes
        showNotifications: true
        showJobs: false                      // KIO / job progress stays out (README「有意不做」)
        showExpired: false
        showDismissed: false
        limit: 3
        groupMode: NotificationManager.Notifications.GroupDisabled
        sortMode: NotificationManager.Notifications.SortByDate
        sortOrder: Qt.DescendingOrder
        Component.onCompleted: {
            window = win;                    // the xdg-activation token a tapped notification's app gets
            shell.log("notifications: serving org.freedesktop.Notifications");
        }
    }

    // mapped while there is a card, and a moment longer so a leaving card finishes its fade; never under the curtain.
    // The model's count, not the ListView's: a ListView only signals countChanged when its window polishes (lays
    // out before a frame), and a hidden window never does - so a window waiting for list.count > 0 stays hidden
    // for good (bed, 10-22: rows came in, no banner). notes.count follows the rows as they are inserted.
    readonly property bool want: r.ready && !shell.ccOpen && notes.count > 0
    onWantChanged: if (!want) linger.restart()
    Timer { id: linger; interval: 240 }
    visible: want || (r.ready && !shell.ccOpen && linger.running)

    // the curtain shows them all: the banners are done (from the last row down: an expired row leaves the model)
    Connections {
        target: shell
        function onCcOpenChanged() {
            if (!shell.ccOpen) return;
            for (let i = notes.rowCount() - 1; i >= 0; i--) notes.expire(notes.index(i, 0));
        }
    }

    // blur + input follow the cards (while they come in, move down and fade out)
    function sync() {
        if (!visible) return;
        const rects = [];
        for (const c of list.contentItem.children) {
            if (!c.isCard) continue;
            rects.push({ x: Math.round(list.x + c.x), y: Math.round(list.y + c.y), w: Math.round(c.width), h: Math.round(c.height) });
        }
        shell.setBlurRects(win, rects, win.radius);
        shell.setInputRects(win, rects);
    }
    onVisibleChanged: Qt.callLater(sync)

    ListView {
        id: list
        y: win.cardTop
        width: win.width
        height: win.height - y
        model: notes
        interactive: false
        spacing: 10
        onCountChanged: Qt.callLater(win.sync)
        // in: from 40 px above its place (the mockup); out: a fade with a touch of shrink, never from nothing
        add: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200 }
            NumberAnimation { property: "y"; from: -40; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
        }
        displaced: Transition {
            NumberAnimation { property: "y"; duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
        }
        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: 180 }
            NumberAnimation { property: "scale"; to: 0.96; duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
        }
        delegate: Banner {}
    }

    component Banner: Item {
        id: card
        required property int index
        required property var model
        readonly property bool isCard: true
        width: list.width
        height: body.height
        onYChanged: Qt.callLater(win.sync)
        onHeightChanged: Qt.callLater(win.sync)
        Component.onCompleted: shell.log("banner + " + model.summary)
        function expire() { notes.expire(notes.index(card.index, 0)) }

        // the banner's clock: 5 s, +40 ms a character of body past 40, 10 s at most; an app's own timeout as given
        // (2-15 s); 0 (critical urgency) = not by itself. Paused under a finger and while the window is hidden
        readonly property int ttl: model.timeout > 0 ? Math.min(15000, Math.max(2000, model.timeout))
                                 : 5000 + Math.min(5000, Math.max(0, String(model.body || "").length - 40) * 40)
        Timer {
            id: clock
            interval: card.ttl
            running: card.model.timeout !== 0 && win.visible && !tap.pressed && !drag.active && !flyOut.running
            onTriggered: { shell.log("banner expired: " + card.model.summary); card.expire() }
        }

        Item {
            id: body
            width: card.width
            height: Math.max(44, column.height) + 32
            scale: tap.pressed ? 0.97 : 1
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
            // the finger moves the card; let go short of the threshold and it comes back, past it and it leaves
            property real dx: 0
            property real dy: 0
            transform: Translate { x: body.dx; y: body.dy }
            Behavior on dx { enabled: !drag.active && !flyOut.running; NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
            Behavior on dy { enabled: !drag.active && !flyOut.running; NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }

            Rectangle {   // material: a tint over the blur behind, a 1 px rim (the mockup's banner)
                anchors.fill: parent
                radius: win.radius
                color: Qt.rgba(30 / 255, 32 / 255, 38 / 255, 0.62)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.10)
            }
            Kirigami.Icon {   // the app
                x: 18; y: 16
                width: 44; height: 44
                source: card.model.applicationIconName || card.model.desktopEntry || "preferences-desktop-notification"
                roundToIconSize: false
            }
            Column {
                id: column
                x: 18 + 44 + 14
                y: 16
                width: card.width - x - 18 - (pic.visible ? 44 + 14 : 0)
                spacing: 3
                Text {
                    width: parent.width
                    color: Qt.rgba(1, 1, 1, 0.7)
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    text: card.model.applicationName || ""
                    visible: text.length > 0
                }
                Text {
                    width: parent.width
                    color: "white"
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    text: card.model.summary || ""
                }
                Text {
                    width: parent.width
                    color: Qt.rgba(1, 1, 1, 0.75)
                    font.pixelSize: 14
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: card.model.body || ""
                    visible: text.length > 0
                }
                Row {   // the notification's actions as pills (vivo); the default action is the card itself
                    id: actions
                    readonly property var labels: card.model.actionLabels || []
                    visible: labels.length > 0
                    spacing: 8
                    topPadding: 6
                    Repeater {
                        model: actions.labels
                        Rectangle {
                            id: pill
                            required property string modelData
                            required property int index
                            height: 30
                            width: pillText.implicitWidth + 28
                            radius: 15
                            color: Qt.rgba(1, 1, 1, pillTap.pressed ? 0.26 : 0.16)
                            scale: pillTap.pressed ? 0.96 : 1
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
                            Text {
                                id: pillText
                                anchors.centerIn: parent
                                color: "white"
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                text: pill.modelData
                            }
                            TapHandler {
                                id: pillTap
                                onTapped: {
                                    shell.log("banner action: " + pill.modelData);
                                    notes.invokeAction(notes.index(card.index, 0), card.model.actionNames[pill.index],
                                                       NotificationManager.Notifications.Close);
                                }
                            }
                        }
                    }
                }
            }
            Kirigami.Icon {   // the notification's own picture, if any (a received image, a screenshot)
                id: pic
                x: card.width - 18 - 44; y: 16
                width: 44; height: 44
                visible: !!card.model.image || !!card.model.iconName
                source: card.model.image || card.model.iconName || ""
                roundToIconSize: false
            }

            TapHandler {
                id: tap
                onTapped: (eventPoint) => {
                    // a tap on a pill is the pill's (both handlers see it: this one lets it be)
                    if (actions.visible && actions.contains(actions.mapFromItem(body, eventPoint.position))) return;
                    shell.log("banner tapped: " + card.model.summary);
                    if (card.model.hasDefaultAction) notes.invokeDefaultAction(notes.index(card.index, 0), NotificationManager.Notifications.Close);
                    else card.expire();
                }
            }
            DragHandler {
                id: drag
                target: null
                onActiveTranslationChanged: if (active) { body.dx = activeTranslation.x; body.dy = Math.min(0, activeTranslation.y) }
                onActiveChanged: {
                    if (active) return;
                    if (body.dy < -40 || Math.abs(body.dx) > 120) {
                        shell.log("banner swiped: " + card.model.summary);
                        flyOut.tx = Math.abs(body.dx) > 120 ? (body.dx > 0 ? body.width : -body.width) : body.dx;
                        flyOut.ty = body.dy < -40 ? -(card.y + win.cardTop + body.height) : body.dy;
                        flyOut.start();
                    } else {
                        body.dx = 0; body.dy = 0;
                    }
                }
            }
            // off the way the finger sent it, then expired (the remove transition then fades what is left: nothing)
            SequentialAnimation {
                id: flyOut
                property real tx: 0
                property real ty: 0
                ParallelAnimation {
                    NumberAnimation { target: body; property: "dx"; to: flyOut.tx; duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
                    NumberAnimation { target: body; property: "dy"; to: flyOut.ty; duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
                    NumberAnimation { target: body; property: "opacity"; to: 0; duration: 160 }
                }
                ScriptAction { script: card.expire() }
            }
        }
    }
}
