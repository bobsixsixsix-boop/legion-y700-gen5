// The stage manager's backdrop (linux/stage; vivo 原子工作台's static background): the wallpaper blurred with 30/255
// black over it, the whole screen on the Bottom layer - over the wallpaper and the desktop icons, under every window.
// The KWin script turns it on (shell.stage, setStage over D-Bus) while a group is on the stage; 300 ms in and out.
// The blur is worked out once per wallpaper: a quarter-size copy, a cached GaussianBlur, scaled up (the blur hides
// the scaling). Nothing moves while it shows, so it costs no frames. It takes the touches that miss the stage and
// the cards (the desktop icons under it are hidden; tapping them blind would open apps), never the keyboard.
import QtQuick
import QtQuick.Window
import Qt5Compat.GraphicalEffects

Window {
    id: win
    required property var shellRoot
    visible: shellRoot.ready && (shell.stage || body.opacity > 0)
    width: Screen.width
    height: Screen.height
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "y700-stage-backdrop"

    Item {
        id: body
        anchors.fill: parent
        opacity: shell.stage ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.33, 0, 0.67, 1, 1, 1] } }

        Rectangle { anchors.fill: parent; color: "#2a3346" }   // no wallpaper found, or not decoded yet
        Item {
            // 1.1 x the screen as the mockup (CSS blur(40px) on a scale(1.1) copy): the blur's soft rim stays outside
            width: win.width / 4
            height: win.height / 4
            anchors.centerIn: parent
            scale: 4 * 1.1
            Image {
                id: wall
                anchors.fill: parent
                source: shell.wallpaper
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(Math.ceil(width * Screen.devicePixelRatio), Math.ceil(height * Screen.devicePixelRatio))
                asynchronous: true
                visible: false
            }
            GaussianBlur {
                anchors.fill: parent
                source: wall
                visible: wall.status === Image.Ready
                deviation: 10            // 40 px on the screen
                radius: 24
                samples: 49
                cached: true
            }
        }
        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 30 / 255) }
    }
}
