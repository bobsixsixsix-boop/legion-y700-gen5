// One key face. Pure view: the keyboard's touch logic sets `down` and reads `def`.
// Look (design mockup .key): radius 6, a 1 px hard bottom "lip" instead of a blurred shadow,
// a 1 px top edge highlight on dark skins; pressed = colour change only (no scale: it is pressed
// thousands of times a day), released fades back in 80 ms linear.
import QtQuick
import "."
import "Layouts.js" as L

Item {
    id: key
    property var def: ({})
    property bool down: false
    property real fs: 1                 // font scale (split .94, float .83)
    property real u: 1                  // design px -> logical px
    property bool zh: true
    property string lang: "zh"          // zh | en | ja: which one the 中英日 key shows big
    property int shift: 0               // 0 off, 1 once, 2 caps lock
    // blue ⏎ on the letter layouts, grey ⏎ on the number pad. The label stays an icon: the app's
    // Enter may send, go or break the line, and the virtual keyboard protocol does not say which
    property bool accent: def.t === "enter" && !!def.send
    property bool cursorTint: false                           // the space bar while it steers the cursor
    property bool listMode: def.t === "list"
    property alias glowLayer: glowLayer
    readonly property bool fnKey: !!def.fn && !accent

    // lip: 1 px below the face
    Rectangle {
        anchors.fill: face; anchors.topMargin: 1 * key.u; anchors.bottomMargin: -1 * key.u
        radius: face.radius
        color: key.accent ? Theme.accLip : (key.down ? Theme.lipP : Theme.lip)
    }
    Rectangle {
        id: face
        anchors.fill: parent
        anchors.topMargin: key.down && Theme.pressSinks ? 0.5 * key.u : 0
        radius: 6 * key.u
        clip: true
        color: key.cursorTint ? Theme.accSoft
             : key.accent ? (key.down ? Theme.accP : Theme.acc)
             : key.fnKey ? (key.down ? Theme.fnP : Theme.fn)
             : (key.down ? Theme.keyP : Theme.key)
        Behavior on color { enabled: !key.down; ColorAnimation { duration: 80; easing.type: Easing.Linear } }

        // top edge highlight (dark skins)
        Rectangle { visible: !key.accent && !key.down; x: face.radius; width: parent.width - 2 * face.radius; height: 1; color: Theme.edge }

        Item { id: glowLayer; anchors.fill: parent }

        Loader {
            anchors.fill: parent
            sourceComponent: {
                switch (key.def.t) {
                case "char": return charFace
                case "punct": case "digit": case "sep": case "sym": case "num": case "back": return textFace
                case "shift": case "del": return iconFace
                case "space": return spaceFace
                case "lang": return langFace
                case "enter": return iconFace
                case "list": return listFace
                }
                return null
            }
        }
    }

    readonly property color inkColour: key.accent ? "#ffffff" : Theme.ink

    Component {
        id: charFace
        Item {
            readonly property string hint: L.hints(key.zh)[key.def.k] || ""
            readonly property bool upper: key.zh || key.shift > 0
            Text {
                visible: hint !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                y: 7 * key.u * key.fs
                text: hint; color: Theme.ink2
                font.family: Theme.font; font.pixelSize: 13 * key.u * key.fs
            }
            Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: (hint === "" ? 0 : (upper ? 4 : 3)) * key.u * key.fs
                text: upper ? key.def.k.toUpperCase() : key.def.k
                color: key.inkColour
                font.family: Theme.font; font.weight: Font.Medium
                font.pixelSize: (upper ? 24 : 25) * key.u * key.fs
            }
        }
    }
    Component {
        id: textFace
        Text {
            readonly property bool pun: key.def.t === "punct" && /[，。、]/.test(key.def.ch)
            readonly property bool dig: key.def.t === "digit" || (key.def.t === "punct" && !pun)
            text: key.def.t === "sep" ? "分词" : key.def.t === "sym" ? "符" : key.def.t === "num" ? "123"
                : key.def.t === "back" ? "返回" : key.def.ch
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            color: key.inkColour
            font.family: Theme.font
            font.weight: dig ? Font.Bold : Font.Medium
            font.pixelSize: (pun ? 24 : dig ? 28 : 21) * key.u * key.fs
            // ，。 sit low-left in the glyph box: nudge them like the design (.3em right, .2em up)
            transform: Translate { x: pun ? 0.3 * 24 * key.u * key.fs : 0; y: pun ? -0.2 * 24 * key.u * key.fs : 0 }
            width: parent.width; height: parent.height
        }
    }
    Component {
        id: iconFace
        Item {
            readonly property string name: key.def.t === "del" ? "backspace"
                : key.def.t === "enter" ? "enter"
                : key.shift === 2 ? "shift_lock" : key.shift === 1 ? "shift_once" : "shift"
            readonly property real sz: (key.def.t === "shift" ? 24 : 28) * key.u * key.fs
            Image {
                anchors.centerIn: parent
                width: parent.sz; height: parent.sz
                sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(height * Screen.devicePixelRatio))
                source: Theme.ic(parent.name, key.inkColour, 2)
            }
        }
    }
    Component {
        id: spaceFace
        Item {
            Image {
                anchors.centerIn: parent
                width: 76 * key.u * key.fs; height: 38 * key.u * key.fs
                sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(height * Screen.devicePixelRatio))
                source: Theme.ic("__space", Theme.ink, 1.45)
            }
        }
    }
    Component {
        id: langFace
        // 中 英 日: the current language big, the other two small (the key cycles 中 → 英 → 日)
        Item {
            Row {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -2 * key.u * key.fs
                spacing: 2 * key.u * key.fs
                Repeater {
                    model: [["zh", "中"], ["en", "英"], ["ja", "日"]]
                    delegate: Text {
                        required property var modelData
                        readonly property bool on: key.lang === modelData[0]
                        // same box height, text sits on the bottom: the big and small glyphs share a line
                        height: 30 * key.u * key.fs; verticalAlignment: Text.AlignBottom
                        text: modelData[1]; color: Theme.ink; opacity: on ? 1 : .36
                        font.family: Theme.font; font.weight: Font.Medium
                        font.pixelSize: (on ? 21 : 13) * key.u * key.fs
                    }
                }
            }
        }
    }
    Component {
        id: listFace
        ListView {
            id: lv
            objectName: "numList"
            clip: true
            interactive: false              // the keyboard's touch logic scrolls it
            topMargin: 6 * key.u; bottomMargin: 6 * key.u
            model: L.NUM_LIST
            delegate: Item {
                width: lv.width; height: 54 * key.u * key.fs
                property bool hot: lv.hotIndex === index
                Rectangle { anchors.fill: parent; anchors.leftMargin: 6 * key.u; anchors.rightMargin: 6 * key.u; radius: 8 * key.u; color: parent.hot ? Theme.cardP : "transparent" }
                Text { anchors.centerIn: parent; text: modelData; color: Theme.ink; font.family: Theme.font; font.pixelSize: 22 * key.u * key.fs }
            }
            property int hotIndex: -1
        }
    }
}
