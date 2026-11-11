// y700 task switcher: one card of the stack. Only draws; TaskSwitcher.qml positions it every frame
// (px, py, ps, ...) and owns all the motion. Card-local coordinates: (0, 0, cw, ch) is the work area
// x ratio; the window is drawn where it sits in the work area (a "screen miniature"), so a card zooms
// exactly onto the real window.
import QtQuick
import Qt5Compat.GraphicalEffects

import org.kde.kirigami as Kirigami
import org.kde.kwin 3.0 as KWinComponents

Item {
    id: card

    required property QtObject window
    required property var wid               // the window's internalId, kept after the window is gone
    required property real cw
    required property real ch
    required property rect win              // the window in card-local coordinates
    required property bool guarded
    required property string name
    required property var icon
    required property real zoomK            // 1 / ratio: how far the anchor card is blown up at most
    required property real dpr              // the output's scale (the layer is sized in device pixels)
    // a ▾ after the name, its menu 「分屏」 (linux/split, 11-10): only while the split screen script runs and the stage
    // manager is off, never on a game (TaskSwitcher.makeCard)
    required property bool menuable

    // the window fills the work area (maximized, or a fullscreen game that also covers the panel):
    // then the card IS the window (a fullscreen game's card is a little taller); otherwise the card is
    // the work area with the window drawn inside on a dark ground
    readonly property bool fills: win.width >= cw * .92 && win.height >= ch * .92
    readonly property rect shape: fills ? win : Qt.rect(0, 0, cw, ch)

    // written by TaskSwitcher.render()
    property real px: 0
    property real py: 0
    property real ps: 1
    property real palpha: 1
    property real pdim: 0
    property real phead: 1
    property real pname: 1
    property real pshadow: 0
    property real pradius: 18
    property real pzoom: 0                  // 0..1: how far this card is zoomed toward the screen (anchor only)
    property bool anchor: false             // the card the zoom is anchored on
    property bool hires: false              // full-resolution layer: the anchor while it zooms (not at rest in the stack)
    property bool shown: true
    property int zk: 0
    property bool headDown: false           // a finger on the header (its menu opens on the release)
    readonly property real headW: head.width   // for TaskSwitcher's hit rect of the header

    // guarded card: the first swipe arms it (red band, 3 s), the second closes
    property bool armed: false
    property bool reduced: false
    signal armExpired()

    width: cw
    height: ch
    x: px
    y: py
    z: zk
    opacity: palpha
    visible: shown
    transform: Scale { origin.x: 0; origin.y: card.ch / 2; xScale: card.ps; yScale: card.ps }

    Timer {
        id: armTimer
        interval: 3000
        onTriggered: { card.armed = false; card.armExpired(); }
    }
    function arm() { armed = true; armTimer.restart(); countdown.restart(); }
    function disarm() { armed = false; armTimer.stop(); countdown.stop(); }

    // shadow that separates the stacked cards (vivo: on the left)
    Kirigami.ShadowedRectangle {
        x: card.shape.x; y: card.shape.y; width: card.shape.width; height: card.shape.height
        radius: card.pradius
        color: "#222222"
        opacity: card.pshadow
        visible: opacity > 0.005
        shadow.size: 40
        shadow.xOffset: -14
        shadow.yOffset: 4
        shadow.color: Qt.rgba(0, 0, 0, 0.42)
    }

    // the picture: ground + live window thumbnail, rounded by a mask like KWin's own overview does it
    Item {
        id: picture
        x: card.shape.x; y: card.shape.y; width: card.shape.width; height: card.shape.height

        layer.enabled: true
        layer.smooth: true                  // drawn scaled (press, stack depth, mid-zoom): linear, not nearest
        // full resolution only while the card zooms in or out, else it would go soft on the way
        layer.textureSize: Qt.size(Math.ceil(width * texScale), Math.ceil(height * texScale))
        readonly property real texScale: card.dpr * (card.hires ? card.zoomK : 1)
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: picture.width
                height: picture.height
                radius: card.pradius
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "#222222"
            // a window that does not fill the screen: the ground goes as the card becomes the screen
            opacity: card.fills ? 1 : 1 - card.pzoom
        }
        KWinComponents.WindowThumbnail {
            wId: card.wid
            x: card.win.x - card.shape.x
            y: card.win.y - card.shape.y
            width: card.win.width
            height: card.win.height
        }
    }

    // depth dim + hairline edge (outside the layer: they change every frame while scrolling)
    Rectangle {
        x: card.shape.x; y: card.shape.y; width: card.shape.width; height: card.shape.height
        radius: card.pradius
        color: "black"
        opacity: card.pdim
        visible: opacity > 0.002
    }
    Rectangle {
        x: card.shape.x; y: card.shape.y; width: card.shape.width; height: card.shape.height
        radius: card.pradius
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)
        opacity: 1 - card.pzoom
        visible: opacity > 0.01
    }

    // header above the card: icon 30, name 16/600, 「防误关」 tag for games, ▾ (its menu, TaskSwitcher.openMenu)
    Row {
        id: head
        x: 9
        y: -40
        height: 30
        spacing: 10
        opacity: card.phead * (card.headDown ? 0.6 : 1)
        visible: opacity > 0.005

        Kirigami.Icon {
            width: 30
            height: 30
            anchors.verticalCenter: parent.verticalCenter
            source: card.icon
        }
        Text {
            renderType: Text.QtRendering   // stays sharp while the stack layer scales
            anchors.verticalCenter: parent.verticalCenter
            text: card.name
            color: "white"
            font.pixelSize: 16
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            width: Math.min(implicitWidth, card.cw - 140)
            opacity: card.pname
        }
        Rectangle {
            visible: card.guarded
            anchors.verticalCenter: parent.verticalCenter
            width: tag.implicitWidth + 16
            height: tag.implicitHeight + 2
            radius: 7
            color: Qt.rgba(1, 1, 1, 0.16)
            opacity: card.pname
            Text {
                renderType: Text.QtRendering   // stays sharp while the stack layer scales
                id: tag
                anchors.centerIn: parent
                text: "防误关"
                color: Qt.rgba(1, 1, 1, 0.86)
                font.pixelSize: 13
                font.weight: Font.Medium
            }
        }
        // ▾: 16 px, 6 px after the name (the row's 10 less 4), dimmer than the name
        Item {
            visible: card.menuable
            width: 12
            height: 30
            opacity: card.pname
            Kirigami.Icon {
                x: -4
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                source: "arrow-down"
                isMask: true
                color: Qt.rgba(1, 1, 1, 0.7)
            }
        }
    }

    // armed guarded card: red band near the bottom with a 3 s countdown
    Rectangle {
        id: band
        anchors.horizontalCenter: parent.horizontalCenter
        y: card.ch - 28 - height
        width: bandText.implicitWidth + 40
        height: bandText.implicitHeight + 22
        radius: 14
        color: Qt.rgba(1, 59 / 255, 48 / 255, 0.94)
        clip: true
        opacity: card.armed ? 1 : 0
        scale: card.armed || card.reduced ? 1 : 0.96
        visible: opacity > 0.005
        Behavior on opacity { enabled: !card.reduced; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on scale { enabled: !card.reduced; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Text {
            renderType: Text.QtRendering   // stays sharp while the stack layer scales
            id: bandText
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -1
            text: "再上划一次才会关掉"
            color: "white"
            font.pixelSize: 18
            font.weight: Font.DemiBold
        }
        Rectangle {
            id: bar
            x: 0
            anchors.bottom: parent.bottom
            height: 3
            width: parent.width * barScale
            property real barScale: 1
            color: Qt.rgba(1, 1, 1, 0.55)
            NumberAnimation on barScale {
                id: countdown
                running: false
                from: 1; to: 0
                duration: 3000
            }
        }
    }
}
